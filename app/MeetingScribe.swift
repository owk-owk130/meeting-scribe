import AppKit
import EventKit
import Foundation

// .app は build.sh がプロジェクトルートに生成するので、バンドルの親 = プロジェクトルート
let rootDir = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent().path
let stateDir = "\(rootDir)/state"
let liveTranscriptFile = "\(stateDir)/live-transcript.md"
let logFile = "\(stateDir)/record.log"

// 子プロセス同士（recorder / whisper / transcribe.sh）が同じログに同時に書くので追記モードで開く
func logHandle() -> FileHandle {
    FileHandle(fileDescriptor: open(logFile, O_WRONLY | O_APPEND | O_CREAT, 0o644), closeOnDealloc: true)
}

let idleIcon = "🎙"
let recordingIcon = "🔴"
let pausedIcon = "⏸"
let recentNotesCount = 5
let logRotateBytes = 10 * 1024 * 1024
let eventLookaheadSecs: TimeInterval = 10 * 60
let eventStore = EKEventStore()

func eventSidecar(_ recording: String) -> String {
    recording.replacingOccurrences(of: ".m4a", with: ".event.json")
}

// 進行中か 10 分以内に始まる予定。録音は会議の少し前に始めることが多い
func currentCalendarEvents() -> [[String: Any]] {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
    let now = Date()
    let predicate = eventStore.predicateForEvents(withStart: now, end: now.addingTimeInterval(eventLookaheadSecs), calendars: nil)
    let formatter = ISO8601DateFormatter()
    return eventStore.events(matching: predicate).filter { !$0.isAllDay }
        .sorted { $0.startDate < $1.startDate }.map { event in
        [
            "title": event.title ?? "",
            "start": formatter.string(from: event.startDate),
            "end": formatter.string(from: event.endDate),
            "attendees": (event.attendees ?? []).compactMap { $0.name },
        ]
    }
}

struct ShellResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

func runShell(_ launchPath: String, _ args: [String]) -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
    } catch {
        return ShellResult(stdout: "", stderr: "\(error.localizedDescription)", exitCode: -1)
    }
    // パイプが詰まらないよう wait より先に EOF まで読み切る
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    return ShellResult(stdout: decode(outData), stderr: decode(errData), exitCode: process.terminationStatus)
}

func notify(_ message: String) {
    _ = runShell("/usr/bin/osascript", ["-e", "display notification \"\(message)\" with title \"MeetingScribe\""])
}

struct Config {
    let recordingsDir: String
    let vaultMeetingsDir: String
    let liveTranscribe: Bool
    let silenceStopMins: String
    let silenceThresholdDB: String
    let maxRecordMins: String
    let recordingsKeepDays: Int
    let inboxDir: String
    let live: LiveConfig
}

struct LiveConfig {
    let intervalSecs: Int
    let whisperBin: String
    let ffmpegBin: String
    let model: String
    let vadModel: String
    let language: String
    let mergeScript: String
}

// ツールの既定パスは common.sh が持つので、shell スクリプトと同じ値を読む
func loadConfig() -> Config? {
    let variables = [
        "$RECORDINGS_DIR", "$VAULT_MEETINGS_DIR", "${LIVE_TRANSCRIBE:-1}", "${SILENCE_STOP_MINS:-0}",
        "${SILENCE_THRESHOLD_DB:-}", "${MAX_RECORD_MINS:-0}", "${RECORDINGS_KEEP_DAYS:-0}", "${INBOX_DIR:-}",
        "${LIVE_INTERVAL_SECS:-30}", "$WHISPER_BIN", "$FFMPEG_BIN", "$MODEL", "$VAD_MODEL", "$WHISPER_LANG",
    ]
    let result = runShell("/bin/bash", [
        "-c",
        "ROOT_DIR=\"\(rootDir)\" SCRIPT_DIR=\"\(rootDir)/scripts\" && source \"$ROOT_DIR/config.sh\" "
            + "&& source \"$SCRIPT_DIR/common.sh\" && printf '%s\\n' "
            + variables.map { "\"\($0)\"" }.joined(separator: " "),
    ])
    let lines = result.stdout.components(separatedBy: "\n")
    guard result.exitCode == 0, lines.count == variables.count, !lines[0].isEmpty, !lines[1].isEmpty else { return nil }
    let live = LiveConfig(intervalSecs: Int(lines[8]) ?? 30, whisperBin: lines[9], ffmpegBin: lines[10],
                          model: lines[11], vadModel: lines[12], language: lines[13],
                          mergeScript: "\(rootDir)/scripts/merge_transcript.py")
    return Config(recordingsDir: lines[0], vaultMeetingsDir: lines[1], liveTranscribe: lines[2] != "0",
                  silenceStopMins: lines[3], silenceThresholdDB: lines[4], maxRecordMins: lines[5],
                  recordingsKeepDays: Int(lines[6]) ?? 0, inboxDir: lines[7], live: live)
}

// 録音中の raw PCM（2ch float32 インターリーブ）を一定間隔で切り出し、自分/相手を並列に whisper にかける
final class LiveTranscriber {
    private static let bytesPerFrame: UInt64 = 8
    private static let minChunkSecs: UInt64 = 2

    private let config: LiveConfig
    private let pcmPath: String
    private let transcriptPath: String
    private let queue = DispatchQueue(label: "live.transcribe")
    private let tmpDir: String
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var running: [Process] = []
    private var stopped = false
    private var offset: UInt64
    private var rate: UInt64?

    init(config: LiveConfig, pcmPath: String, transcriptPath: String, resumeFromEnd: Bool) {
        self.config = config
        self.pcmPath = pcmPath
        self.transcriptPath = transcriptPath
        tmpDir = NSTemporaryDirectory() + "meetingscribe-live-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        offset = resumeFromEnd ? LiveTranscriber.frameAlignedSize(pcmPath) : 0
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(config.intervalSecs), repeating: .seconds(config.intervalSecs))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    // 実行中の whisper ごと止める。残すと最終文字起こしとモデルが同時に走る
    func stop() {
        lock.lock()
        stopped = true
        running.forEach { $0.terminate() }
        lock.unlock()
        timer?.cancel()
        queue.async { [tmpDir] in try? FileManager.default.removeItem(atPath: tmpDir) }
    }

    private static func frameAlignedSize(_ path: String) -> UInt64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 ?? 0
        return size / bytesPerFrame * bytesPerFrame
    }

    private func tick() {
        if rate == nil {
            rate = (try? String(contentsOfFile: pcmPath + ".rate", encoding: .utf8))
                .flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        guard let rate else { return }
        let size = LiveTranscriber.frameAlignedSize(pcmPath)
        guard size > offset, size - offset >= rate * LiveTranscriber.bytesPerFrame * LiveTranscriber.minChunkSecs,
              let handle = FileHandle(forReadingAtPath: pcmPath) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.read(upToCount: Int(size - offset)) else { return }

        let selfWav = "\(tmpDir)/self.wav", othersWav = "\(tmpDir)/others.wav"
        let split = [
            "-hide_banner", "-loglevel", "error", "-y", "-f", "f32le", "-ar", "\(rate)", "-ac", "2", "-i", "pipe:0",
            "-filter_complex", "[0:a]channelsplit=channel_layout=stereo[l][r]",
            "-map", "[l]", "-ac", "1", "-ar", "16000", selfWav,
            "-map", "[r]", "-ac", "1", "-ar", "16000", othersWav,
        ]
        guard run(config.ffmpegBin, split, stdin: chunk) else { return }

        let offsetMs = offset / LiveTranscriber.bytesPerFrame * 1000 / rate
        offset = size

        let whispers = [("self", selfWav), ("others", othersWav)].map { name, wav in
            launch(config.whisperBin, [
                "-m", config.model, "-l", config.language, "-f", wav, "-oj", "-of", "\(tmpDir)/\(name)", "-np",
                "--vad", "--vad-model", config.vadModel,
            ], stderrPath: "\(tmpDir)/\(name).log")
        }
        let succeeded = whispers.map { $0.map(wait) == true }
        guard !succeeded.contains(false) else {
            logWhisperFailure()
            return
        }

        let output = Pipe()
        let merge = [config.mergeScript, "\(tmpDir)/self.json", "\(tmpDir)/others.json",
                     "--offset-ms", "\(offsetMs)", "--labels", "always"]
        guard let process = launch("/usr/bin/python3", merge, stdout: output) else { return }
        let text = output.fileHandleForReading.readDataToEndOfFile()
        guard wait(process), let transcript = FileHandle(forWritingAtPath: transcriptPath) else { return }
        defer { try? transcript.close() }
        _ = try? transcript.seekToEnd()
        try? transcript.write(contentsOf: text)
    }

    // whisper は -np でも GPU の初期化ログを大量に出すので、失敗したときだけ record.log に残す
    private func logWhisperFailure() {
        lock.lock()
        let wasStopped = stopped
        lock.unlock()
        guard !wasStopped else { return }
        let log = logHandle()
        for name in ["self", "others"] {
            if let data = FileManager.default.contents(atPath: "\(tmpDir)/\(name).log") { log.write(data) }
        }
    }

    private func run(_ executable: String, _ arguments: [String], stdin data: Data) -> Bool {
        let input = Pipe()
        guard let process = launch(executable, arguments, stdin: input) else { return false }
        try? input.fileHandleForWriting.write(contentsOf: data)
        try? input.fileHandleForWriting.close()
        return wait(process)
    }

    private func launch(_ executable: String, _ arguments: [String], stdin: Pipe? = nil, stdout: Pipe? = nil,
                        stderrPath: String? = nil) -> Process? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = stdout ?? FileHandle.nullDevice
        if let stderrPath, FileManager.default.createFile(atPath: stderrPath, contents: nil),
           let handle = FileHandle(forWritingAtPath: stderrPath) {
            process.standardError = handle
        } else {
            process.standardError = logHandle()
        }
        guard (try? process.run()) != nil else { return nil }
        running.append(process)
        return process
    }

    private func wait(_ process: Process) -> Bool {
        process.waitUntilExit()
        lock.lock()
        running.removeAll { $0 === process }
        lock.unlock()
        return process.terminationStatus == 0
    }
}

enum RecordingStatus {
    case idle
    case recording(startedAt: Date, pausedAt: Date?)
    case transcribing
}

struct ControlError: Error {
    let message: String
}

// AudioTapRecorder.swift の RecorderExit と一致させる
enum RecorderExit: Int32 {
    case userStop = 0
    case silence = 2
    case maxDuration = 3
}

func processPath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
}

// 操作はすべて queue 上で直列に走らせる（ユーザー操作とポーリングが競合しても文字起こしを二重に始めない）
final class RecordingController {
    let queue = DispatchQueue(label: "recording.control")
    var onRecorderExit: (() -> Void)?

    private let config: Config
    private let recorderBin: String
    private let transcribeScript: String
    private let resummarizeScript: String
    private let importScript: String
    private let pidFile: String
    private let outFile: String
    private let livePCM: String
    private let transcribingPIDFile: String
    private let transcribingFileFile: String
    private let exitFile: String
    private let pausedFile: String
    private let startedFile: String

    private var liveTranscriber: LiveTranscriber?
    private var transcriber: Process?
    private var transcribingPath: String?
    private var inboxSizes: [String: UInt64] = [:]
    private var attemptedImports = Set<String>()

    init(rootDir: String, config: Config) {
        self.config = config
        recorderBin = "\(Bundle.main.bundlePath)/Contents/MacOS/MeetingScribeRecorder"
        transcribeScript = "\(rootDir)/scripts/transcribe.sh"
        resummarizeScript = "\(rootDir)/scripts/resummarize.sh"
        importScript = "\(rootDir)/scripts/import_recording.sh"
        pidFile = "\(stateDir)/recording.pid"
        outFile = "\(stateDir)/recording.file"
        livePCM = "\(stateDir)/live.pcm"
        transcribingPIDFile = "\(stateDir)/transcribing.pid"
        transcribingFileFile = "\(stateDir)/transcribing.file"
        exitFile = "\(stateDir)/recording.exit"
        pausedFile = "\(stateDir)/recording.paused"
        startedFile = "\(stateDir)/recording.started"
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    }

    func sync() -> RecordingStatus {
        if let pid = readPID(pidFile) {
            if isAlive(pid, suffix: "/MeetingScribeRecorder") {
                let started = readDate(startedFile) ?? fileDate(pidFile) ?? Date()
                // アプリを再起動した直後は録音だけが続いているので、今の位置からライブを再開する
                if liveTranscriber == nil, config.liveTranscribe, FileManager.default.fileExists(atPath: livePCM) {
                    startLiveTranscriber(resumeFromEnd: true)
                }
                return .recording(startedAt: started, pausedAt: readDate(pausedFile))
            }
            if let exit = read(exitFile).flatMap(Int32.init).flatMap(RecorderExit.init) {
                finishRecording(reason: stopReason(exit))
            } else {
                // 終了理由が残っていない（クラッシュ等）録音は文字起こしせず未完了に残す
                clearRecordingState()
            }
        }
        if !isTranscribing { importNextInboxRecording() }
        return isTranscribing ? .transcribing : .idle
    }

    func start() throws {
        guard FileManager.default.isExecutableFile(atPath: recorderBin) else {
            throw ControlError(message: "\(recorderBin) がありません。./build.sh を実行してください")
        }
        try? FileManager.default.createDirectory(atPath: config.recordingsDir, withIntermediateDirectories: true)
        clearRecordingState()
        rotateLogIfLarge()
        deleteExpiredRecordings()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let outfile = "\(config.recordingsDir)/meeting-\(formatter.string(from: Date())).m4a"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: recorderBin)
        process.arguments = config.liveTranscribe ? [outfile, livePCM] : [outfile]
        var environment = ProcessInfo.processInfo.environment
        environment["SILENCE_STOP_MINS"] = config.silenceStopMins
        environment["SILENCE_THRESHOLD_DB"] = config.silenceThresholdDB
        environment["MAX_RECORD_MINS"] = config.maxRecordMins
        environment["RECORDER_EXIT_FILE"] = exitFile
        process.environment = environment
        process.standardOutput = logHandle()
        process.standardError = process.standardOutput
        process.terminationHandler = { [weak self] _ in self?.onRecorderExit?() }
        if config.liveTranscribe {
            FileManager.default.createFile(atPath: liveTranscriptFile, contents: Data())
        }
        do {
            try process.run()
        } catch {
            throw ControlError(message: "recorder を起動できません: \(error.localizedDescription)")
        }
        sleep(1)
        guard process.isRunning else {
            throw ControlError(message: "recorder が起動直後に終了しました。state/record.log を確認してください")
        }
        write("\(process.processIdentifier)", to: pidFile)
        write(outfile, to: outFile)
        writeDate(Date(), to: startedFile)
        let events = currentCalendarEvents()
        if !events.isEmpty, let json = try? JSONSerialization.data(withJSONObject: events) {
            try? json.write(to: URL(fileURLWithPath: eventSidecar(outfile)))
        }

        if config.liveTranscribe { startLiveTranscriber(resumeFromEnd: false) }
        notify("録音を開始しました")
    }

    func stop() {
        guard case .recording = sync(), let pid = readPID(pidFile) else { return }
        // SIGINT でファイルを正常にファイナライズさせる
        kill(pid, SIGINT)
        var waited = 0
        while waited < 30, isAlive(pid, suffix: "/MeetingScribeRecorder") {
            usleep(200_000)
            waited += 1
        }
        if isAlive(pid, suffix: "/MeetingScribeRecorder") { kill(pid, SIGKILL) }
        finishRecording(reason: stopReason(.userStop))
    }

    // 停止中の時間は経過時間に含めないよう、再開時に開始時刻をずらす
    func togglePause() {
        guard case .recording(let started, let pausedAt) = sync(), let pid = readPID(pidFile) else { return }
        kill(pid, SIGUSR1)
        if let pausedAt {
            writeDate(started.addingTimeInterval(Date().timeIntervalSince(pausedAt)), to: startedFile)
            remove(pausedFile)
        } else {
            writeDate(Date(), to: pausedFile)
        }
    }

    func transcribe(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ControlError(message: "ファイルがありません: \(path)")
        }
        if isTranscribing {
            throw ControlError(message: "文字起こし中です: \(transcribingFile ?? "")")
        }
        try launchTranscriber(path)
        notify("文字起こしを開始しました: \(URL(fileURLWithPath: path).lastPathComponent)")
    }

    func resummarize(_ note: String) throws {
        if isTranscribing {
            throw ControlError(message: "文字起こし中です: \(transcribingFile ?? "")")
        }
        transcriber = try launch(script: resummarizeScript, arguments: [note])
        transcribingPath = note
        notify("要約を再生成しています: \(URL(fileURLWithPath: note).lastPathComponent)")
    }

    func pending() -> [String] {
        var known = notedRecordings()
        if let current = read(outFile) { known.insert(URL(fileURLWithPath: current).lastPathComponent) }
        if let current = transcribingFile { known.insert(URL(fileURLWithPath: current).lastPathComponent) }
        return recordings().filter { !known.contains($0) }.sorted(by: >).map { "\(config.recordingsDir)/\($0)" }
    }

    // 失敗した取り込みは受け取りフォルダに残るので、同じファイルはアプリの起動中に一度しか試さない
    private func importNextInboxRecording() {
        guard !config.inboxDir.isEmpty else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: config.inboxDir)) ?? []
        for name in names where name.hasPrefix(".") && name.hasSuffix(".icloud") {
            let original = String(name.dropFirst().dropLast(".icloud".count))
            try? FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: "\(config.inboxDir)/\(original)"))
        }
        var sizes: [String: UInt64] = [:]
        for name in names where !name.hasPrefix(".") {
            let path = "\(config.inboxDir)/\(name)"
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? UInt64 else { continue }
            sizes[path] = size
        }
        let previous = inboxSizes
        inboxSizes = sizes
        let ready = sizes.filter { previous[$0.key] == $0.value && !attemptedImports.contains($0.key) }.keys
        guard let path = ready.min(by: { (fileBirthDate($0) ?? .distantFuture) < (fileBirthDate($1) ?? .distantFuture) })
        else { return }
        attemptedImports.insert(path)
        guard let process = try? launch(script: importScript, arguments: [path]) else { return }
        transcriber = process
        transcribingPath = path
        notify("スマホの録音を取り込みます: \(URL(fileURLWithPath: path).lastPathComponent)")
    }

    private func recordings() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: config.recordingsDir)) ?? [])
            .filter { $0.hasSuffix(".m4a") && !$0.hasPrefix(".") }
    }

    private func notedRecordings() -> Set<String> {
        var known = Set<String>()
        for note in (try? FileManager.default.contentsOfDirectory(atPath: config.vaultMeetingsDir)) ?? []
        where note.hasSuffix(".md") && !note.hasPrefix(".") {
            guard let text = try? String(contentsOfFile: "\(config.vaultMeetingsDir)/\(note)", encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.hasPrefix("recording:") {
                // recording: は [a.m4a, b.m4a] のリスト形式もある
                for token in line.split(whereSeparator: { "[], ".contains($0) }) where token.hasSuffix(".m4a") {
                    known.insert(URL(fileURLWithPath: String(token)).lastPathComponent)
                }
            }
        }
        return known
    }

    // ノートになっていない録音は「未完了の文字起こし」から再実行できるよう残す
    private func deleteExpiredRecordings() {
        guard config.recordingsKeepDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(config.recordingsKeepDays) * 86_400)
        let noted = notedRecordings()
        for name in recordings() where noted.contains(name) {
            let path = "\(config.recordingsDir)/\(name)"
            if let date = fileDate(path), date < cutoff { remove(path, eventSidecar(path)) }
        }
    }

    private func rotateLogIfLarge() {
        let size = (try? FileManager.default.attributesOfItem(atPath: logFile))?[.size] as? Int ?? 0
        guard size > logRotateBytes else { return }
        remove(logFile + ".1")
        try? FileManager.default.moveItem(atPath: logFile, toPath: logFile + ".1")
    }

    private var isTranscribing: Bool {
        transcriber?.isRunning == true || readPID(transcribingPIDFile).map { isAlive($0, suffix: "/bash") } == true
    }

    private var transcribingFile: String? {
        if transcriber?.isRunning == true { return read(transcribingFileFile) ?? transcribingPath }
        return isTranscribing ? read(transcribingFileFile) : nil
    }

    private func stopReason(_ exit: RecorderExit) -> String {
        switch exit {
        case .userStop: return "録音を停止しました"
        case .silence: return "無音が \(config.silenceStopMins) 分続いたため録音を自動停止しました"
        case .maxDuration: return "録音が \(config.maxRecordMins) 分に達したため自動停止しました"
        }
    }

    private func finishRecording(reason: String) {
        let outfile = read(outFile)
        clearRecordingState()
        guard let outfile, FileManager.default.fileExists(atPath: outfile) else { return }
        if (try? launchTranscriber(outfile)) != nil {
            notify("\(reason)。文字起こし中…")
        }
    }

    private func clearRecordingState() {
        remove(pidFile, outFile, exitFile, pausedFile, startedFile)
        stopLiveWatcher()
    }

    private func startLiveTranscriber(resumeFromEnd: Bool) {
        let transcriber = LiveTranscriber(config: config.live, pcmPath: livePCM, transcriptPath: liveTranscriptFile,
                                          resumeFromEnd: resumeFromEnd)
        transcriber.start()
        liveTranscriber = transcriber
    }

    private func stopLiveWatcher() {
        liveTranscriber?.stop()
        liveTranscriber = nil
        remove(livePCM, livePCM + ".rate")
    }

    private func launchTranscriber(_ path: String) throws {
        transcriber = try launch(script: transcribeScript, arguments: [path])
        transcribingPath = path
    }

    private func launch(script: String, arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script] + arguments
        process.standardOutput = logHandle()
        process.standardError = process.standardOutput
        do {
            try process.run()
        } catch {
            throw ControlError(message: "\(script) を起動できません: \(error.localizedDescription)")
        }
        return process
    }

    private func isAlive(_ pid: pid_t, suffix: String) -> Bool {
        processPath(pid)?.hasSuffix(suffix) == true
    }

    private func readPID(_ path: String) -> pid_t? {
        read(path).flatMap { pid_t($0) }
    }

    private func readDate(_ path: String) -> Date? {
        read(path).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    private func writeDate(_ date: Date, to path: String) {
        write("\(date.timeIntervalSince1970)", to: path)
    }

    private func read(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ text: String, to path: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func remove(_ paths: String...) {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
    }

    private func fileBirthDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }

    private func fileDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

let config = loadConfig()

// .common モードに登録しないとメニュー表示中（eventTracking）にタイマーが止まる
func makeRepeatingTimer(_ interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in block() }
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

final class LiveTranscriptPanel {
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var timer: Timer?
    private var content: String?

    private(set) var userHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "LivePanelUserHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "LivePanelUserHidden") }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        if panel == nil {
            panel = makePanel()
            panel?.center()
        }
        content = nil
        refresh()
        panel?.orderFront(nil)
        stopTimer()
        timer = makeRepeatingTimer(2) { [weak self] in self?.refresh() }
    }

    func hide() {
        stopTimer()
        panel?.orderOut(nil)
    }

    func toggle() {
        if isVisible {
            hide()
            userHidden = true
        } else {
            show()
            userHidden = false
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // 会議アプリの上に重ねて使うので、フォーカスを奪わない（nonactivating）ことが必須
    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "ライブ文字起こし"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameAutosaveName("MeetingScribeLivePanel")

        let scroll = NSScrollView(frame: panel.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true

        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        panel.contentView?.addSubview(scroll)
        textView = text

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: panel, queue: nil) { [weak self] _ in
            self?.stopTimer()
            self?.userHidden = true
        }
        return panel
    }

    private func refresh() {
        guard let text = textView else { return }
        let latest = (try? String(contentsOfFile: liveTranscriptFile, encoding: .utf8)) ?? ""
        guard latest != content else { return }
        content = latest

        // 末尾を見ているときだけ追従する（発言を遡って読んでいる最中に飛ばされないように）
        let atBottom = text.enclosingScrollView!.contentView.bounds.maxY >= text.frame.height - 30
        text.string = latest.isEmpty ? "（文字起こし待ち…）" : latest
        if atBottom { text.scrollToEndOfDocument(nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let recentNotesMenu = NSMenu()
    private let resummarizeMenu = NSMenu()
    private let pendingItem = NSMenuItem(title: "未完了の文字起こし", action: nil, keyEquivalent: "")
    private let pendingMenu = NSMenu()

    private var recordingStartDate: Date?
    private var recordingPausedAt: Date?
    private var isRecording: Bool { recordingStartDate != nil }
    private var isTranscribing = false
    private var elapsedTimer: Timer?
    private var pollTimer: Timer?
    private let controller = config.map { RecordingController(rootDir: rootDir, config: $0) }
    private var scriptAvailable: Bool { controller != nil }

    private let transcribingItem = NSMenuItem(title: "文字起こし中…", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "録音開始", action: #selector(toggleRecording), keyEquivalent: "r")
    private let pauseItem = NSMenuItem(title: "一時停止", action: #selector(togglePause), keyEquivalent: "p")
    private let liveItem = NSMenuItem(title: "ライブ文字起こしを表示", action: #selector(toggleLivePanel), keyEquivalent: "l")

    private let livePanel = LiveTranscriptPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // autosaveName がないとメニューバー内の位置が保存されず、項目が多いと
        // 最左（ノッチの裏）へ追いやられて見えなくなる
        statusItem.autosaveName = "MeetingScribe"
        statusItem.button?.title = idleIcon

        buildMenu()
        statusItem.menu = menu

        guard let controller else {
            showAlert("config.sh を読み込めません",
                      detail: "\(rootDir)/config.sh が存在しないか壊れています。録音機能は無効です。")
            return
        }

        controller.onRecorderExit = { [weak self] in self?.syncState() }
        // 録音開始時に待たされないよう、権限は起動時に非同期で求めておく
        eventStore.requestFullAccessToEvents { _, _ in }
        syncState()
        pollTimer = makeRepeatingTimer(5) { [weak self] in self?.syncState() }
    }

    private func buildMenu() {
        menu.delegate = self

        transcribingItem.isEnabled = false
        transcribingItem.isHidden = true
        menu.addItem(transcribingItem)

        toggleItem.target = self
        toggleItem.isEnabled = scriptAvailable
        menu.addItem(toggleItem)

        pauseItem.target = self
        pauseItem.isHidden = true
        menu.addItem(pauseItem)

        liveItem.target = self
        liveItem.isEnabled = scriptAvailable
        menu.addItem(liveItem)
        menu.addItem(.separator())

        let recentItem = NSMenuItem(title: "最近のノート", action: nil, keyEquivalent: "")
        recentItem.submenu = recentNotesMenu
        menu.addItem(recentItem)

        let resummarizeItem = NSMenuItem(title: "要約をやり直す", action: nil, keyEquivalent: "")
        resummarizeItem.submenu = resummarizeMenu
        resummarizeMenu.autoenablesItems = false
        menu.addItem(resummarizeItem)
        setRecentNotesPlaceholder("ノートがありません")

        pendingItem.submenu = pendingMenu
        pendingItem.isHidden = true
        pendingMenu.autoenablesItems = false
        menu.addItem(pendingItem)

        let openRecordings = NSMenuItem(title: "録音フォルダを開く", action: #selector(openRecordingsFolder), keyEquivalent: "")
        openRecordings.target = self
        menu.addItem(openRecordings)

        let openVault = NSMenuItem(title: "Vaultを開く", action: #selector(openVaultFolder), keyEquivalent: "")
        openVault.target = self
        menu.addItem(openVault)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuWillOpen(_ opening: NSMenu) {
        guard opening === menu else { return }
        transcribingItem.isHidden = !(scriptAvailable && !isRecording && isTranscribing)
        // iCloud フォルダの列挙は遅いので、メインメニューを開いた時点で投げておく
        rebuildRecentNotesAsync()
        rebuildPendingAsync()
    }

    private func rebuildPendingAsync() {
        guard let controller else { return }
        controller.queue.async { [weak self] in
            let paths = controller.pending()
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingItem.isHidden = paths.isEmpty
                self.pendingItem.title = "未完了の文字起こし (\(paths.count))"
                self.pendingMenu.removeAllItems()
                for path in paths {
                    let item = NSMenuItem(title: URL(fileURLWithPath: path).lastPathComponent,
                                          action: #selector(self.transcribePending(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = path
                    item.isEnabled = !self.isTranscribing
                    self.pendingMenu.addItem(item)
                }
            }
        }
    }

    @objc private func transcribePending(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        syncState({ try $0.transcribe(path) }) { [weak self] error in
            if let error { self?.showAlert("文字起こしを開始できませんでした", detail: error.message) }
        }
    }

    @objc private func resummarizeNote(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        syncState({ try $0.resummarize(path) }) { [weak self] error in
            if let error { self?.showAlert("要約の再生成を開始できませんでした", detail: error.message) }
        }
    }

    private func setRecentNotesPlaceholder(_ title: String) {
        for submenu in [recentNotesMenu, resummarizeMenu] {
            submenu.removeAllItems()
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
    }

    private func rebuildRecentNotesAsync() {
        guard let config else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let dirURL = URL(fileURLWithPath: config.vaultMeetingsDir)
            let notes = ((try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            )) ?? [])
                .filter { $0.pathExtension == "md" }
                .map { url -> (url: URL, date: Date) in
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return (url, date)
                }
                .sorted { $0.date > $1.date }
                .prefix(recentNotesCount)
                .map(\.url)

            DispatchQueue.main.async {
                guard let self else { return }
                if notes.isEmpty {
                    self.setRecentNotesPlaceholder("ノートがありません")
                    return
                }
                self.recentNotesMenu.removeAllItems()
                self.resummarizeMenu.removeAllItems()
                for note in notes {
                    let title = note.deletingPathExtension().lastPathComponent
                    let open = NSMenuItem(title: title, action: #selector(self.openNote(_:)), keyEquivalent: "")
                    open.target = self
                    open.representedObject = note.path
                    self.recentNotesMenu.addItem(open)
                    let redo = NSMenuItem(title: title, action: #selector(self.resummarizeNote(_:)), keyEquivalent: "")
                    redo.target = self
                    redo.representedObject = note.path
                    redo.isEnabled = !self.isTranscribing && !self.isRecording
                    self.resummarizeMenu.addItem(redo)
                }
            }
        }
    }

    private func syncState(_ work: ((RecordingController) throws -> Void)? = nil,
                           then completion: ((ControlError?) -> Void)? = nil) {
        guard let controller else { return }
        controller.queue.async { [weak self] in
            var error: ControlError?
            do {
                try work?(controller)
            } catch let failure as ControlError {
                error = failure
            } catch {}
            let status = controller.sync()
            DispatchQueue.main.async {
                completion?(error)
                self?.applyStatus(status)
            }
        }
    }

    private func applyStatus(_ status: RecordingStatus) {
        var startedAt: Date?
        recordingPausedAt = nil
        isTranscribing = false
        switch status {
        case .recording(let date, let pausedAt):
            startedAt = date
            recordingPausedAt = pausedAt
        case .transcribing: isTranscribing = true
        case .idle: break
        }
        pauseItem.title = recordingPausedAt == nil ? "一時停止" : "再開"
        if let startedAt, isRecording { recordingStartDate = startedAt }
        guard (startedAt != nil) != isRecording else { return }
        pauseItem.isHidden = startedAt == nil
        if let startedAt {
            recordingStartDate = startedAt
            toggleItem.title = "録音停止"
            startElapsedTimer()
            if config?.liveTranscribe == true && !livePanel.userHidden { livePanel.show() }
        } else {
            recordingStartDate = nil
            toggleItem.title = "録音開始"
            stopElapsedTimer()
            statusItem.button?.title = idleIcon
            livePanel.hide()
        }
    }

    @objc private func toggleLivePanel() {
        livePanel.toggle()
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        updateElapsedTitle()
        elapsedTimer = makeRepeatingTimer(1) { [weak self] in self?.updateElapsedTitle() }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func updateElapsedTitle() {
        guard let start = recordingStartDate else { return }
        let elapsed = Int((recordingPausedAt ?? Date()).timeIntervalSince(start))
        let icon = recordingPausedAt == nil ? recordingIcon : pausedIcon
        statusItem.button?.title = String(format: "%@ %02d:%02d", icon, elapsed / 60, elapsed % 60)
    }

    @objc private func togglePause() {
        syncState({ $0.togglePause() })
    }

    @objc private func toggleRecording() {
        toggleItem.isEnabled = false
        // メニューに出ていた状態で分岐する（直前に自動停止していた場合に新規録音を始めない）
        let stopping = isRecording
        syncState({ stopping ? $0.stop() : try $0.start() }) { [weak self] error in
            self?.toggleItem.isEnabled = true
            if let error { self?.showAlert("録音の開始/停止に失敗しました", detail: error.message) }
        }
    }

    // Obsidian は .md のファイルハンドラを登録しないため、ファイル URL で開くと
    // .md の既定アプリ（エディタ等）に渡ってしまう。URL スキームで Obsidian に開かせる
    @objc private func openNote(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openRecordingsFolder() {
        guard let config else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: config.recordingsDir))
    }

    @objc private func openVaultFolder() {
        guard let config else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: config.vaultMeetingsDir))
    }

    private func showAlert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

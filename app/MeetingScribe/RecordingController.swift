import Foundation

let logRotateBytes = 10 * 1024 * 1024

enum RecordingStatus {
    case idle
    case recording(startedAt: Date, pausedAt: Date?)
    case transcribing
}

struct ControlError: Error {
    let message: String
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
    private let inbox: InboxWatcher?

    init(rootDir: String, config: Config) {
        self.config = config
        inbox = config.inboxDir.isEmpty ? nil : InboxWatcher(dir: config.inboxDir)
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

    private func importNextInboxRecording() {
        guard let path = inbox?.nextReadyFile(),
              let process = try? launch(script: importScript, arguments: [path]) else { return }
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

    private func fileDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

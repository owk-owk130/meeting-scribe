import AppKit
import Foundation

// .app は build.sh がプロジェクトディレクトリ内に生成するので、バンドルの親 = スクリプト群の場所
let scriptDir = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent().path
let liveTranscriptFile = "\(scriptDir)/.live-transcript.md"

let idleIcon = "🎙"
let recordingIcon = "🔴"
let recentNotesCount = 5
let logRotateBytes = 10 * 1024 * 1024

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
}

func loadConfig() -> Config? {
    let result = runShell("/bin/bash", [
        "-c",
        "source \"\(scriptDir)/config.sh\" && printf '%s\\n' \"$RECORDINGS_DIR\" \"$VAULT_MEETINGS_DIR\" "
            + "\"${LIVE_TRANSCRIBE:-1}\" \"${SILENCE_STOP_MINS:-0}\" \"${SILENCE_THRESHOLD_DB:-}\" \"${MAX_RECORD_MINS:-0}\"",
    ])
    let lines = result.stdout.components(separatedBy: "\n")
    guard result.exitCode == 0, lines.count == 6, !lines[0].isEmpty, !lines[1].isEmpty else { return nil }
    return Config(recordingsDir: lines[0], vaultMeetingsDir: lines[1], liveTranscribe: lines[2] != "0",
                  silenceStopMins: lines[3], silenceThresholdDB: lines[4], maxRecordMins: lines[5])
}

enum RecordingStatus {
    case idle
    case recording(startedAt: Date)
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
    private let liveScript: String
    private let logFile: String
    private let pidFile: String
    private let outFile: String
    private let livePCM: String
    private let livePIDFile: String
    private let transcribingPIDFile: String
    private let transcribingFileFile: String
    private let exitFile: String

    private var startedAt: Date?
    private var liveWatcher: Process?
    private var transcriber: Process?
    private var transcribingPath: String?

    init(scriptDir: String, config: Config) {
        self.config = config
        recorderBin = "\(scriptDir)/MeetingScribeRecorder"
        transcribeScript = "\(scriptDir)/transcribe.sh"
        liveScript = "\(scriptDir)/transcribe-live.sh"
        logFile = "\(scriptDir)/record.log"
        pidFile = "\(scriptDir)/.recording.pid"
        outFile = "\(scriptDir)/.recording.file"
        livePCM = "\(scriptDir)/.live.pcm"
        livePIDFile = "\(scriptDir)/.live.pid"
        transcribingPIDFile = "\(scriptDir)/.transcribing.pid"
        transcribingFileFile = "\(scriptDir)/.transcribing.file"
        exitFile = "\(scriptDir)/.recording.exit"
    }

    func sync() -> RecordingStatus {
        if let pid = readPID(pidFile) {
            if isAlive(pid, suffix: "/MeetingScribeRecorder") {
                let started = startedAt ?? fileDate(pidFile) ?? Date()
                startedAt = started
                return .recording(startedAt: started)
            }
            if let exit = read(exitFile).flatMap(Int32.init).flatMap(RecorderExit.init) {
                finishRecording(reason: stopReason(exit))
            } else {
                // 終了理由が残っていない（クラッシュ等）録音は文字起こしせず未完了に残す
                clearRecordingState()
            }
        }
        return isTranscribing ? .transcribing : .idle
    }

    func start() throws {
        guard FileManager.default.isExecutableFile(atPath: recorderBin) else {
            throw ControlError(message: "\(recorderBin) がありません。./build.sh を実行してください")
        }
        try? FileManager.default.createDirectory(atPath: config.recordingsDir, withIntermediateDirectories: true)
        clearRecordingState()
        rotateLogIfLarge()

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
            throw ControlError(message: "recorder が起動直後に終了しました。record.log を確認してください")
        }
        write("\(process.processIdentifier)", to: pidFile)
        write(outfile, to: outFile)
        startedAt = Date()

        if config.liveTranscribe {
            let watcher = try launch(script: liveScript, arguments: [livePCM, liveTranscriptFile])
            write("\(watcher.processIdentifier)", to: livePIDFile)
            liveWatcher = watcher
        }
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

    func pending() -> [String] {
        let fm = FileManager.default
        var known = Set<String>()
        for note in (try? fm.contentsOfDirectory(atPath: config.vaultMeetingsDir)) ?? []
        where note.hasSuffix(".md") && !note.hasPrefix(".") {
            guard let text = try? String(contentsOfFile: "\(config.vaultMeetingsDir)/\(note)", encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.hasPrefix("recording:") {
                // recording: は [a.m4a, b.m4a] のリスト形式もある
                for token in line.split(whereSeparator: { "[], ".contains($0) }) where token.hasSuffix(".m4a") {
                    known.insert(URL(fileURLWithPath: String(token)).lastPathComponent)
                }
            }
        }
        if let current = read(outFile) { known.insert(URL(fileURLWithPath: current).lastPathComponent) }
        if let current = transcribingFile { known.insert(URL(fileURLWithPath: current).lastPathComponent) }
        return ((try? fm.contentsOfDirectory(atPath: config.recordingsDir)) ?? [])
            .filter { $0.hasSuffix(".m4a") && !$0.hasPrefix(".") && !known.contains($0) }
            .sorted(by: >)
            .map { "\(config.recordingsDir)/\($0)" }
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
        if transcriber?.isRunning == true { return transcribingPath }
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
        startedAt = nil
        remove(pidFile, outFile, exitFile)
        stopLiveWatcher()
    }

    private func stopLiveWatcher() {
        if let pid = readPID(livePIDFile), isAlive(pid, suffix: "/bash") { kill(pid, SIGTERM) }
        remove(livePIDFile, livePCM, livePCM + ".rate")
        liveWatcher = nil
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

    // 子プロセス同士（recorder / watcher / transcribe.sh）が同じログに同時に書くので追記モードで開く
    private func logHandle() -> FileHandle {
        FileHandle(fileDescriptor: open(logFile, O_WRONLY | O_APPEND | O_CREAT, 0o644), closeOnDealloc: true)
    }

    private func isAlive(_ pid: pid_t, suffix: String) -> Bool {
        processPath(pid)?.hasSuffix(suffix) == true
    }

    private func readPID(_ path: String) -> pid_t? {
        read(path).flatMap { pid_t($0) }
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
    private let pendingItem = NSMenuItem(title: "未完了の文字起こし", action: nil, keyEquivalent: "")
    private let pendingMenu = NSMenu()

    private var recordingStartDate: Date?
    private var isRecording: Bool { recordingStartDate != nil }
    private var isTranscribing = false
    private var elapsedTimer: Timer?
    private var pollTimer: Timer?
    private let controller = config.map { RecordingController(scriptDir: scriptDir, config: $0) }
    private var scriptAvailable: Bool { controller != nil }

    private let transcribingItem = NSMenuItem(title: "文字起こし中…", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "録音開始", action: #selector(toggleRecording), keyEquivalent: "r")
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
                      detail: "\(scriptDir)/config.sh が存在しないか壊れています。録音機能は無効です。")
            return
        }

        controller.onRecorderExit = { [weak self] in self?.syncState() }
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

        liveItem.target = self
        liveItem.isEnabled = scriptAvailable
        menu.addItem(liveItem)
        menu.addItem(.separator())

        let recentItem = NSMenuItem(title: "最近のノート", action: nil, keyEquivalent: "")
        recentItem.submenu = recentNotesMenu
        setRecentNotesPlaceholder("ノートがありません")
        menu.addItem(recentItem)

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

    private func setRecentNotesPlaceholder(_ title: String) {
        recentNotesMenu.removeAllItems()
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        recentNotesMenu.addItem(item)
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
                for note in notes {
                    let item = NSMenuItem(title: note.deletingPathExtension().lastPathComponent,
                                          action: #selector(self.openNote(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = note.path
                    self.recentNotesMenu.addItem(item)
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
        isTranscribing = false
        switch status {
        case .recording(let date): startedAt = date
        case .transcribing: isTranscribing = true
        case .idle: break
        }
        guard (startedAt != nil) != isRecording else { return }
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
        let elapsed = Int(Date().timeIntervalSince(start))
        statusItem.button?.title = String(format: "%@ %02d:%02d", recordingIcon, elapsed / 60, elapsed % 60)
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

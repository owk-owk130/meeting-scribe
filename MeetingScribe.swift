import AppKit
import Foundation

// .app は build.sh がプロジェクトディレクトリ内に生成するので、バンドルの親 = スクリプト群の場所
let scriptDir = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent().path
let recordScript = "\(scriptDir)/record.sh"
let startedFile = "\(scriptDir)/.recording.started"
let liveTranscriptFile = "\(scriptDir)/.live-transcript.md"

let idleIcon = "🎙"
let recordingIcon = "🔴"
let recentNotesCount = 5

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

@discardableResult
func runRecordScript(_ command: String) -> ShellResult {
    runShell("/bin/bash", [recordScript, command])
}

func loadConfig() -> (recordingsDir: String, vaultMeetingsDir: String, liveTranscribe: Bool, configLoaded: Bool) {
    let result = runShell("/bin/bash", [
        "-c", "source \"\(scriptDir)/config.sh\" && printf '%s\\n%s\\n%s' \"$RECORDINGS_DIR\" \"$VAULT_MEETINGS_DIR\" \"${LIVE_TRANSCRIBE:-1}\"",
    ])
    let lines = result.stdout.components(separatedBy: "\n")
    guard result.exitCode == 0, lines.count == 3, !lines[0].isEmpty, !lines[1].isEmpty else {
        return ("", "", true, false)
    }
    return (lines[0], lines[1], lines[2] != "0", true)
}

let (recordingsDir, vaultMeetingsDir, liveTranscribeEnabled, configLoaded) = loadConfig()

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let recentNotesMenu = NSMenu()

    private var recordingStartDate: Date?
    private var isRecording: Bool { recordingStartDate != nil }
    private var isTranscribing = false
    private var elapsedTimer: Timer?
    private var pollTimer: Timer?
    private var scriptAvailable = true

    private let transcribingItem = NSMenuItem(title: "文字起こし中…", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "録音開始", action: #selector(toggleRecording), keyEquivalent: "r")
    private let liveItem = NSMenuItem(title: "ライブ文字起こしを表示", action: #selector(toggleLivePanel), keyEquivalent: "l")

    private var livePanel: NSPanel?
    private var liveTextView: NSTextView?
    private var liveTimer: Timer?
    private var liveContent: String?

    // ユーザーが自分で閉じたら、以降の録音開始で自動表示しない（開き直せば元に戻る）
    private var livePanelUserHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "LivePanelUserHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "LivePanelUserHidden") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // autosaveName がないとメニューバー内の位置が保存されず、項目が多いと
        // 最左（ノッチの裏）へ追いやられて見えなくなる
        statusItem.autosaveName = "MeetingScribe"
        statusItem.button?.title = idleIcon

        scriptAvailable = configLoaded && FileManager.default.isExecutableFile(atPath: recordScript)
        buildMenu()
        statusItem.menu = menu

        if !scriptAvailable {
            showAlert(
                configLoaded ? "record.sh が見つかりません" : "config.sh を読み込めません",
                detail: configLoaded
                    ? "\(recordScript) が存在しないか実行権限がありません。録音機能は無効です。"
                    : "\(scriptDir)/config.sh が存在しないか壊れています。録音機能は無効です。"
            )
            return
        }

        // アプリ再起動時に録音が生きているケースがあるので実状態と同期する
        syncState()
        // .common モードに登録しないとメニュー表示中（eventTracking）にタイマーが止まる
        let poll = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.syncState()
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll
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
    }

    private func setRecentNotesPlaceholder(_ title: String) {
        recentNotesMenu.removeAllItems()
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        recentNotesMenu.addItem(item)
    }

    private func rebuildRecentNotesAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let dirURL = URL(fileURLWithPath: vaultMeetingsDir)
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

    private func syncState(after command: String? = nil, then completion: ((ShellResult?) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = command.map { runRecordScript($0) }
            let status = runRecordScript("status").stdout
            DispatchQueue.main.async {
                completion?(result)
                self?.applyStatus(status)
            }
        }
    }

    private func applyStatus(_ status: String) {
        isTranscribing = status == "transcribing"
        let recording = status == "recording"
        guard recording != isRecording else { return }
        if recording {
            recordingStartDate = readStartedDate() ?? Date()
            toggleItem.title = "録音停止"
            startElapsedTimer()
            if liveTranscribeEnabled && !livePanelUserHidden { showLivePanel() }
        } else {
            recordingStartDate = nil
            toggleItem.title = "録音開始"
            stopElapsedTimer()
            statusItem.button?.title = idleIcon
            hideLivePanel()
        }
    }

    // 会議アプリの上に重ねて使うので、フォーカスを奪わない（nonactivating）ことが必須
    private func makeLivePanel() -> NSPanel {
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
        liveTextView = text

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: panel, queue: nil) { [weak self] _ in
            self?.stopLiveTimer()
            self?.livePanelUserHidden = true
        }
        return panel
    }

    private func showLivePanel() {
        if livePanel == nil {
            livePanel = makeLivePanel()
            livePanel?.center()
        }
        liveContent = nil
        refreshLiveTranscript()
        livePanel?.orderFront(nil)
        startLiveTimer()
    }

    private func hideLivePanel() {
        stopLiveTimer()
        livePanel?.orderOut(nil)
    }

    @objc private func toggleLivePanel() {
        if livePanel?.isVisible == true {
            hideLivePanel()
            livePanelUserHidden = true
        } else {
            showLivePanel()
            livePanelUserHidden = false
        }
    }

    private func startLiveTimer() {
        stopLiveTimer()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshLiveTranscript()
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func stopLiveTimer() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    private func refreshLiveTranscript() {
        guard let text = liveTextView else { return }
        let content = (try? String(contentsOfFile: liveTranscriptFile, encoding: .utf8)) ?? ""
        guard content != liveContent else { return }
        liveContent = content

        // 末尾を見ているときだけ追従する（発言を遡って読んでいる最中に飛ばされないように）
        let atBottom: Bool
        if let scroll = text.enclosingScrollView {
            atBottom = scroll.contentView.bounds.maxY >= text.frame.height - 30
        } else {
            atBottom = true
        }
        text.string = content.isEmpty ? "（文字起こし待ち…）" : content
        if atBottom { text.scrollToEndOfDocument(nil) }
    }

    private func readStartedDate() -> Date? {
        guard let text = try? String(contentsOfFile: startedFile, encoding: .utf8),
              let epoch = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        updateElapsedTitle()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateElapsedTitle()
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
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
        syncState(after: "toggle") { [weak self] result in
            self?.toggleItem.isEnabled = true
            if let result, result.exitCode != 0 {
                self?.showAlert(
                    "録音の開始/停止に失敗しました",
                    detail: result.stderr.isEmpty ? "record.sh がエラーを返しました (exit \(result.exitCode))" : result.stderr
                )
            }
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
        NSWorkspace.shared.open(URL(fileURLWithPath: recordingsDir))
    }

    @objc private func openVaultFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: vaultMeetingsDir))
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

import AppKit
import EventKit

let idleIcon = "🎙"
let recordingIcon = "🔴"
let pausedIcon = "⏸"
let recentNotesCount = 5

// .common モードに登録しないとメニュー表示中（eventTracking）にタイマーが止まる
func makeRepeatingTimer(_ interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in block() }
    RunLoop.main.add(timer, forMode: .common)
    return timer
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

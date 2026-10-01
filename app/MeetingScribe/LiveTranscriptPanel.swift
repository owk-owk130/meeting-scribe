import AppKit

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

import AppKit
import SwiftUI

/// A floating panel that takes keyboard focus without activating Aside, so the app you were in stays in front.
final class LookupPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 200),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc reaching the responder chain (e.g. from the text field) also closes.
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class PanelController {
    let panel = LookupPanel()
    let ui = PanelUI()
    let capturer = Capturer()
    private var hosting: NSHostingView<PanelRoot>!
    private var keyMonitor: Any?
    private var placeBelow = true
    /// The fixed edge: the panel's top when it sits below the text, its bottom when above (Cocoa coordinates).
    private var edgeY: CGFloat = 0
    private var originX: CGFloat = 0
    private var screenFrame: CGRect = .zero
    private var busy = false
    private var hintTimer: Timer?
    var openSettings: () -> Void = {}
    /// Told about every successful capture (onboarding's try-it step listens).
    var onLookup: (Capture) -> Void = { _ in }

    /// What to say when a capture finds nothing.
    static func hintMode(for miss: Capturer.Miss) -> PanelUI.Mode {
        switch miss {
        case .secureField:
            return .hint(title: "That's a password field",
                         body: "Aside never reads password fields, so there's nothing to look up here.", action: nil)
        case .slow(let app):
            return .hint(title: "\(app.isEmpty ? "The app" : app) didn't answer in time",
                         body: "It may be busy. Try again in a moment, or select the text first.", action: nil)
        case .nothing:
            return .hint(title: "Nothing to look up",
                         body: "Select some text, or point at a word, then press \(Prefs.shortcut.label).", action: nil)
        }
    }

    init() {
        hosting = NSHostingView(rootView: PanelRoot(ui: ui))
        hosting.sizingOptions = []
        panel.contentView = hosting
        ui.onSize = { [weak self] size in self?.lastSize = size; self?.resize(to: size) }
        ui.onClose = { [weak self] in self?.close() }
        panel.onCancel = { [weak self] in self?.close() }
        ui.onSettings = { [weak self] in self?.close(); self?.openSettings() }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.ui.pinned, !self.busy else { return }
                self.close()
            }
        }
    }

    var isOpen: Bool { panel.isVisible }

    // MARK: Trigger

    func trigger() {
        guard !busy else { return }
        busy = true
        Engine.shared.prewarm()
        Task { @MainActor in
            defer { busy = false }
            let wasOpen = panel.isVisible
            let previous = ui.session?.capture
            if wasOpen {
                // Hand focus back so the capture reads the app underneath, not us.
                panel.orderOut(nil)
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard AXIsProcessTrusted() else {
                showHint(title: "Aside needs Accessibility access",
                         body: "It reads the text you select or point at. Nothing leaves your Mac except the words you look up and the text around them.",
                         action: "Open Accessibility Settings", sticky: true) {
                    Permissions.openAccessibility()
                }
                return
            }
            guard let cap = await capturer.capture(), !cap.term.isEmpty else {
                if wasOpen && capturer.miss == .nothing { close(); return }
                if case .hint(let title, let body, _) = Self.hintMode(for: capturer.miss) {
                    showHint(title: title, body: body)
                }
                return
            }
            onLookup(cap)
            // Same text again: the shortcut toggles the panel closed.
            if wasOpen, let previous, previous == cap {
                close()
                return
            }
            let session = LookupSession(capture: cap)
            ui.session?.cancel()
            ui.draft = ""
            ui.selected = nil
            ui.pinned = false
            ui.copied = false
            ui.mode = .lookup(session)
            session.start()
            present(anchor: cap.anchor)
        }
    }

    // MARK: Presenting

    func present(anchor: CGRect?) {
        hintTimer?.invalidate()
        closeGeneration &+= 1 // cancel a fade-out still in flight
        place(anchor: anchor)
        // SwiftUI only reports a size when it changes, so start from the last one it reported.
        let size = lastSize ?? hosting.fittingSize
        resize(to: CGSize(width: panelWidth, height: max(size.height, 160)))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        installKeys()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        ui.focusTick += 1
    }

    func showHint(title: String, body: String, action: String? = nil, sticky: Bool = false, run: (() -> Void)? = nil) {
        ui.session?.cancel()
        ui.mode = .hint(title: title, body: body, action: action)
        ui.onAction = { [weak self] in run?(); self?.close() }
        present(anchor: nil)
        hintTimer?.invalidate()
        if !sticky {
            hintTimer = Timer.scheduledTimer(withTimeInterval: 2.6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    func close() {
        hintTimer?.invalidate()
        ui.session?.cancel()
        removeKeys()
        guard panel.isVisible else { return }
        // A fade-out must always end with the window gone: an invisible panel would swallow clicks.
        closeGeneration &+= 1
        let gen = closeGeneration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.09
            panel.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.closeGeneration == gen else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
    }

    private var closeGeneration = 0
    private var lastSize: CGSize?

    /// Choose a side of the text and a fixed edge to grow from.
    private func place(anchor: CGRect?) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let mouse = NSEvent.mouseLocation
        var target: CGRect
        if let a = anchor, a.width < 4000, a.height < 2000, a.height > 0 || a.width > 0 {
            // Accessibility rects are top-left based; flip to Cocoa.
            target = CGRect(x: a.minX, y: primaryHeight - a.maxY, width: max(a.width, 1), height: max(a.height, 1))
            // A multi-line selection: anchor to the line nearest the pointer.
            if target.height > 60 { target = CGRect(x: target.minX, y: mouse.y - 10, width: target.width, height: 20) }
        } else {
            target = CGRect(x: mouse.x, y: mouse.y - 10, width: 1, height: 20)
        }
        func screen(at p: CGPoint) -> NSScreen? { NSScreen.screens.first(where: { $0.frame.contains(p) }) }
        // A rect on no screen at all (some apps report stale or off-screen bounds): use the pointer instead.
        if screen(at: CGPoint(x: target.midX, y: target.midY)) == nil {
            target = CGRect(x: mouse.x, y: mouse.y - 10, width: 1, height: 20)
        }
        guard let screen = screen(at: CGPoint(x: target.midX, y: target.midY)) ?? screen(at: mouse) ?? NSScreen.main
                ?? NSScreen.screens.first else { return }
        screenFrame = screen.visibleFrame
        let gap: CGFloat = 8
        let roomBelow = target.minY - screenFrame.minY - gap
        let roomAbove = screenFrame.maxY - target.maxY - gap
        placeBelow = roomBelow >= 300 || roomBelow >= roomAbove
        edgeY = placeBelow ? target.minY - gap : target.maxY + gap
        // Line the panel's text up with the start of the word.
        originX = min(max(target.minX - 22, screenFrame.minX + 8), screenFrame.maxX - panelWidth - 8)
        let room = (placeBelow ? roomBelow : roomAbove) - 8
        ui.maxScrollHeight = max(140, min(540, room - 110))
    }

    private func resize(to size: CGSize) {
        guard size.height > 0 else { return }
        let h = ceil(size.height)
        let y = placeBelow ? edgeY - h : edgeY
        let clampedY = min(max(y, screenFrame.minY + 4), screenFrame.maxY - h - 4)
        let frame = NSRect(x: originX, y: clampedY, width: panelWidth, height: h)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    // MARK: Keys

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if ProcessInfo.processInfo.environment["ASIDE_DEBUG"] != nil {
                NSLog("Aside key %d mods %lu window %@ panel %@", e.keyCode, e.modifierFlags.rawValue,
                      String(describing: e.window), String(describing: self?.panel))
            }
            guard let self, e.window === self.panel else { return e }
            return self.handle(e) ? nil : e
        }
    }

    private func removeKeys() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func handle(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let s = ui.session
        switch (e.keyCode, mods) {
        case (53, []): // esc
            if ui.selected != nil { ui.selected = nil; return true }
            close()
            return true
        case (18...20, [.command]): // ⌘1-3
            let i = Int(e.keyCode) - 18
            if let s, i < s.suggestions.count { ui.send(s.suggestions[i]) }
            return true
        case (125, []): // ↓ into suggestions when the input is empty
            guard ui.draft.isEmpty, let s, !s.suggestions.isEmpty else { return false }
            ui.selected = min((ui.selected ?? -1) + 1, s.suggestions.count - 1)
            return true
        case (126, []): // ↑
            guard ui.draft.isEmpty, let sel = ui.selected else { return false }
            ui.selected = sel == 0 ? nil : sel - 1
            return true
        case (8, [.command]): // ⌘C copies the answer unless text is selected
            if let tv = panel.firstResponder as? NSTextView, tv.selectedRange().length > 0 { return false }
            guard let s, let first = s.turns.first else { return false }
            var text = first.answer.plainText
            for t in s.turns.dropFirst() where t.state == .done {
                text += "\n\n" + (t.question ?? "") + "\n" + t.answer.plainText
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ui.copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.ui.copied = false }
            return true
        case (35, [.command]): // ⌘P pins the panel open
            ui.pinned.toggle()
            return true
        case (15, [.command]): // ⌘R retries a failed answer
            s?.retry()
            return true
        case (43, [.command]): // ⌘, settings
            ui.onSettings()
            return true
        default:
            if e.keyCode == 36 || e.keyCode == 76, ui.draft.isEmpty, ui.selected != nil { ui.submit(); return true }
            return false
        }
    }
}

enum Permissions {
    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
    static func openScreenRecording() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
    private static func open(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
    static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}

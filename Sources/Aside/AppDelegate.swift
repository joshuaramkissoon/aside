import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem?
    let panel = PanelController()
    private var hotkey: HotKey?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var onboarding: Onboarding?
    private var flagsMonitor: Any?
    private let lookupItem = NSMenuItem(title: "Look Up", action: #selector(lookUp), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Aside", action: #selector(togglePause), keyEquivalent: "")
    private var paused = false

    func applicationDidFinishLaunching(_ note: Notification) {
        Updater.shared.start()
        installEditMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item.button {
            let img = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: "Aside")
            img?.isTemplate = true
            b.image = img
            b.setAccessibilityLabel("Aside")
        }
        item.menu = buildMenu()
        status = item

        registerHotkey()
        Settings.shared.onShortcutChange = { [weak self] in self?.registerHotkey() }
        panel.openSettings = { [weak self] in self?.showSettings() }
        panel.onLookup = { [weak self] cap in
            // The try-it step watches for a look-up made from its own sample text.
            guard let o = self?.onboarding, o.step == .tryIt, cap.appName == "Aside" else { return }
            o.triedIt = true
        }

        Engine.shared.prewarm(force: true)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Engine.shared.prewarm(force: true)
        }
        // Chrome and Electron apps build their accessibility tree lazily: ask as soon as one comes to the front.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.panel.capturer.prime(app) }
        }
        if let front = NSWorkspace.shared.frontmostApplication { panel.capturer.prime(front) }
        // Holding the shortcut's modifier warms the connection a beat before the key lands.
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { e in
            let want: NSEvent.ModifierFlags = Prefs.shortcut == .controlSpace ? .control : .option
            if e.modifierFlags.intersection([.command, .option, .control, .shift]) == want { Engine.shared.prewarm() }
        }
        // `Aside --trigger` (for scripts and testing) runs a look-up as if the shortcut was pressed.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.jkmr.aside.trigger"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.trigger() }
        }

        if !Prefs.onboarded {
            showOnboarding(at: nil)
        } else if KeyStore.apiKey == nil || !AXIsProcessTrusted() {
            showOnboarding(at: Onboarding.firstIncomplete())
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        lookupItem.target = self
        menu.addItem(lookupItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        let about = NSMenuItem(title: "About Aside", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        if Updater.enabled {
            let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }
        menu.addItem(NSMenuItem(title: "Quit Aside", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        lookupItem.title = "Look Up"
        lookupItem.isEnabled = !paused
        // Show the shortcut the way menus do, right-aligned.
        let s = Prefs.shortcut
        lookupItem.keyEquivalent = s == .optionL ? "l" : (s == .optionSlash ? "/" : " ")
        lookupItem.keyEquivalentModifierMask = s == .controlSpace ? [.control] : [.option]
        pauseItem.title = paused ? "Resume Aside" : "Pause Aside"
        pauseItem.state = .off
    }

    func registerHotkey() {
        hotkey = nil
        guard !paused else { return }
        let s = Prefs.shortcut
        hotkey = HotKey(keyCode: s.keyCode, modifiers: s.modifiers) { [weak self] in
            MainActor.assumeIsolated { self?.panel.trigger() }
        }
        Settings.shared.shortcutFailed = hotkey == nil
    }

    @objc func lookUp() { panel.trigger() }

    /// Pausing unregisters the shortcut, so ⌥ Space goes back to whatever else wants it.
    @objc func togglePause() {
        paused.toggle()
        if paused { panel.close() }
        registerHotkey()
        status?.button?.appearsDisabled = paused
        status?.button?.setAccessibilityLabel(paused ? "Aside, paused" : "Aside")
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Aside Settings", size: SettingsView.size, view: SettingsView())
        }
        bringForward(settingsWindow)
    }

    @objc func checkForUpdates() { Updater.shared.checkForUpdates() }

    /// A menu bar app has no menu bar of its own, and text fields get ⌘V, ⌘C, ⌘X, ⌘A and ⌘Z from the main menu's
    /// key equivalents. Without this, pasting an API key in onboarding or settings silently does nothing.
    /// It's never shown. The panel's own shortcuts (⌘C copies the answer) run first, in Panel's key monitor.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Aside", action: nil, keyEquivalent: ""))  // the app menu slot
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc func showAbout() {
        if aboutWindow == nil {
            aboutWindow = makeWindow(title: "About Aside", size: CGSize(width: 320, height: 330), view: AboutView())
        }
        bringForward(aboutWindow)
    }

    func showOnboarding(at step: Onboarding.Step?) {
        let model = Onboarding(start: step)
        model.onFinish = { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            self?.onboarding = nil
        }
        onboarding = model
        let w = makeWindow(title: "Welcome to Aside", size: OnboardingView.size, view: OnboardingView(model: model))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { model.stopPolling() }
        }
        onboardingWindow = w
        bringForward(w)
    }

    private func makeWindow<V: View>(title: String, size: CGSize, view: V) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        w.center()
        return w
    }

    private func bringForward(_ w: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        w?.makeKeyAndOrderFront(nil)
    }
}

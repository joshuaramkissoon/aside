import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    let panel = PanelController()
    private var hotkey: HotKey?
    private var settingsWindow: NSWindow?
    private var flagsMonitor: Any?
    private var lookupItem: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = status.button {
            let img = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: "Aside")
            img?.isTemplate = true
            b.image = img
        }
        let menu = NSMenu()
        lookupItem = NSMenuItem(title: "Look Up  \(Prefs.shortcut.label)", action: #selector(lookUp), keyEquivalent: "")
        lookupItem.target = self
        menu.addItem(lookupItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Aside", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        status.menu = menu

        registerHotkey()
        Settings.shared.onShortcutChange = { [weak self] in self?.registerHotkey() }
        panel.openSettings = { [weak self] in self?.showSettings() }

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

        if !Prefs.onboarded || KeyStore.apiKey == nil || !AXIsProcessTrusted() {
            Prefs.onboarded = true
            showSettings()
        }
    }

    func registerHotkey() {
        hotkey = nil
        let s = Prefs.shortcut
        hotkey = HotKey(keyCode: s.keyCode, modifiers: s.modifiers) { [weak self] in
            MainActor.assumeIsolated { self?.panel.trigger() }
        }
        Settings.shared.shortcutFailed = hotkey == nil
        lookupItem?.title = "Look Up  \(s.label)"
    }

    @objc func lookUp() { panel.trigger() }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 660),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

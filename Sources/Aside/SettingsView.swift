import AppKit
import ServiceManagement
import SwiftUI

/// Preferences, in four panes under a small masthead.
struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @Environment(\.colorScheme) private var scheme

    static let size = CGSize(width: 560, height: 540)

    var body: some View {
        let c = settings.palette.swatch(scheme)
        VStack(alignment: .leading, spacing: 0) {
            masthead(c)
            Group {
                switch settings.pane {
                case .general: GeneralPane(c: c)
                case .look: LookPane(c: c)
                case .keys: KeysPane(c: c)
                case .permissions: PermissionsPane(c: c)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer(c)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(c.card)
    }

    private func masthead(_ c: Swatch) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Aside").font(.system(size: 26, weight: .semibold, design: .serif)).foregroundStyle(c.ink)
                Text(".").font(.system(size: 26, weight: .semibold, design: .serif)).foregroundStyle(c.accent)
                Spacer()
                ShortcutKeys(label: settings.shortcut.label, c: c, size: 11)
            }
            HStack(spacing: 22) {
                ForEach(SettingsPane.allCases) { p in
                    PaneTab(title: p.title, on: settings.pane == p, c: c) { settings.pane = p }
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 40)
        .overlay(alignment: .bottom) { Rectangle().fill(c.line).frame(height: 0.5) }
    }

    private func footer(_ c: Swatch) -> some View {
        HStack {
            Text(AboutView.version)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(c.faint)
            Spacer()
            Button("Quit Aside") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(c.faint)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 16)
    }
}

/// A text tab with the rubric rule under the current one.
struct PaneTab: View {
    let title: String
    let on: Bool
    let c: Swatch
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? c.ink : (hover ? c.soft : c.faint))
                .padding(.bottom, 10)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(on ? c.accent : .clear).frame(height: 2)
                }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let c: Swatch
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(c.accent)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

struct Note: View {
    let text: String
    let c: Swatch
    var warn = false
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(warn ? c.accent : c.faint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralPane: View {
    @ObservedObject var settings = Settings.shared
    let c: Swatch
    @State private var loginOn = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection(title: "Shortcut", c: c) {
                HStack(spacing: 8) {
                    ForEach(Shortcut.allCases) { s in
                        Chip(title: s.label, on: settings.shortcut == s, c: c) { settings.shortcut = s }
                    }
                }
                if settings.shortcutFailed {
                    Note(text: "Another app already uses \(settings.shortcut.label). Pick a different one.", c: c, warn: true)
                } else {
                    Note(text: "Select text, or just point at a word, and press it. Press it again to close.", c: c)
                }
            }
            SettingsSection(title: "In the panel", c: c) {
                VStack(alignment: .leading, spacing: 6) {
                    ShortcutRow(keys: "esc", text: "closes it", c: c)
                    ShortcutRow(keys: "⌘1  ⌘2  ⌘3", text: "ask a suggested follow-up (or ↓ then Return)", c: c)
                    ShortcutRow(keys: "⌘C", text: "copies the answer", c: c)
                    ShortcutRow(keys: "⌘P", text: "pins it open", c: c)
                    ShortcutRow(keys: "⌘R", text: "tries again after an error", c: c)
                }
            }
            SettingsSection(title: "Startup", c: c) {
                Toggle(isOn: $loginOn) {
                    Text("Open Aside when you log in").font(.system(size: 13)).foregroundStyle(c.ink)
                }
                .toggleStyle(.switch)
                .tint(c.accent)
                .onChange(of: loginOn) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { loginOn = SMAppService.mainApp.status == .enabled }
                }
            }
        }
    }
}

private struct LookPane: View {
    @ObservedObject var settings = Settings.shared
    let c: Swatch
    var body: some View {
        SettingsSection(title: "Palette", c: c) {
            HStack(spacing: 12) {
                ForEach(Palette.all) { p in
                    PaletteCard(palette: p, on: settings.theme == p.id) { settings.theme = p.id }
                }
            }
            Note(text: settings.palette.note + " Follows your Mac's light or dark mode.", c: c)
        }
    }
}

private struct KeysPane: View {
    @ObservedObject var settings = Settings.shared
    let c: Swatch
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            KeyField(name: .together, title: "Together API key", link: ("Get a key at api.together.ai", "https://api.together.ai/settings/api-keys"),
                     testable: true, c: c)
            Note(text: "Answers come from \(settings.model.split(separator: "/").last.map(String.init) ?? settings.model) on Together, with thinking off for speed. Only the text you look up and the words around it are sent.", c: c)
            KeyField(name: .gemini, title: "Gemini API key, optional",
                     link: ("For things the model hasn't heard of: Aside checks the web first. Get one at aistudio.google.com", "https://aistudio.google.com/apikey"),
                     testable: false, c: c)
            Note(text: "Keys are kept in ~/Library/Application Support/Aside, readable only by you.", c: c)
        }
    }
}

private struct PermissionsPane: View {
    let c: Swatch
    @State private var axOK = AXIsProcessTrusted()
    @State private var screenOK = CGPreflightScreenCaptureAccess()
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PermissionRow(title: "Accessibility", detail: "Required. Reads the text you select or point at.", ok: axOK, c: c) {
                Permissions.promptAccessibility()
                Permissions.openAccessibility()
            }
            PermissionRow(title: "Screen Recording", detail: "Optional. Reads text from apps that hide it, like some terminals.", ok: screenOK, c: c) {
                CGRequestScreenCaptureAccess()
                Permissions.openScreenRecording()
            }
            Note(text: "Aside never reads password fields, and only reads anything when you press the shortcut.", c: c)
                .padding(.top, 6)
        }
        .onReceive(poll) { _ in
            axOK = AXIsProcessTrusted()
            screenOK = CGPreflightScreenCaptureAccess()
        }
    }
}

struct Chip: View {
    let title: String
    let on: Bool
    let c: Swatch
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(on ? c.card : c.soft)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(on ? c.accent : c.codeBg))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

struct PaletteCard: View {
    let palette: Palette
    let on: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = palette.swatch(scheme)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("fsync").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(s.ink)
                        Spacer()
                        Text("CALL").font(.system(size: 7, weight: .bold)).tracking(1).foregroundStyle(s.accent)
                    }
                    Text(Rich.attributed("Forces data to ==physical disk==.", size: 10.5, serif: true, base: s.soft, strong: s.ink, c: s))
                        .lineLimit(1)
                    Capsule().fill(s.accent).frame(width: 12, height: 1.5).padding(.top, 2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(s.card))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(on ? s.accent : Color.primary.opacity(0.1), lineWidth: on ? 1.5 : 0.5))
                Text(palette.name)
                    .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(Color.primary.opacity(on ? 0.9 : 0.55))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(palette.name) palette")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let ok: Bool
    let c: Swatch
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 15))
                .foregroundStyle(ok ? c.accent : c.faint)
                .accessibilityLabel(ok ? "Allowed" : "Not allowed")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(c.ink)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(c.faint).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !ok { PillButton(title: "Allow", c: c, action: action) }
        }
    }
}

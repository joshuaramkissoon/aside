import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @Environment(\.colorScheme) private var scheme
    @State private var keyDraft = ""
    @State private var hasKey = KeyStore.apiKey != nil
    @State private var testResult: String? = nil
    @State private var testing = false
    @State private var axOK = AXIsProcessTrusted()
    @State private var screenOK = CGPreflightScreenCaptureAccess()
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let c = settings.palette.swatch(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero(c)
                section("Shortcut", c) {
                    HStack(spacing: 8) {
                        ForEach(Shortcut.allCases) { s in
                            Chip(title: s.label, on: settings.shortcut == s, c: c) { settings.shortcut = s }
                        }
                    }
                    if settings.shortcutFailed {
                        note("Another app already uses \(settings.shortcut.label). Pick a different one.", c, warn: true)
                    } else {
                        note("Select text, or just point at a word, and press it. Press it again to close.", c)
                    }
                }
                section("Look", c) {
                    HStack(spacing: 12) {
                        ForEach(Palette.all) { p in
                            PaletteCard(palette: p, on: settings.theme == p.id) { settings.theme = p.id }
                        }
                    }
                    note(settings.palette.note + " Follows your Mac's light or dark mode.", c)
                }
                section("Together API key", c) {
                    HStack(spacing: 8) {
                        SecureField(hasKey ? "Saved on this Mac" : "Paste your key", text: $keyDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(c.codeBg))
                            .onSubmit(saveKey)
                        if !keyDraft.isEmpty {
                            PillButton(title: "Save", c: c, action: saveKey)
                        } else if hasKey {
                            PillButton(title: testing ? "Testing…" : "Test", c: c, action: test)
                        }
                    }
                    if let testResult { note(testResult, c) }
                    else { note("Answers come from \(settings.model.split(separator: "/").last.map(String.init) ?? settings.model) on Together, with thinking off for speed. Only the text you look up and the words around it are sent.", c) }
                }
                section("Permissions", c) {
                    PermissionRow(title: "Accessibility", detail: "Required. Reads the text you select or point at.", ok: axOK, c: c) {
                        Permissions.promptAccessibility()
                        Permissions.openAccessibility()
                    }
                    PermissionRow(title: "Screen Recording", detail: "Optional. Reads text from apps that hide it, like some terminals.", ok: screenOK, c: c) {
                        CGRequestScreenCaptureAccess()
                        Permissions.openScreenRecording()
                    }
                }
                section("General", c) {
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
                HStack {
                    Text("Esc closes · ⌘1–3 asks a suggestion · ↓ picks one · ⌘C copies · ⌘P pins")
                        .font(.system(size: 11))
                        .foregroundStyle(c.faint)
                    Spacer()
                    Button("Quit Aside") { NSApp.terminate(nil) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(c.faint)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 44)
            .padding(.bottom, 26)
        }
        .frame(width: 540, height: 660)
        .background(c.card)
        .onReceive(poll) { _ in
            axOK = AXIsProcessTrusted()
            screenOK = CGPreflightScreenCaptureAccess()
        }
    }

    private func hero(_ c: Swatch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Aside").font(.system(size: 34, weight: .semibold, design: .serif)).foregroundStyle(c.ink)
                Text(".").font(.system(size: 34, weight: .semibold, design: .serif)).foregroundStyle(c.accent)
            }
            Text(Rich.attributed("Point at anything on your Mac and see what it ==means right there==, then keep asking.",
                                 size: 16, serif: true, base: c.soft, strong: c.ink, c: c))
                .lineSpacing(3)
            HStack(spacing: 6) {
                ForEach(settings.shortcut.label.split(separator: " ").map(String.init), id: \.self) { k in
                    Text(k)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(c.ink)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.codeBg))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(c.line, lineWidth: 1))
                }
            }
            .padding(.top, 4)
        }
    }

    private func section<Content: View>(_ title: String, _ c: Swatch, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(c.accent)
            content()
        }
    }

    private func note(_ text: String, _ c: Swatch, warn: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(warn ? c.accent : c.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func saveKey() {
        guard let k = keyDraft.nonEmpty else { return }
        KeyStore.save(k)
        keyDraft = ""
        hasKey = true
        test()
    }

    private func test() {
        testing = true
        testResult = nil
        let t0 = CFAbsoluteTimeGetCurrent()
        Task { @MainActor in
            var first: Double?
            do {
                for try await _ in Engine.shared.stream([["role": "user", "content": "Say ok."]], maxTokens: 3) {
                    if first == nil { first = CFAbsoluteTimeGetCurrent() - t0 }
                }
                testResult = String(format: "Working. First word in %.2fs.", first ?? 0)
            } catch {
                testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            testing = false
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
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(c.ink)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(c.faint)
            }
            Spacer()
            if !ok { PillButton(title: "Allow", c: c, action: action) }
        }
    }
}

import AppKit
import ServiceManagement
import SwiftUI

/// First run: welcome, Accessibility, Screen Recording, keys, a place to try it, and done.
@MainActor
final class Onboarding: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, accessibility, screen, keys, tryIt, done
        var label: String {
            switch self {
            case .welcome: return "Welcome"
            case .accessibility: return "Accessibility"
            case .screen: return "Screen Recording"
            case .keys: return "Keys"
            case .tryIt: return "Try it"
            case .done: return "Done"
            }
        }
    }

    @Published var step: Step { didSet { UserDefaults.standard.set(step.rawValue, forKey: "onboardingStep") } }
    @Published var axOK = AXIsProcessTrusted()
    @Published var screenOK = CGPreflightScreenCaptureAccess()
    @Published var hasKey = KeyStore.apiKey != nil
    @Published var hasGemini = KeyStore.get(.gemini) != nil
    /// Set when a look-up happens from the try-it text.
    @Published var triedIt = false
    @Published var launchAtLogin = true
    /// Off for screenshots, which pin the permission state.
    var polls = true
    var onFinish: () -> Void = {}
    private var timer: Timer?

    init(start: Step? = nil) {
        let saved = Step(rawValue: UserDefaults.standard.integer(forKey: "onboardingStep")) ?? .welcome
        step = start ?? saved
    }

    /// Where a returning user who is missing something should land.
    static func firstIncomplete() -> Step {
        if !AXIsProcessTrusted() { return .accessibility }
        if KeyStore.apiKey == nil { return .keys }
        return .welcome
    }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    private func poll() {
        let ax = AXIsProcessTrusted()
        if ax && !axOK && step == .accessibility {
            axOK = true
            // Granted: show the tick for a beat, then move on by itself.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, self.step == .accessibility else { return }
                self.advance()
            }
        }
        axOK = ax
        screenOK = CGPreflightScreenCaptureAccess()
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { finish(); return }
        step = next
    }

    func back() {
        if let prev = Step(rawValue: step.rawValue - 1) { step = prev }
    }

    func finish() {
        if launchAtLogin, SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        Prefs.onboarded = true
        UserDefaults.standard.removeObject(forKey: "onboardingStep")
        stopPolling()
        onFinish()
    }
}

struct OnboardingView: View {
    @ObservedObject var model: Onboarding
    @ObservedObject var settings = Settings.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 640, height: 500)

    var body: some View {
        let c = settings.palette.swatch(scheme)
        VStack(alignment: .leading, spacing: 0) {
            StepRail(step: model.step, c: c)
                .padding(.top, 38)
                .padding(.horizontal, 44)
            Group {
                switch model.step {
                case .welcome: WelcomeStep(c: c)
                case .accessibility: AccessibilityStep(model: model, c: c)
                case .screen: ScreenStep(model: model, c: c)
                case .keys: KeysStep(model: model, c: c)
                case .tryIt: TryStep(model: model, c: c)
                case .done: DoneStep(model: model, c: c)
                }
            }
            .padding(.horizontal, 44)
            .padding(.top, 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(model.step)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 14)), removal: .opacity))
            footer(c)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(c.card)
        .focusEffectDisabled()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.step)
        .onAppear { if model.polls { model.startPolling() } }
    }

    private func footer(_ c: Swatch) -> some View {
        HStack(spacing: 14) {
            if model.step != .welcome && model.step != .done {
                Button("Back") { model.back() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(c.faint)
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
            }
            Spacer()
            switch model.step {
            case .welcome:
                PrimaryButton(title: "Set up Aside", c: c) { model.advance() }
            case .accessibility:
                if model.axOK { PrimaryButton(title: "Continue", c: c) { model.advance() } }
                else { PrimaryButton(title: "Open System Settings", c: c) { Permissions.promptAccessibility(); Permissions.openAccessibility() } }
            case .screen:
                if !model.screenOK { QuietButton(title: "Skip", c: c) { model.advance() } }
                PrimaryButton(title: model.screenOK ? "Continue" : "Allow Screen Recording", c: c) {
                    if model.screenOK { model.advance() } else { CGRequestScreenCaptureAccess(); Permissions.openScreenRecording() }
                }
            case .keys:
                if !model.hasKey { QuietButton(title: "Skip for now", c: c) { model.advance() } }
                PrimaryButton(title: "Continue", c: c, enabled: model.hasKey) { model.advance() }
            case .tryIt:
                if !model.triedIt { QuietButton(title: "Skip", c: c) { model.advance() } }
                PrimaryButton(title: "Continue", c: c, enabled: model.triedIt) { model.advance() }
            case .done:
                PrimaryButton(title: "Start using Aside", c: c) { model.finish() }
            }
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 20)
        .overlay(alignment: .top) { Rectangle().fill(c.line).frame(height: 0.5) }
    }
}

/// "2 of 6 · Accessibility" over a hairline that fills as you go.
struct StepRail: View {
    let step: Onboarding.Step
    let c: Swatch

    var body: some View {
        let total = Onboarding.Step.allCases.count
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 0) {
                Text("\(step.rawValue + 1) OF \(total)")
                    .foregroundStyle(c.accent)
                Text("  ·  " + step.label.uppercased())
                    .foregroundStyle(c.faint)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(1.3)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(c.line)
                    Capsule().fill(c.accent)
                        .frame(width: g.size.width * CGFloat(step.rawValue + 1) / CGFloat(total))
                }
            }
            .frame(height: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(total): \(step.label)")
    }
}

// MARK: - Steps

private struct Headline: View {
    let text: String
    let c: Swatch
    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .semibold, design: .serif))
            .foregroundStyle(c.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct Lede: View {
    let text: String
    let c: Swatch
    var body: some View {
        Text(Rich.attributed(text, size: 14.5, serif: false, base: c.soft, strong: c.ink, c: c))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct WelcomeStep: View {
    let c: Swatch
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Aside").font(.system(size: 44, weight: .semibold, design: .serif)).foregroundStyle(c.ink)
                Text(".").font(.system(size: 44, weight: .semibold, design: .serif)).foregroundStyle(c.accent)
            }
            Text(Rich.attributed("Point at anything on your Mac and see what it ==means right there==, then keep asking.",
                                 size: 19, serif: true, base: c.soft, strong: c.ink, c: c))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 26) {
                SpecimenCard(c: c)
                VStack(alignment: .leading, spacing: 12) {
                    point("Select a word or a sentence, or just point at one.")
                    point("Press \(Settings.shared.shortcut.label). The answer fits what's around it.")
                    point("Type to ask more. Esc to put it away.")
                }
                .padding(.top, 6)
            }
            .padding(.top, 14)
        }
    }

    private func point(_ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle().fill(c.accent.opacity(0.75)).frame(width: 4, height: 4)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 4 }
            Text(s).font(.system(size: 13)).foregroundStyle(c.soft).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A small printed sample of the panel: what you'll get.
struct SpecimenCard: View {
    let c: Swatch
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Claude  write vs flush vs fsync")
                .font(.system(size: 9.5).italic())
                .foregroundStyle(c.faint)
            HStack(alignment: .firstTextBaseline) {
                Text("flush").font(.system(size: 20, weight: .semibold, design: .serif)).foregroundStyle(c.ink)
                Spacer()
                Text("I/O OPERATION").font(.system(size: 7.5, weight: .semibold)).tracking(1.1).foregroundStyle(c.accent)
            }
            Text(Rich.attributed("Hands buffered writes to the OS, but does ==not guarantee they reach disk==.",
                                 size: 12.5, serif: true, base: c.ink, strong: c.ink, c: c))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Capsule().fill(c.accent.opacity(0.85)).frame(width: 14, height: 1.5).padding(.top, 2)
        }
        .padding(14)
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.codeBg.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.line, lineWidth: 0.75))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: flush, an I/O operation. Hands buffered writes to the OS, but does not guarantee they reach disk.")
    }
}

private struct AccessibilityStep: View {
    @ObservedObject var model: Onboarding
    let c: Swatch
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Headline(text: "Let Aside read what you point at", c: c)
            Lede(text: "Aside uses **Accessibility** to read the words you select or point at, and the text around them. It only reads when you press the shortcut.", c: c)
            SettingsMock(app: "Aside", pane: "Accessibility", on: model.axOK, c: c)
                .padding(.top, 8)
            StatusLine(ok: model.axOK, waiting: "Waiting for you to switch Aside on…", done: "Access granted. Moving on.", c: c)
        }
    }
}

private struct ScreenStep: View {
    @ObservedObject var model: Onboarding
    let c: Swatch
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Headline(text: "For apps that hide their text", c: c)
            Lede(text: "A few apps draw text that Accessibility can't see, like some terminals and games. With **Screen Recording**, Aside reads the words around the pointer using on-device text recognition. Nothing is saved or sent as an image.", c: c)
            Lede(text: "This is optional. Most apps work without it.", c: c)
            SettingsMock(app: "Aside", pane: "Screen & System Audio Recording", on: model.screenOK, c: c)
                .padding(.top, 4)
            StatusLine(ok: model.screenOK, waiting: "If macOS asks to reopen Aside, say yes: setup carries on where you left it.",
                       done: "Screen Recording is on.", c: c, waitingIcon: "info.circle")
        }
    }
}

private struct KeysStep: View {
    @ObservedObject var model: Onboarding
    let c: Swatch
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Headline(text: "Connect a model", c: c)
            Lede(text: "Aside answers with DeepSeek on **Together**, with thinking off, so the first words land in about a third of a second. Your key stays in a file on this Mac that only you can read.", c: c)
            KeyField(name: .together, title: "Together API key", link: ("Get a key at api.together.ai", "https://api.together.ai/settings/api-keys"),
                     testable: true, c: c) { model.hasKey = $0 }
                .padding(.top, 6)
            Lede(text: "When the model hasn't heard of something, Aside looks it up on Wikipedia first. No extra key needed.", c: c)
        }
    }
}

private struct TryStep: View {
    @ObservedObject var model: Onboarding
    @ObservedObject var settings = Settings.shared
    let c: Swatch

    static let sample = "Before it confirms a commit, the database appends the record to its write-ahead log and calls fsync, so a power cut can't take it with the page cache. Readers carry on from an MVCC snapshot in the meantime, and never wait on the writer."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Headline(text: "Try it here", c: c)
            Lede(text: "Point at a word below, like **fsync**, and press **\(settings.shortcut.label)**. Or select a whole phrase first.", c: c)
            SampleText(text: Self.sample, hints: ["fsync", "write-ahead log", "MVCC"], c: c)
                .frame(height: 108)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.codeBg.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.line, lineWidth: 0.75))
                .padding(.top, 6)
            StatusLine(ok: model.triedIt, waiting: "The underlined words are good ones to start with.",
                       done: "That's it. Ask a follow-up in the panel, or press Esc to close it.", c: c, waitingIcon: "hand.point.up.left")
        }
    }
}

private struct DoneStep: View {
    @ObservedObject var model: Onboarding
    @ObservedObject var settings = Settings.shared
    let c: Swatch
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Headline(text: "You're set", c: c)
            Lede(text: "Aside lives in your menu bar. Press the shortcut in any app, on any word.", c: c)
            ShortcutKeys(label: settings.shortcut.label, c: c, size: 15)
                .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 7) {
                ShortcutRow(keys: "esc", text: "closes the panel", c: c)
                ShortcutRow(keys: "⌘1  ⌘2", text: "ask a suggested follow-up", c: c)
                ShortcutRow(keys: "⌘C", text: "copies the answer", c: c)
                ShortcutRow(keys: "⌘P", text: "pins the panel open", c: c)
            }
            Toggle(isOn: $model.launchAtLogin) {
                Text("Open Aside when you log in").font(.system(size: 13)).foregroundStyle(c.ink)
            }
            .toggleStyle(.switch)
            .tint(c.accent)
            .padding(.top, 10)
        }
    }
}

// MARK: - Pieces

/// A drawing of the System Settings list, with Aside's switch picked out, so it's obvious what to flip.
struct SettingsMock: View {
    let app: String
    let pane: String
    let on: Bool
    let c: Swatch
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(c.faint)
                Text("Privacy & Security  ›  \(pane)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(c.faint)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Rectangle().fill(c.line).frame(height: 0.5)
            row(name: "Terminal", on: true, dim: true)
            Rectangle().fill(c.line).frame(height: 0.5).padding(.leading, 44)
            row(name: app, on: on, dim: false)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.codeBg.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(c.line, lineWidth: 0.75))
        .frame(maxWidth: 420)
        .onAppear { glow = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In System Settings, Privacy and Security, \(pane): switch \(app) on. \(on ? "It's on." : "It's off.")")
    }

    private func row(name: String, on: Bool, dim: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if name == "Aside" { MiniIcon() }
                else { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.line).frame(width: 20, height: 20) }
            }
            Text(name).font(.system(size: 12.5, weight: dim ? .regular : .semibold)).foregroundStyle(dim ? c.faint : c.ink)
            Spacer()
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? c.accent : c.line).frame(width: 30, height: 17)
                Circle().fill(Color.white).frame(width: 13, height: 13).padding(2).shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            }
            .opacity(dim ? 0.45 : 1)
            .overlay {
                if !dim && !on {
                    Capsule().strokeBorder(c.accent, lineWidth: 1.5)
                        .frame(width: 40, height: 27)
                        .opacity(reduceMotion ? 0.9 : (glow ? 0.95 : 0.25))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: glow)
                }
            }
            .animation(.easeOut(duration: 0.25), value: on)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

/// The app icon drawn small enough for a list row: dark card, serif "a", the highlighter under it.
struct MiniIcon: View {
    var body: some View {
        let s = Palette.named("rubric").dark
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x2A241E), Color(hex: 0x1A1612)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(s.accent.opacity(0.92))
                .frame(width: 12, height: 3)
                .rotationEffect(.degrees(-3.5))
                .offset(y: 4.5)
            Text("a")
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(s.ink)
                .offset(y: -1.5)
        }
        .frame(width: 22, height: 22)
    }
}

struct StatusLine: View {
    let ok: Bool
    let waiting: String
    let done: String
    let c: Swatch
    var waitingIcon = "circle.dashed"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : waitingIcon)
                .font(.system(size: 13))
                .foregroundStyle(ok ? c.accent : c.faint)
            Text(ok ? done : waiting)
                .font(.system(size: 12.5))
                .foregroundStyle(ok ? c.ink : c.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeOut(duration: 0.2), value: ok)
        .accessibilityElement(children: .combine)
    }
}

/// Paste, save and (for Together) test an API key. Never shows a saved key.
struct KeyField: View {
    let name: KeyStore.Name
    let title: String
    let link: (String, String)
    let testable: Bool
    let c: Swatch
    var onChange: (Bool) -> Void = { _ in }
    @State private var draft = ""
    @State private var saved: Bool
    @State private var result: (ok: Bool, text: String)? = nil
    @State private var testing = false

    init(name: KeyStore.Name, title: String, link: (String, String), testable: Bool, c: Swatch, onChange: @escaping (Bool) -> Void = { _ in }) {
        self.name = name
        self.title = title
        self.link = link
        self.testable = testable
        self.c = c
        self.onChange = onChange
        _saved = State(initialValue: KeyStore.get(name) != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(c.faint)
            HStack(spacing: 8) {
                SecureField(saved ? "Saved on this Mac" : "Paste your key", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.codeBg))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(c.line, lineWidth: 0.75))
                    .onSubmit(save)
                    .accessibilityLabel(title)
                if !draft.isEmpty {
                    PillButton(title: "Save", c: c, action: save)
                } else if saved {
                    if testable { PillButton(title: testing ? "Testing…" : "Test", c: c, action: test) }
                    PillButton(title: "Remove", c: c, action: remove)
                }
            }
            if let result {
                Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(result.ok ? c.accent : c.soft)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let url = URL(string: link.1) {
                Link(destination: url) {
                    Text("\(link.0) \(Image(systemName: "arrow.up.right"))")
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .foregroundStyle(c.faint)
            }
        }
    }

    private func save() {
        guard let k = draft.nonEmpty else { return }
        KeyStore.save(k, as: name)
        draft = ""
        saved = true
        onChange(true)
        if testable { test() } else { result = (true, "Saved.") }
    }

    private func remove() {
        KeyStore.save("", as: name)
        saved = false
        result = nil
        onChange(false)
    }

    private func test() {
        testing = true
        result = nil
        let t0 = CFAbsoluteTimeGetCurrent()
        Task { @MainActor in
            var first: Double?
            do {
                for try await _ in Engine.shared.stream([["role": "user", "content": "Say ok."]], maxTokens: 3) {
                    if first == nil { first = CFAbsoluteTimeGetCurrent() - t0 }
                }
                result = (true, String(format: "Working. First word in %.2fs.", first ?? 0))
            } catch {
                let f = Failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                result = (false, f.kind == .other ? f.detail : f.title + ". " + f.body)
            }
            testing = false
        }
    }
}

/// The shortcut drawn as keycaps.
struct ShortcutKeys: View {
    let label: String
    let c: Swatch
    var size: CGFloat = 13
    var body: some View {
        HStack(spacing: 6) {
            ForEach(label.split(separator: " ").map(String.init), id: \.self) { k in
                Text(k)
                    .font(.system(size: size, weight: .medium, design: .rounded))
                    .foregroundStyle(c.ink)
                    .padding(.horizontal, size * 0.8).padding(.vertical, size * 0.4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.codeBg))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(c.line, lineWidth: 1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shortcut: \(label.replacingOccurrences(of: "⌥", with: "Option").replacingOccurrences(of: "⌃", with: "Control"))")
    }
}

struct ShortcutRow: View {
    let keys: String
    let text: String
    let c: Swatch
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(c.ink)
                .frame(width: 64, alignment: .leading)
            Text(text).font(.system(size: 12.5)).foregroundStyle(c.soft)
        }
    }
}

struct PrimaryButton: View {
    let title: String
    let c: Swatch
    var enabled = true
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(c.card)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(c.accent.opacity(enabled ? (hover ? 0.88 : 1) : 0.35)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .keyboardShortcut(.defaultAction)
    }
}

struct QuietButton: View {
    let title: String
    let c: Swatch
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(c.soft)
    }
}

/// Sample text in a real, selectable text view, so Aside's own capture can read it like any other app's.
struct SampleText: NSViewRepresentable {
    let text: String
    let hints: [String]
    let c: Swatch

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.setAccessibilityLabel("Sample text to try Aside on")
        update(tv)
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) { update(tv) }

    private func update(_ tv: NSTextView) {
        let base = NSFont.systemFont(ofSize: 16.5)
        let font = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 16.5) } ?? base
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 5
        let s = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(c.ink), .paragraphStyle: para])
        for h in hints {
            let r = (text as NSString).range(of: h)
            if r.location != NSNotFound {
                s.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                 .underlineColor: NSColor(c.accent)], range: r)
            }
        }
        if tv.attributedString() != s { tv.textStorage?.setAttributedString(s) }
        tv.selectedTextAttributes = [.backgroundColor: NSColor(c.mark), .foregroundColor: NSColor(c.markInk)]
    }
}

// MARK: - About

struct AboutView: View {
    @ObservedObject var settings = Settings.shared
    @Environment(\.colorScheme) private var scheme

    static var version: String {
        let info = Bundle.main.infoDictionary
        guard let v = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        let b = info?["CFBundleVersion"] as? String
        return "Version \(v)" + (b.map { " (\($0))" } ?? "")
    }

    var body: some View {
        let c = settings.palette.swatch(scheme)
        VStack(spacing: 10) {
            AppIconArt().frame(width: 1024, height: 1024).scaleEffect(96.0 / 1024).frame(width: 96, height: 96)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Aside").font(.system(size: 28, weight: .semibold, design: .serif)).foregroundStyle(c.ink)
                Text(".").font(.system(size: 28, weight: .semibold, design: .serif)).foregroundStyle(c.accent)
            }
            .padding(.top, 2)
            Text(Self.version)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(c.faint)
                .textSelection(.enabled)
            Text(Rich.attributed("Look anything up, ==in context==.", size: 14, serif: true, base: c.soft, strong: c.ink, c: c))
                .padding(.top, 6)
            Text("Made by Joshua Ramkissoon. MIT licence.")
                .font(.system(size: 11))
                .foregroundStyle(c.faint)
                .padding(.top, 8)
        }
        .padding(.top, 34)
        .padding(.bottom, 26)
        .frame(width: 320)
        .background(c.card)
    }
}

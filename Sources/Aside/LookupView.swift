import AppKit
import SwiftUI

/// UI state the panel controller and the view share.
@MainActor
final class PanelUI: ObservableObject {
    enum Mode {
        case lookup(LookupSession)
        case hint(title: String, body: String, action: String?)
    }

    @Published var mode: Mode = .hint(title: "", body: "", action: nil)
    @Published var draft = ""
    @Published var selected: Int? = nil
    @Published var pinned = false
    @Published var copied = false
    @Published var maxScrollHeight: CGFloat = 520
    var snapshot = false
    /// Bumped to pull focus back to the input.
    @Published var focusTick = 0

    var onSize: (CGSize) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onAction: () -> Void = {}
    var onSettings: () -> Void = {}

    var session: LookupSession? {
        if case .lookup(let s) = mode { return s }
        return nil
    }

    func send(_ text: String) {
        guard let s = session else { return }
        let q = text.trimmed
        guard !q.isEmpty, !s.isBusy else { return }
        s.ask(q)
        draft = ""
        selected = nil
    }

    func submit() {
        if draft.trimmed.isEmpty {
            if let i = selected, let s = session, i < s.suggestions.count { send(s.suggestions[i]) }
            return
        }
        send(draft)
    }
}

let panelWidth: CGFloat = 448

struct PanelRoot: View {
    @ObservedObject var ui: PanelUI
    @ObservedObject var settings = Settings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = settings.palette.swatch(scheme)
        Group {
            switch ui.mode {
            case .lookup(let s): LookupView(session: s, ui: ui)
            case .hint(let title, let body, let action): HintView(title: title, message: body, action: action, ui: ui)
            }
        }
        .frame(width: panelWidth)
        .background(CardBackground(color: c.card, snapshot: ui.snapshot))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08), lineWidth: 0.5)
        )
        // Always take the ideal height, whatever the window currently is, and report it so the window can follow.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { ui.onSize($0) }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Look-up

struct LookupView: View {
    @ObservedObject var session: LookupSession
    @ObservedObject var ui: PanelUI
    @ObservedObject var settings = Settings.shared
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let c = settings.palette.swatch(scheme)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        Eyebrow(capture: session.capture, ms: session.turns.first?.firstTokenMs, pinned: ui.pinned, copied: ui.copied, c: c)
                        TitleBlock(session: session, c: c)
                            .padding(.top, 9)
                        ForEach(Array(session.turns.enumerated()), id: \.element.id) { i, turn in
                            TurnView(turn: turn, first: i == 0, c: c, ui: ui, retry: { session.retry() })
                                .id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 15)
                    .padding(.bottom, 16)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollIndicators(contentHeight > ui.maxScrollHeight ? .automatic : .never)
                .frame(height: max(80, min(contentHeight, ui.maxScrollHeight)))
                .onChange(of: session.turns.last?.raw) {
                    if session.turns.count > 1 { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: session.turns.count) {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }

            if !session.suggestions.isEmpty {
                Suggestions(items: session.suggestions, ui: ui, c: c)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }

            InputBar(ui: ui, busy: session.isBusy, c: c, focused: $focused)
        }
        .animation(.easeOut(duration: 0.18), value: session.suggestions)
        .onAppear { focused = true }
        .onChange(of: ui.focusTick) { focused = true }
    }
}

struct Eyebrow: View {
    let capture: Capture
    let ms: Double?
    let pinned: Bool
    let copied: Bool
    let c: Swatch

    var body: some View {
        HStack(spacing: 6) {
            AppIcon(bundleID: capture.bundleID)
                .frame(width: 13, height: 13)
            snippetText
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            if copied {
                Label("Copied", systemImage: "checkmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(c.accent)
                    .transition(.opacity)
            } else if pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(c.accent)
                    .help("Pinned (⌘P)")
            }
            if let ms, ms > 0 {
                Text(String(format: "%.2fs", ms / 1000))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(c.faint.opacity(0.8))
                    .help("Time to first word")
            }
        }
        .animation(.easeOut(duration: 0.15), value: copied)
    }

    private var snippetText: Text {
        let app = Text(capture.appName.isEmpty ? "Selection" : capture.appName).foregroundColor(c.faint).fontWeight(.medium)
        guard let s = ContextText.snippet(capture, maxLen: 64) else { return app }
        return app
            + Text("  ").foregroundColor(c.faint)
            + Text(s.before).italic().foregroundColor(c.faint)
            + Text(s.term).italic().fontWeight(.semibold).foregroundColor(c.soft)
            + Text(s.after).italic().foregroundColor(c.faint)
    }
}

struct TitleBlock: View {
    @ObservedObject var session: LookupSession
    let c: Swatch

    var body: some View {
        let a = session.turns.first?.answer ?? Answer()
        let title = a.term ?? session.capture.term
        let long = title.count > 38
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.system(size: long ? 19 : 26, weight: .semibold, design: .serif))
                    .foregroundStyle(c.ink)
                    .lineLimit(long ? 2 : 1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.opacity)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if let kind = a.kind {
                    Text(kind.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(1.3)
                        .foregroundStyle(c.accent)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            if let ex = a.expands {
                Expansion(text: ex, c: c)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: a.kind)
        .animation(.easeOut(duration: 0.18), value: title)
    }
}

/// "Least Recently Used" with the initials picked out, so the acronym reads itself.
struct Expansion: View {
    let text: String
    let c: Swatch

    var body: some View {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        var t = Text("")
        for (i, w) in words.enumerated() {
            if i > 0 { t = t + Text(" ") }
            if let f = w.first, f.isUppercase || f.isNumber {
                t = t + Text(String(f)).foregroundColor(c.accent).fontWeight(.semibold)
                    + Text(String(w.dropFirst())).foregroundColor(c.soft)
            } else {
                t = t + Text(String(w)).foregroundColor(c.soft)
            }
        }
        return t.font(.system(size: 15, design: .serif).italic())
    }
}

struct TurnView: View {
    let turn: LookupSession.Turn
    let first: Bool
    let c: Swatch
    @ObservedObject var ui: PanelUI
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let q = turn.question {
                Rectangle().fill(c.line).frame(height: 0.5).padding(.top, 18).padding(.bottom, 14)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(c.accent)
                    Text(q)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(c.soft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 7)
            }

            switch turn.state {
            case .failed(let message):
                ErrorRow(message: message, c: c, retry: retry, settings: ui.onSettings)
                    .padding(.top, first ? 12 : 2)
            default:
                if turn.answer.gist.isEmpty {
                    Skeleton(c: c, big: first)
                        .padding(.top, first ? 13 : 3)
                } else {
                    Text(Rich.attributed(turn.answer.gist, size: first ? 17 : 15.5, serif: true, base: c.ink, strong: c.ink, c: c))
                        .lineSpacing(first ? 3.5 : 2.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.top, first ? 11 : 0)
                }
                if !turn.answer.blocks.isEmpty {
                    if first {
                        Capsule().fill(c.accent.opacity(0.85)).frame(width: 18, height: 2)
                            .padding(.top, 14).padding(.bottom, 12)
                    } else {
                        Color.clear.frame(height: 10)
                    }
                    Blocks(blocks: turn.answer.blocks, c: c)
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: turn.answer.blocks.count)
    }
}

struct Blocks: View {
    let blocks: [Answer.Block]
    let c: Swatch

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle().fill(c.accent.opacity(0.75)).frame(width: 4, height: 4)
                            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 4 }
                        Text(Rich.attributed(s, size: 13.5, serif: false, base: c.soft, strong: c.ink, c: c))
                            .lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                case .para(let s):
                    Text(Rich.attributed(s, size: 13.5, serif: false, base: c.soft, strong: c.ink, c: c))
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .code(let s):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(s)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(c.ink)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                    }
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.codeBg))
                }
            }
        }
    }
}

struct Suggestions: View {
    let items: [String]
    @ObservedObject var ui: PanelUI
    let c: Swatch
    @State private var hover: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                let lit = ui.selected == i || hover == i
                Button { ui.send(s) } label: {
                    HStack(spacing: 10) {
                        Text("⌘\(i + 1)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(lit ? c.accent : c.faint)
                            .frame(width: 22, alignment: .leading)
                        Text(s)
                            .font(.system(size: 13))
                            .foregroundStyle(lit ? c.ink : c.soft)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if ui.selected == i {
                            Image(systemName: "return")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(c.accent)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lit ? c.accent.opacity(0.09) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 ? i : (hover == i ? nil : hover) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

struct InputBar: View {
    @ObservedObject var ui: PanelUI
    let busy: Bool
    let c: Swatch
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(c.accent)
            TextField("", text: $ui.draft, prompt: Text("Ask a follow-up").foregroundColor(c.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(c.ink)
                .focused(focused)
                .tint(c.accent)
                .onSubmit { ui.submit() }
            if busy {
                Pulse(c: c)
            } else if !ui.draft.trimmed.isEmpty {
                Keycap(text: "↵", c: c)
            } else {
                Keycap(text: "esc", c: c)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(c.codeBg.opacity(0.55))
        .overlay(alignment: .top) { Rectangle().fill(c.line).frame(height: 0.5) }
    }
}

struct Keycap: View {
    let text: String
    let c: Swatch
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(c.faint)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(c.faint.opacity(0.45), lineWidth: 0.75))
    }
}

/// Three dots breathing in sequence while an answer streams.
struct Pulse: View {
    let c: Swatch
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(c.accent)
                        .frame(width: 4, height: 4)
                        .opacity(0.25 + 0.75 * max(0, sin((t * 5) - Double(i) * 0.7)))
                }
            }
        }
        .frame(width: 22)
    }
}

struct Skeleton: View {
    let c: Swatch
    let big: Bool
    @State private var on = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            bar(0.94)
            bar(0.58)
        }
        .opacity(on ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: on)
        .onAppear { on = true }
    }

    private func bar(_ fraction: CGFloat) -> some View {
        GeometryReader { g in
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(c.line)
                .frame(width: g.size.width * fraction)
        }
        .frame(height: big ? 13 : 11)
    }
}

struct ErrorRow: View {
    let message: String
    let c: Swatch
    let retry: () -> Void
    let settings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 13.5))
                .foregroundStyle(c.soft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if message.contains("Settings") {
                    PillButton(title: "Open Settings", c: c, action: settings)
                }
                PillButton(title: "Try again", c: c, action: retry)
            }
        }
    }
}

struct PillButton: View {
    let title: String
    let c: Swatch
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(c.accent)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().fill(c.accent.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hints (nothing selected, permissions)

struct HintView: View {
    let title: String
    let message: String
    let action: String?
    @ObservedObject var ui: PanelUI
    @ObservedObject var settings = Settings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = settings.palette.swatch(scheme)
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(c.ink)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(c.soft)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                PillButton(title: action, c: c, action: ui.onAction).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }
}

// MARK: - Pieces

struct CardBackground: View {
    let color: Color
    let snapshot: Bool
    var body: some View {
        ZStack {
            if !snapshot { VisualEffect().opacity(1) }
            color.opacity(snapshot ? 1 : 0.94)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct AppIcon: View {
    let bundleID: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "text.cursor").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }
}

enum Rich {
    /// Inline markup to styled text. ==marks== get the highlighter; **bold** goes to full ink.
    static func attributed(_ s: String, size: CGFloat, serif: Bool, base: Color, strong: Color, c: Swatch) -> AttributedString {
        let design: Font.Design = serif ? .serif : .default
        var out = AttributedString()
        for run in Inline.runs(s) {
            var a: AttributedString
            switch run.style {
            case .plain:
                a = AttributedString(run.text)
                a.font = .system(size: size, design: design)
                a.foregroundColor = base
            case .bold:
                a = AttributedString(run.text)
                a.font = .system(size: size, weight: .semibold, design: design)
                a.foregroundColor = strong
            case .italic:
                a = AttributedString(run.text)
                a.font = .system(size: size, design: design).italic()
                a.foregroundColor = base
            case .code:
                // No chip: backgrounds leave slivers where a line wraps. Mono in full ink reads as code.
                a = AttributedString(run.text)
                a.font = .system(size: size * 0.88, weight: .medium, design: .monospaced)
                a.foregroundColor = strong
            case .mark:
                a = AttributedString(run.text)
                a.font = .system(size: size, weight: .medium, design: design)
                a.foregroundColor = c.markInk
                a.backgroundColor = c.mark
            }
            out += a
        }
        return out
    }
}


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
/// Horizontal padding inside the panel; code blocks wrap to the width left over.
let panelInset: CGFloat = 22

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var contentHeight: CGFloat = 0
    @State private var lastTurnHeight: CGFloat = 0
    /// The follow-up asked in this panel that the view scrolled to; only it gets a runway.
    @State private var askedTurn: UUID? = nil

    private static let padTop: CGFloat = 15
    private static let padBottom: CGFloat = 16

    /// Room under the newest follow-up, so its question can sit at the top while the answer streams in below.
    private var runway: CGFloat {
        guard let asked = askedTurn, asked == session.turns.last?.id, contentHeight > ui.maxScrollHeight else { return 0 }
        return max(0, ui.maxScrollHeight - lastTurnHeight - Self.padTop - Self.padBottom)
    }

    var body: some View {
        let c = settings.palette.swatch(scheme)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Eyebrow(capture: session.capture, pinned: ui.pinned, copied: ui.copied, c: c)
                            TitleBlock(session: session, c: c)
                                .padding(.top, 9)
                            ForEach(Array(session.turns.enumerated()), id: \.element.id) { i, turn in
                                let isLast = i == session.turns.count - 1
                                TurnView(turn: turn, first: i == 0, c: c, ui: ui, retry: { session.retry() })
                                    .id(turn.id)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                                        if isLast { lastTurnHeight = h }
                                    }
                            }
                        }
                        .padding(.horizontal, panelInset)
                        .padding(.top, Self.padTop)
                        .padding(.bottom, Self.padBottom)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                        Color.clear.frame(height: runway)
                    }
                }
                .scrollIndicators(contentHeight > ui.maxScrollHeight ? .automatic : .never)
                .frame(height: max(80, min(contentHeight, ui.maxScrollHeight)))
                // A new question: bring it to the top and let the answer arrive beneath it. The stream itself
                // never moves the view, so scrolling back up to reread is never fought.
                .onChange(of: session.turns.count) { old, new in
                    guard new > old, new > 1, let id = session.turns.last?.id else { return }
                    askedTurn = id
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(40)) // let the runway lay out first
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { proxy.scrollTo(id, anchor: .top) }
                    }
                }
            }

            if !session.suggestions.isEmpty {
                Suggestions(items: session.suggestions, ui: ui, c: c)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }

            InputBar(ui: ui, busy: session.isBusy, c: c, focused: $focused)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: session.suggestions)
        .onAppear { focused = true }
        .onChange(of: ui.focusTick) { focused = true }
    }
}

struct Eyebrow: View {
    let capture: Capture
    let pinned: Bool
    let copied: Bool
    let c: Swatch

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            AppIcon(bundleID: capture.bundleID)
                .frame(width: 13, height: 13)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
                .accessibilityHidden(true)
            line
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
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
                    .accessibilityLabel("Pinned")
            }
        }
        .animation(.easeOut(duration: 0.15), value: copied)
        .accessibilityElement(children: .combine)
    }

    private var line: Text {
        let name = capture.appName.isEmpty ? "Selection" : capture.appName
        let app = Text(name).foregroundColor(c.faint).fontWeight(.medium)
        if capture.isPassage {
            let words = capture.wordCount
            return app + Text("  Passage, \(words) word\(words == 1 ? "" : "s")").italic().foregroundColor(c.faint)
        }
        // Long app names leave less room for the excerpt, so the line stays short without being cut.
        guard let s = ContextText.snippet(capture, maxLen: max(24, 62 - name.count)) else { return app }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let a = session.turns.first?.answer ?? Answer()
        let cap = session.capture
        let titleRaw = a.term ?? (cap.isPassage ? "This passage" : cap.term)
        let plain = Inline.strip(titleRaw)
        let size: CGFloat = plain.count <= 24 ? 26 : (plain.count <= 44 ? 22 : 19)
        VStack(alignment: .leading, spacing: 4) {
            titleRow(titleRaw, size: size, kind: a.kind, placeholder: a.term == nil && cap.isPassage)
            if let ex = a.expands {
                Expansion(text: ex, c: c)
                    .transition(.opacity)
            }
            if cap.isPassage {
                PassageQuote(text: cap.term, c: c)
                    .padding(.top, 6)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: a.kind)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: titleRaw)
    }

    @ViewBuilder
    private func titleRow(_ raw: String, size: CGFloat, kind: String?, placeholder: Bool) -> some View {
        let title = Text(a11yTitle(raw, size: size, placeholder: placeholder))
            .lineSpacing(size > 22 ? 0 : 1)
            .contentTransition(.opacity)
            .textSelection(.enabled)
            .accessibilityAddTraits(.isHeader)
        if let kind {
            let label = Text(Inline.strip(kind).uppercased().replacingOccurrences(of: " ", with: "\u{00A0}"))
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.3)
                .foregroundColor(c.accent)
            // Beside the title when both fit on one line; otherwise the title wraps and the kind drops beneath it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    title.fixedSize()
                    Spacer(minLength: 0)
                    label.fixedSize()
                }
                VStack(alignment: .leading, spacing: 5) {
                    title.fixedSize(horizontal: false, vertical: true)
                    label.fixedSize(horizontal: false, vertical: true)
                }
            }
            .transition(.opacity)
        } else {
            title.fixedSize(horizontal: false, vertical: true)
        }
    }

    private func a11yTitle(_ raw: String, size: CGFloat, placeholder: Bool) -> AttributedString {
        if placeholder || session.turns.first?.answer.term == nil {
            // The captured text is shown as typed, not parsed as markdown.
            var s = AttributedString(raw)
            s.font = .system(size: size, weight: .semibold, design: .serif)
            s.foregroundColor = placeholder ? c.faint : c.ink
            return s
        }
        return Rich.attributed(raw, size: size, serif: true, base: c.ink, strong: c.ink, c: c, weight: .semibold)
    }
}

/// A long selection, quoted briefly under the title so it's clear what is being explained.
struct PassageQuote: View {
    let text: String
    let c: Swatch

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(c.accent.opacity(0.6)).frame(width: 2)
            Text(Self.excerpt(text))
                .font(.system(size: 12.5, design: .serif).italic())
                .foregroundStyle(c.soft)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Passage: \(text)")
    }

    /// The opening of the passage, cut at a word and marked with an ellipsis.
    static func excerpt(_ s: String, max: Int = 150) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flat.count > max else { return flat }
        let cut = flat.prefix(max)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}

/// "Least Recently Used" with the initials picked out, so the acronym reads itself.
struct Expansion: View {
    let text: String
    let c: Swatch

    var body: some View {
        let words = Inline.strip(text).split(separator: " ", omittingEmptySubsequences: false)
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
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Inline.strip(text))
    }
}

struct TurnView: View {
    let turn: LookupSession.Turn
    let first: Bool
    let c: Swatch
    @ObservedObject var ui: PanelUI
    let retry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let q = turn.question {
                Rectangle().fill(c.line).frame(height: 0.5).padding(.top, 18).padding(.bottom, 14)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(c.accent)
                        .accessibilityHidden(true)
                    Text(Rich.attributed(q, size: 13, serif: false, base: c.soft, strong: c.ink, c: c, weight: .semibold))
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.bottom, 7)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("You asked: \(Inline.strip(q))")
            }

            switch turn.state {
            case .failed(let message):
                FailureView(failure: Failure(message), c: c, retry: retry, settings: ui.onSettings)
                    .padding(.top, first ? 12 : 2)
            case .searching(let query):
                SearchingView(query: query, c: c)
                    .padding(.top, first ? 14 : 4)
                    .transition(.opacity)
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
                            .accessibilityHidden(true)
                    } else {
                        Color.clear.frame(height: 10)
                    }
                    Blocks(blocks: turn.answer.blocks, c: c)
                }
                if !turn.sources.isEmpty && !turn.answer.isEmpty {
                    SourcesRow(sources: turn.sources, c: c)
                        .padding(.top, 14)
                        .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: turn.answer.blocks.count)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: turn.state)
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
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("⌘\(i + 1)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(lit ? c.accent : c.faint)
                            .frame(width: 22, alignment: .leading)
                        Text(Rich.attributed(s, size: 13, serif: false, base: lit ? c.ink : c.soft, strong: c.ink, c: c))
                            .lineSpacing(1.5)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
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
                .accessibilityLabel("Ask: \(Inline.strip(s))")
                .accessibilityHint("Command \(i + 1)")
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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(c.accent)
                .accessibilityHidden(true)
            // Grows to a few lines for a long question rather than scrolling sideways.
            TextField("", text: $ui.draft, prompt: Text("Ask a follow-up").foregroundColor(c.faint), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(c.ink)
                .focused(focused)
                .tint(c.accent)
                .onSubmit { ui.submit() }
                .accessibilityLabel("Ask a follow-up")
            Group {
                if busy {
                    Pulse(c: c).accessibilityLabel("Answering")
                } else if !ui.draft.trimmed.isEmpty {
                    Keycap(text: "↵", c: c).accessibilityHidden(true)
                } else {
                    Keycap(text: "esc", c: c).accessibilityHidden(true)
                }
            }
            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 3 }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(c.accent)
                        .frame(width: 4, height: 4)
                        .opacity(reduceMotion ? 0.7 : 0.25 + 0.75 * max(0, sin((t * 5) - Double(i) * 0.7)))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            bar(0.94)
            bar(0.58)
        }
        .opacity(reduceMotion ? 0.8 : (on ? 1 : 0.45))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: on)
        .onAppear { on = true }
        .accessibilityElement()
        .accessibilityLabel("Loading")
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

// MARK: - Failures

/// What went wrong, read from the engine's message so each case gets its own words and way out.
struct Failure: Equatable {
    enum Kind: Equatable { case noKey, badKey, rateLimited, offline, timedOut, other }
    let kind: Kind
    let detail: String

    init(_ message: String) {
        detail = message
        let m = message.lowercased()
        if m.contains("add your together api key") { kind = .noKey }
        else if m.contains("rejected the api key") || m.contains("returned 401") || m.contains("returned 403") { kind = .badKey }
        else if m.contains("rate limit") || m.contains("returned 429") { kind = .rateLimited }
        else if m.contains("timed out") { kind = .timedOut }
        else if m.contains("offline") || m.contains("not connected") || m.contains("network connection was lost")
                    || m.contains("could not be found") || m.contains("could not connect") { kind = .offline }
        else { kind = .other }
    }

    var title: String {
        switch kind {
        case .noKey: return "Add a Together key to start"
        case .badKey: return "Together didn't accept the key"
        case .rateLimited: return "Too many look-ups at once"
        case .offline: return "You're offline"
        case .timedOut: return "Together took too long"
        case .other: return "That didn't work"
        }
    }

    var body: String {
        switch kind {
        case .noKey: return "Aside sends what you look up to DeepSeek on Together. Paste a key in Settings; it stays on this Mac."
        case .badKey: return "It may have been revoked or mistyped. Paste a fresh one in Settings."
        case .rateLimited: return "Together is limiting requests on this key. Give it a few seconds."
        case .offline: return "Aside needs the internet to answer. It'll work as soon as you're back on."
        case .timedOut: return "No answer came back in time. It's usually a blip."
        case .other: return detail
        }
    }

    var wantsSettings: Bool { kind == .noKey || kind == .badKey }
    var canRetry: Bool { kind != .noKey }
}

struct FailureView: View {
    let failure: Failure
    let c: Swatch
    let retry: () -> Void
    let settings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(failure.title)
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(c.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(failure.body)
                .font(.system(size: 13))
                .foregroundStyle(c.soft)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if failure.wantsSettings {
                    PillButton(title: failure.kind == .noKey ? "Add a key" : "Open Settings", shortcut: "⌘,", c: c) {
                        Settings.shared.pane = .keys
                        settings()
                    }
                }
                if failure.canRetry {
                    PillButton(title: "Try again", shortcut: "⌘R", c: c, action: retry)
                }
            }
            .padding(.top, 6)
        }
        .accessibilityElement(children: .contain)
    }
}

struct PillButton: View {
    let title: String
    var shortcut: String? = nil
    let c: Swatch
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(c.accent)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(c.accent.opacity(0.65))
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(c.accent.opacity(hover ? 0.16 : 0.1)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(title)
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
                .fixedSize(horizontal: false, vertical: true)
            Text(Rich.attributed(message, size: 13, serif: false, base: c.soft, strong: c.ink, c: c))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                PillButton(title: action, c: c, action: ui.onAction).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, panelInset)
        .padding(.vertical, 18)
        .accessibilityElement(children: .contain)
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

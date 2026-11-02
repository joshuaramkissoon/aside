import AppKit
import SwiftUI

// MARK: - Inline text

enum Rich {
    /// Inline markup to styled text. Styles combine: `code` inside a ==mark== keeps the highlighter,
    /// **bold** goes to full ink, links take the accent and open in the browser.
    static func attributed(_ s: String, size: CGFloat, serif: Bool, base: Color, strong: Color, c: Swatch,
                           weight: Font.Weight = .regular) -> AttributedString {
        let design: Font.Design = serif ? .serif : .default
        var out = AttributedString()
        for run in Inline.runs(s) {
            var a = AttributedString(run.text)
            let st = run.style
            var font: Font
            if st.contains(.code) {
                // No chip: backgrounds leave slivers where a line wraps. Mono in full ink reads as code.
                font = .system(size: size * 0.88, weight: .medium, design: .monospaced)
            } else {
                let w: Font.Weight = st.contains(.bold) ? .semibold : (st.contains(.mark) ? .medium : weight)
                font = .system(size: size, weight: w, design: design)
            }
            if st.contains(.italic) { font = font.italic() }
            a.font = font
            a.foregroundColor = st.contains(.mark) ? c.markInk : (st.contains(.bold) || st.contains(.code) ? strong : base)
            if st.contains(.mark) { a.backgroundColor = c.mark }
            if st.contains(.strike) { a.strikethroughStyle = Text.LineStyle(pattern: .solid, color: base.opacity(0.7)) }
            if let url = run.link {
                a.link = url
                if !st.contains(.mark) { a.foregroundColor = c.accent }
                a.underlineStyle = Text.LineStyle(pattern: .solid, color: c.accent.opacity(0.45))
            }
            out += a
        }
        return out
    }
}

// MARK: - Blocks

struct Blocks: View {
    let blocks: [Answer.Block]
    let c: Swatch

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .bullet(let s, let level):
                    ListRow(level: level, c: c) {
                        Circle()
                            .fill(level == 0 ? c.accent.opacity(0.75) : .clear)
                            .strokeBorder(level == 0 ? .clear : c.accent.opacity(0.7), lineWidth: 1)
                            .frame(width: 4, height: 4)
                            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 4 }
                    } text: { body(s) }
                case .numbered(let s, let label, let level):
                    ListRow(level: level, c: c) {
                        Text(label + ".")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(c.accent)
                    } text: { body(s) }
                case .para(let s):
                    body(s)
                case .heading(let s):
                    Text(Rich.attributed(s, size: 13.5, serif: false, base: c.ink, strong: c.ink, c: c, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                        .accessibilityAddTraits(.isHeader)
                case .quote(let s):
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle().fill(c.line).frame(width: 2)
                        Text(Rich.attributed(s, size: 13.5, serif: true, base: c.soft, strong: c.ink, c: c))
                            .italic()
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .code(let s):
                    CodeBlock(code: s, c: c)
                case .table(let rows):
                    TableBlock(rows: rows, c: c)
                }
            }
        }
    }

    private func body(_ s: String) -> some View {
        Text(Rich.attributed(s, size: 13.5, serif: false, base: c.soft, strong: c.ink, c: c))
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// A list item: marker in a fixed gutter, text hanging beside it, indented by nesting level.
struct ListRow<Marker: View, Content: View>: View {
    let level: Int
    let c: Swatch
    @ViewBuilder let marker: () -> Marker
    @ViewBuilder let text: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            marker()
                .frame(minWidth: 10, alignment: .leading)
            text()
        }
        .padding(.leading, CGFloat(level) * 16)
    }
}

// MARK: - Code

/// Code soft-wraps with a hanging indent instead of scrolling sideways. The panel is for reading at a glance:
/// a sideways scroller inside a vertical one is fiddly on a trackpad and hides the very comments that explain
/// the code. Wrapping is done here, at a known column count (the panel's width is fixed and the font is
/// monospaced), so continuation lines can hang deeper than the line they continue and never read as new lines.
struct CodeBlock: View {
    let code: String
    let c: Swatch
    @State private var hover = false
    @State private var copied = false

    static let fontSize: CGFloat = 11.5
    static let padH: CGFloat = 12

    static let columns: Int = {
        let f = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let w = ("0" as NSString).size(withAttributes: [.font: f]).width
        let avail = panelWidth - panelInset * 2 - padH * 2
        return max(24, Int(floor(avail / max(w, 1))) - 1)
    }()

    var body: some View {
        Text(CodeWrap.wrap(code, columns: Self.columns))
            .font(.system(size: Self.fontSize, design: .monospaced))
            .foregroundStyle(c.ink)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.padH).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.codeBg))
            .overlay(alignment: .topTrailing) {
                if hover || copied {
                    Button(action: copy) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(copied ? c.accent : c.faint)
                            .frame(width: 22, height: 20)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.codeBg))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(c.line, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .help("Copy code")
                    .accessibilityLabel(copied ? "Copied" : "Copy code")
                    .transition(.opacity)
                }
            }
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Code")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

enum CodeWrap {
    /// Wrap each line at `columns`, breaking at a space where it can, continuing with the line's own indent plus four.
    static func wrap(_ code: String, columns: Int) -> String {
        var out: [String] = []
        for raw in code.replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n") {
            var line = Substring(raw)
            while let last = line.last, last.isWhitespace { line = line.dropLast() }
            guard line.count > columns else { out.append(String(line)); continue }
            let indent = line.prefix(while: { $0 == " " }).count
            var hangCols = min(indent + 4, columns / 2)
            // A trailing comment that wraps keeps to its own column, as a tidy block beside the code.
            if let cm = commentStart(line), cm > indent, cm + 3 <= columns - 16 {
                hangCols = cm + 3
            }
            let hang = String(repeating: " ", count: hangCols)
            var rest = line
            var first = true
            while !rest.isEmpty {
                let lead = first ? "" : hang
                let room = columns - lead.count
                if rest.count <= room { out.append(lead + rest); break }
                let window = rest.prefix(room)
                // Prefer the last space past a third of the line, so a break never leaves a stub.
                var cut = window.endIndex
                if let sp = window.lastIndex(of: " "), rest.distance(from: rest.startIndex, to: sp) > room / 3 { cut = sp }
                out.append(lead + String(rest[..<cut]))
                rest = rest[cut...].drop(while: { $0 == " " })
                first = false
            }
        }
        return out.joined(separator: "\n")
    }

    /// Column of a trailing `//`, `#` or `--` comment, outside quotes.
    static func commentStart(_ line: Substring) -> Int? {
        let chars = Array(line)
        var quote: Character? = nil
        for i in chars.indices {
            let ch = chars[i]
            if let q = quote { if ch == q && (i == 0 || chars[i - 1] != "\\") { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            let prevSpace = i > 0 && chars[i - 1] == " "
            if ch == "/", i + 1 < chars.count, chars[i + 1] == "/", prevSpace { return i }
            if ch == "#", prevSpace, i + 1 < chars.count, chars[i + 1] == " " { return i }
            if ch == "-", i + 1 < chars.count, chars[i + 1] == "-", prevSpace, i + 2 < chars.count, chars[i + 2] == " " { return i }
        }
        return nil
    }
}

// MARK: - Tables

struct TableBlock: View {
    let rows: [[String]]
    let c: Swatch

    var body: some View {
        let cols = rows.map(\.count).max() ?? 0
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                GridRow(alignment: .firstTextBaseline) {
                    ForEach(0..<cols, id: \.self) { i in
                        let cell = i < row.count ? row[i] : ""
                        Text(Rich.attributed(cell, size: 12.5, serif: false, base: r == 0 ? c.ink : c.soft, strong: c.ink, c: c,
                                             weight: r == 0 ? .semibold : .regular))
                            .lineSpacing(1.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                if r == 0 && rows.count > 1 {
                    Rectangle().fill(c.line).frame(height: 0.5).gridCellUnsizedAxes(.horizontal)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Web search

/// While Aside reads the web for a term the model doesn't know: the query, with a highlighter drawing across it.
struct SearchingView: View {
    let query: String
    let c: Swatch
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("SEARCHING THE WEB")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(c.faint)
            TimelineView(.animation(paused: reduceMotion)) { tl in
                let p = reduceMotion ? (start: CGFloat(0), width: CGFloat(1), opacity: 1.0) : Self.sweep(tl.date.timeIntervalSinceReferenceDate)
                Text(query)
                    .font(.system(size: 17, weight: .medium, design: .serif))
                    .foregroundStyle(c.markInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 3)
                    .background(alignment: .leading) {
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(c.mark)
                                .frame(width: g.size.width * p.width)
                                .offset(x: g.size.width * p.start)
                                .opacity(p.opacity)
                        }
                    }
            }
            Text("Not one the model knows well, so Aside is reading a few pages first.")
                .font(.system(size: 12))
                .foregroundStyle(c.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Searching the web for \(query)")
    }

    /// A slow, calm stroke: draws left to right, rests, lifts off to the right, pauses.
    static func sweep(_ t: Double) -> (start: CGFloat, width: CGFloat, opacity: Double) {
        let period = 2.6
        let x = t.truncatingRemainder(dividingBy: period) / period
        func ease(_ v: Double) -> Double { v * v * (3 - 2 * v) }
        switch x {
        case ..<0.42: return (0, CGFloat(ease(x / 0.42)), 1)
        case ..<0.62: return (0, 1, 1)
        case ..<0.9: let k = ease((x - 0.62) / 0.28); return (CGFloat(k), CGFloat(1 - k), 1)
        default: return (1, 0, 0)
        }
    }
}

/// The pages a grounded answer drew on: site names that open in the browser.
struct SourcesRow: View {
    let sources: [LookupSession.WebSource]
    let c: Swatch

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("FROM")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(c.faint)
                .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] - 1 }
            Flow(spacing: 6, lineSpacing: 6) {
                ForEach(sources) { s in SourceChip(source: s, c: c) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources")
    }
}

struct SourceChip: View {
    let source: LookupSession.WebSource
    let c: Swatch
    @State private var hover = false

    var body: some View {
        Button { NSWorkspace.shared.open(source.url) } label: {
            HStack(spacing: 4) {
                Text(source.site)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hover ? c.accent : c.soft)
                    .fixedSize()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hover ? c.accent : c.faint)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(hover ? c.accent.opacity(0.1) : c.codeBg))
            .overlay(Capsule().strokeBorder(c.line, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(source.title.isEmpty ? source.url.absoluteString : "\(source.title)\n\(source.url.absoluteString)")
        .accessibilityLabel("Source: \(source.title.isEmpty ? source.site : source.title), \(source.site)")
        .accessibilityHint("Opens in your browser")
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct Flow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            lineH = max(lineH, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += lineH + lineSpacing; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}

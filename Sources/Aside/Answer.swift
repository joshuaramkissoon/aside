import Foundation

/// A parsed answer. Built from the raw stream on every chunk, so it must tolerate half-written lines.
struct Answer: Equatable {
    enum Block: Equatable, Hashable {
        /// `level` is the nesting depth (0, 1 or 2).
        case bullet(String, level: Int)
        /// `label` is the number as written ("1", "2"…).
        case numbered(String, label: String, level: Int)
        case para(String)
        /// A stray markdown heading, shown as a bold line.
        case heading(String)
        case quote(String)
        case code(String)
        /// Rows of cells; the first row is the header.
        case table([[String]])
    }

    var term: String?
    var expands: String?
    var kind: String?
    var gist: String = ""
    var blocks: [Block] = []
    var next: [String] = []

    var isEmpty: Bool { gist.isEmpty && blocks.isEmpty }

    /// Plain text for the clipboard.
    var plainText: String {
        var out = ""
        if let term { out += Inline.strip(term) + (expands.map { " (\(Inline.strip($0)))" } ?? "") + "\n" }
        out += Inline.strip(gist)
        for b in blocks {
            switch b {
            case .bullet(let s, let level): out += "\n" + String(repeating: "  ", count: level) + "• " + Inline.strip(s)
            case .numbered(let s, let label, let level): out += "\n" + String(repeating: "  ", count: level) + label + ". " + Inline.strip(s)
            case .para(let s), .heading(let s): out += "\n" + Inline.strip(s)
            case .quote(let s): out += "\n> " + Inline.strip(s)
            case .code(let s): out += "\n" + s
            case .table(let rows): for r in rows { out += "\n" + r.map(Inline.strip).joined(separator: "\t") }
            }
        }
        return out
    }

    static func parse(_ raw: String, streaming: Bool) -> Answer {
        var a = Answer()
        var lines = raw.components(separatedBy: "\n")
        // While streaming, a last line that could still become a header keyword is held back.
        if streaming, let last = lines.last {
            let keys = ["TERM:", "EXPANDS:", "KIND:", "GIST:", "NEXT:"]
            let t = last.trimmed.uppercased()
            if !t.isEmpty, keys.contains(where: { $0.hasPrefix(t) && $0 != t }) { lines.removeLast() }
        }
        var inNext = false
        var inCode = false
        var code: [String] = []
        var table: [[String]] = []
        var sawGist = false

        func field(_ line: String, _ key: String) -> String? {
            guard line.uppercased().hasPrefix(key) else { return nil }
            return String(line.dropFirst(key.count)).replacingOccurrences(of: String(Inline.openEnd), with: "").trimmed
        }
        func flushTable() {
            if !table.isEmpty { a.blocks.append(.table(table)); table = [] }
        }

        for (n, rawLine) in lines.enumerated() {
            // The line still being written gets a marker, so an unclosed ** or == styles the rest instead of showing.
            let open = streaming && n == lines.count - 1
            func live(_ s: String) -> String { open && !s.isEmpty ? s + String(Inline.openEnd) : s }

            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if inCode {
                if line.hasPrefix("```") { a.blocks.append(.code(code.joined(separator: "\n"))); code = []; inCode = false }
                else { code.append(rawLine) }
                continue
            }
            // A half-written fence ("`" or "``") on the last line shouldn't flash.
            if open && !line.isEmpty && line.allSatisfy({ $0 == "`" }) { continue }
            if line.hasPrefix("```") { flushTable(); inCode = true; continue }
            if line.isEmpty { flushTable(); continue }

            if line.hasPrefix("|") {
                if let row = Table.row(line) { table.append(row) }
                continue
            }
            flushTable()

            if let v = field(line, "TERM:") { a.term = v.nonEmpty; continue }
            if let v = field(line, "EXPANDS:") { a.expands = v.nonEmpty; continue }
            if let v = field(line, "KIND:") { a.kind = v.nonEmpty?.lowercased(); continue }
            if let v = field(line, "GIST:") { a.gist = live(v); sawGist = true; continue }
            if field(line, "NEXT:") != nil { inNext = true; continue }
            if inNext || line.hasPrefix("? ") {
                var q = line
                if q.hasPrefix("?") { q = String(q.dropFirst()) }
                else if let b = Markup.bullet(q) { q = b }
                q = q.trimmed
                if !q.isEmpty { a.next.append(q) }
                continue
            }
            // Horizontal rules carry nothing in a panel this small.
            if line.count >= 3, Set(line).count == 1, let f = line.first, "-*_".contains(f) { continue }

            let level = Markup.level(rawLine)
            if let b = Markup.bullet(line) {
                a.blocks.append(.bullet(live(b), level: level))
                continue
            }
            if let (label, text) = Markup.numbered(line) {
                a.blocks.append(.numbered(live(text), label: label, level: level))
                continue
            }
            if let h = Markup.heading(line) {
                a.blocks.append(.heading(live(h)))
                continue
            }
            if line.hasPrefix(">") {
                let q = String(line.drop(while: { $0 == ">" })).trimmed
                if !q.isEmpty { a.blocks.append(.quote(live(q))) }
                continue
            }
            // Untagged prose: the first line is the gist when the model forgot the tag.
            if !sawGist && a.gist.isEmpty { a.gist = live(line); sawGist = true; continue }
            a.blocks.append(.para(live(line)))
        }
        if inCode && !code.isEmpty { a.blocks.append(.code(code.joined(separator: "\n"))) }
        flushTable()
        a.next = Array(a.next.prefix(3))
        return a
    }
}

/// Line-level markdown helpers.
enum Markup {
    /// "- x", "* x", "• x", "+ x" → "x".
    static func bullet(_ line: String) -> String? {
        for p in ["- ", "* ", "• ", "+ ", "– "] where line.hasPrefix(p) {
            return String(line.dropFirst(p.count)).trimmed
        }
        return nil
    }

    /// "12. x" or "12) x" → ("12", "x").
    static func numbered(_ line: String) -> (String, String)? {
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        guard (1...3).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let p = rest.first, p == "." || p == ")", rest.dropFirst().first == " " else { return nil }
        return (String(digits), String(rest.dropFirst(2)).trimmed)
    }

    /// "## Title" → "Title".
    static func heading(_ line: String) -> String? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).first == " " else { return nil }
        return String(line.dropFirst(hashes.count)).trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmed
    }

    /// Nesting depth from leading whitespace: two or more spaces is one level, six or more is two.
    static func level(_ raw: String) -> Int {
        var n = 0
        for ch in raw {
            if ch == " " { n += 1 } else if ch == "\t" { n += 4 } else { break }
        }
        return n >= 6 ? 2 : (n >= 2 ? 1 : 0)
    }
}

/// Markdown table rows.
enum Table {
    /// "| a | b |" → ["a", "b"]. Separator rows ("|---|:--:|") return nil.
    static func row(_ line: String) -> [String]? {
        var body = Substring(line.trimmed)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        if !body.isEmpty, body.allSatisfy({ "|-: ".contains($0) }) { return nil }
        var cells: [String] = []
        var cur = ""
        var inCode = false
        var escaped = false
        for ch in body {
            if escaped { cur.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; cur.append(ch); continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode { cells.append(cur.trimmed); cur = ""; continue }
            cur.append(ch)
        }
        cells.append(cur.replacingOccurrences(of: String(Inline.openEnd), with: "").trimmed)
        return cells
    }
}

/// Inline markup: ==mark==, **bold**, *italic*, `code`, ~~strike~~, [links](url), bare URLs and \escapes, nested freely.
enum Inline {
    struct Style: OptionSet, Hashable {
        let rawValue: UInt8
        static let mark = Style(rawValue: 1)
        static let bold = Style(rawValue: 2)
        static let italic = Style(rawValue: 4)
        static let code = Style(rawValue: 8)
        static let strike = Style(rawValue: 16)
    }

    struct Run: Equatable {
        var text: String
        var style: Style
        var link: URL? = nil
    }

    /// Appended by `Answer.parse` to the line still streaming: unclosed markers then style the rest
    /// rather than showing, and a trailing half-marker ("*", "=") is hidden until it resolves.
    static let openEnd: Character = "\u{E000}"

    static func runs(_ s: String) -> [Run] {
        var chars = Array(s)
        var open = false
        if chars.last == openEnd { chars.removeLast(); open = true }
        chars.removeAll { $0 == openEnd }
        var out: [Run] = []
        InlineParser(c: chars, open: open).parse(0, chars.count, [], nil, &out)
        // Merge neighbours with the same look, so text renders in as few runs as possible.
        var merged: [Run] = []
        for r in out where !r.text.isEmpty {
            if let last = merged.last, last.style == r.style, last.link == r.link { merged[merged.count - 1].text += r.text }
            else { merged.append(r) }
        }
        return merged
    }

    static func strip(_ s: String) -> String { runs(s).map(\.text).joined() }
}

private struct InlineParser {
    let c: [Character]
    let open: Bool

    private func at(_ i: Int, _ s: String) -> Bool {
        var j = i
        for ch in s {
            guard j < c.count, c[j] == ch else { return false }
            j += 1
        }
        return true
    }

    /// The end of a run of `ch` starting at `i`.
    private func runEnd(_ i: Int, _ ch: Character, _ hi: Int) -> Int {
        var j = i
        while j < hi, c[j] == ch { j += 1 }
        return j
    }

    /// A closing backtick run of exactly `n`, from `from`.
    private func codeClose(_ n: Int, from: Int, _ hi: Int) -> Int? {
        var j = from
        while j < hi {
            if c[j] == "`" {
                let e = runEnd(j, "`", hi)
                if e - j == n { return j }
                j = e
            } else { j += 1 }
        }
        return nil
    }

    /// The next `marker` at or after `from`, skipping escapes and code spans.
    private func close(_ marker: String, from: Int, _ hi: Int) -> Int? {
        var j = from
        while j < hi {
            if c[j] == "\\" { j += 2; continue }
            if c[j] == "`" {
                let e = runEnd(j, "`", hi)
                if let cl = codeClose(e - j, from: e, hi) { j = cl + (e - j); continue }
                j = e
                continue
            }
            if at(j, marker), j + marker.count <= hi { return j }
            j += 1
        }
        return nil
    }

    /// A single `*` or `_` closing an italic: not after a space, and not part of a `**` pair.
    private func italicClose(_ ch: Character, from: Int, _ hi: Int) -> Int? {
        var j = from
        while j < hi {
            if c[j] == "\\" { j += 2; continue }
            if c[j] == "`" {
                let e = runEnd(j, "`", hi)
                if let cl = codeClose(e - j, from: e, hi) { j = cl + (e - j); continue }
                j = e
                continue
            }
            if c[j] == ch {
                if ch == "*", j + 1 < hi, c[j + 1] == "*" { j += 2; continue }
                let afterOK = ch == "*" || j + 1 >= hi || !(c[j + 1].isLetter || c[j + 1].isNumber || c[j + 1] == "_")
                if j > from, !c[j - 1].isWhitespace, afterOK { return j }
            }
            j += 1
        }
        return nil
    }

    /// The `]` matching the `[` at `i`, allowing nested brackets.
    private func bracketClose(_ i: Int, _ hi: Int) -> Int? {
        var depth = 0
        var j = i
        while j < hi {
            if c[j] == "\\" { j += 2; continue }
            if c[j] == "[" { depth += 1 }
            if c[j] == "]" { depth -= 1; if depth == 0 { return j } }
            j += 1
        }
        return nil
    }

    /// The `)` matching the `(` at `i`, so addresses like wiki/Foo_(bar) survive.
    private func parenClose(_ i: Int, _ hi: Int) -> Int? {
        var depth = 0
        var j = i
        while j < hi {
            if c[j] == "(" { depth += 1 }
            if c[j] == ")" { depth -= 1; if depth == 0 { return j } }
            if c[j].isWhitespace && depth == 1 && j + 1 < hi && c[j + 1] == "\"" { // [t](url "title")
                if let q = (j + 2..<hi).first(where: { c[$0] == "\"" }), q + 1 < hi, c[q + 1] == ")" { return q + 1 }
            }
            j += 1
        }
        return nil
    }

    private static let markerChars: Set<Character> = ["=", "*", "~", "`", "_", "\\", "["]

    func parse(_ lo: Int, _ hi: Int, _ style: Inline.Style, _ link: URL?, _ out: inout [Inline.Run]) {
        let openHere = open && hi == c.count
        var buf = ""
        var i = lo
        func flush() {
            if !buf.isEmpty { out.append(.init(text: buf, style: style, link: link)); buf = "" }
        }

        while i < hi {
            let ch = c[i]

            // A half-written marker at the very end of a streaming line: wait for the rest.
            if openHere, Self.markerChars.contains(ch), c[i..<hi].allSatisfy({ Self.markerChars.contains($0) }) { break }

            // \* and friends.
            if ch == "\\", i + 1 < hi, c[i + 1].isASCII, c[i + 1].isPunctuation || c[i + 1].isSymbol {
                buf.append(c[i + 1])
                i += 2
                continue
            }

            // `code`, ``code with ` inside``.
            if ch == "`" {
                let e = runEnd(i, "`", hi)
                let n = e - i
                if let cl = codeClose(n, from: e, hi) {
                    flush()
                    var t = String(c[e..<cl])
                    if t.count > 2, t.hasPrefix(" "), t.hasSuffix(" ") { t = String(t.dropFirst().dropLast()) }
                    out.append(.init(text: t, style: style.union(.code), link: link))
                    i = cl + n
                    continue
                }
                if openHere {
                    flush()
                    out.append(.init(text: String(c[e..<hi]), style: style.union(.code), link: link))
                    i = hi
                    continue
                }
                buf.append(contentsOf: String(c[i..<e]))
                i = e
                continue
            }

            // ==mark==, **bold**, ~~strike~~: contents are parsed again, so styles nest.
            var paired = false
            for (m, st) in [("==", Inline.Style.mark), ("**", .bold), ("~~", .strike)] where at(i, m) {
                let start = i + 2
                if start < hi, !c[start].isWhitespace, let end = close(m, from: start, hi), end > start {
                    flush()
                    parse(start, end, style.union(st), link, &out)
                    i = end + 2
                    paired = true
                } else if openHere, st != .strike {
                    flush()
                    parse(start, hi, style.union(st), link, &out)
                    i = hi
                    paired = true
                }
                break
            }
            if paired { continue }
            if at(i, "==") || at(i, "**") || at(i, "~~") {
                buf.append(contentsOf: String(c[i..<i + 2]))
                i += 2
                continue
            }

            // *italic* and _italic_ (the underscore only at a word edge, so snake_case survives).
            if ch == "*" || ch == "_", i + 1 < hi, !c[i + 1].isWhitespace, c[i + 1] != ch,
               ch == "*" || i == lo || !(c[i - 1].isLetter || c[i - 1].isNumber || c[i - 1] == "_") {
                if let end = italicClose(ch, from: i + 1, hi) {
                    flush()
                    parse(i + 1, end, style.union(.italic), link, &out)
                    i = end + 1
                    continue
                }
                if openHere, ch == "*" {
                    flush()
                    parse(i + 1, hi, style.union(.italic), link, &out)
                    i = hi
                    continue
                }
            }

            // [text](url)
            if ch == "[", let rb = bracketClose(i, hi), rb + 1 < hi, c[rb + 1] == "(" {
                if let rp = parenClose(rb + 1, hi) {
                    var target = String(c[(rb + 2)..<rp]).trimmed
                    if let sp = target.firstIndex(of: " ") { target = String(target[..<sp]) } // drop a "title"
                    target = target.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                    flush()
                    parse(i + 1, rb, style, Self.url(target) ?? link, &out)
                    i = rp + 1
                    continue
                }
                if openHere {
                    // The address is still arriving: show the words, hide the brackets.
                    flush()
                    parse(i + 1, rb, style, link, &out)
                    i = hi
                    continue
                }
            }

            // <https://…>
            if ch == "<", at(i + 1, "http"), let gt = close(">", from: i + 1, hi),
               let u = Self.url(String(c[(i + 1)..<gt])) {
                flush()
                out.append(.init(text: String(c[(i + 1)..<gt]), style: style, link: u))
                i = gt + 1
                continue
            }

            // Bare https://… addresses.
            if ch == "h", link == nil, !style.contains(.code), at(i, "http"), at(i, "https://") || at(i, "http://"),
               i == lo || !(c[i - 1].isLetter || c[i - 1].isNumber) {
                var j = i
                var depth = 0
                while j < hi, !c[j].isWhitespace, c[j] != "<", c[j] != ">", c[j] != "\"" {
                    if c[j] == "(" { depth += 1 }
                    if c[j] == ")" { if depth == 0 { break }; depth -= 1 }
                    j += 1
                }
                while j > i, ".,;:!?'*_=~".contains(c[j - 1]) { j -= 1 }
                let text = String(c[i..<j])
                if let u = Self.url(text), text.count > 8 {
                    flush()
                    out.append(.init(text: text, style: style, link: u))
                    i = j
                    continue
                }
            }

            buf.append(ch)
            i += 1
        }
        flush()
    }

    static func url(_ s: String) -> URL? {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return u
    }
}

import Foundation

/// A parsed answer. Built from the raw stream on every chunk, so it must tolerate half-written lines.
struct Answer: Equatable {
    enum Block: Equatable, Hashable {
        case bullet(String)
        case para(String)
        case code(String)
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
        if let term { out += term + (expands.map { " (\($0))" } ?? "") + "\n" }
        out += Inline.strip(gist)
        for b in blocks {
            switch b {
            case .bullet(let s): out += "\n• " + Inline.strip(s)
            case .para(let s): out += "\n" + Inline.strip(s)
            case .code(let s): out += "\n" + s
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
        var sawGist = false

        func field(_ line: String, _ key: String) -> String? {
            guard line.uppercased().hasPrefix(key) else { return nil }
            return String(line.dropFirst(key.count)).trimmed
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if inCode {
                if line.hasPrefix("```") { a.blocks.append(.code(code.joined(separator: "\n"))); code = []; inCode = false }
                else { code.append(rawLine) }
                continue
            }
            if line.hasPrefix("```") { inCode = true; continue }
            if line.isEmpty { continue }
            if let v = field(line, "TERM:") { a.term = v.nonEmpty; continue }
            if let v = field(line, "EXPANDS:") { a.expands = v.nonEmpty; continue }
            if let v = field(line, "KIND:") { a.kind = v.nonEmpty?.lowercased(); continue }
            if let v = field(line, "GIST:") { a.gist = v; sawGist = true; continue }
            if field(line, "NEXT:") != nil { inNext = true; continue }
            if inNext || line.hasPrefix("? ") {
                let q = line.hasPrefix("?") ? String(line.dropFirst()).trimmed : line
                if !q.isEmpty { a.next.append(q) }
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                a.blocks.append(.bullet(String(line.dropFirst(2)).trimmed))
                continue
            }
            // Untagged prose: the first line is the gist when the model forgot the tag.
            if !sawGist && a.gist.isEmpty { a.gist = line; sawGist = true; continue }
            a.blocks.append(.para(line))
        }
        if inCode && !code.isEmpty { a.blocks.append(.code(code.joined(separator: "\n"))) }
        a.next = Array(a.next.prefix(3))
        return a
    }
}

/// Inline markup: ==mark==, **bold**, *italic*, `code`.
enum Inline {
    enum Style { case plain, mark, bold, italic, code }
    struct Run: Equatable { var text: String; var style: Style }

    static func runs(_ s: String) -> [Run] {
        var out: [Run] = []
        var buf = ""
        var i = s.startIndex
        func flush(_ style: Style = .plain) { if !buf.isEmpty { out.append(Run(text: buf, style: style)); buf = "" } }
        func take(_ open: String, _ close: String, _ style: Style) -> Bool {
            guard s[i...].hasPrefix(open) else { return false }
            let start = s.index(i, offsetBy: open.count)
            if let end = s.range(of: close, range: start..<s.endIndex) {
                flush()
                out.append(Run(text: String(s[start..<end.lowerBound]), style: style))
                i = end.upperBound
                return true
            }
            // Unclosed while streaming: style the rest so it doesn't flash raw markers.
            if style == .mark || style == .bold || style == .code {
                flush()
                out.append(Run(text: String(s[start...]), style: style))
                i = s.endIndex
                return true
            }
            return false
        }
        while i < s.endIndex {
            if take("==", "==", .mark) || take("**", "**", .bold) || take("`", "`", .code) { continue }
            if s[i] == "*", s.index(after: i) < s.endIndex, s[s.index(after: i)] != " ",
               take("*", "*", .italic) { continue }
            buf.append(s[i])
            i = s.index(after: i)
        }
        flush()
        return out
    }

    static func strip(_ s: String) -> String { runs(s).map(\.text).joined() }
}

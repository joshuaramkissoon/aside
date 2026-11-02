import AppKit
import ScreenCaptureKit
import Vision

/// Reads text from the screen around a point, for apps that hide their text from Accessibility.
/// Needs Screen Recording permission; does nothing without it.
@MainActor
final class ScreenText {
    struct Line { let text: String; let rect: CGRect; let observation: VNRecognizedText; let capture: CGRect }

    var allowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Lines of text in a band around `p` (Accessibility coordinates), top to bottom.
    func lines(around p: CGPoint, width: CGFloat = 1100, height: CGFloat = 300) async -> [Line] {
        guard allowed else { return [] }
        guard let screen = NSScreen.screens.first(where: { $0.axFrame.contains(p) }) ?? NSScreen.screens.first else { return [] }
        let bounds = screen.axFrame
        var rect = CGRect(x: p.x - width * 0.35, y: p.y - height / 2, width: width, height: height)
        rect = rect.intersection(bounds)
        guard rect.width > 20, rect.height > 10 else { return [] }
        guard let image = try? await SCScreenshotManager.captureImage(in: rect) else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let obs = request.results ?? []
        return obs.compactMap { o in
            guard let top = o.topCandidates(1).first else { return nil }
            // Vision boxes are normalised with origin bottom-left.
            let b = o.boundingBox
            let r = CGRect(x: rect.minX + b.minX * rect.width,
                           y: rect.minY + (1 - b.maxY) * rect.height,
                           width: b.width * rect.width, height: b.height * rect.height)
            return Line(text: top.string, rect: r, observation: top, capture: rect)
        }
        .sorted { abs($0.rect.minY - $1.rect.minY) > 4 ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
    }

    /// The word under the pointer, with nearby lines as context.
    func pointer(at p: CGPoint, _ base: Capture) async -> Capture? {
        let ls = await lines(around: p)
        guard let hitIndex = ls.firstIndex(where: { $0.rect.insetBy(dx: -2, dy: -3).contains(p) }) else { return nil }
        let line = ls[hitIndex]
        let ns = line.text as NSString
        // Find the word whose box contains the pointer.
        var found: (String, NSRange, CGRect)? = nil
        var i = 0
        while i < ns.length {
            guard let (w, wr) = ContextText.word(in: line.text, at: i) else { i += 1; continue }
            if let range = Range(wr, in: line.text), let box = try? line.observation.boundingBox(for: range) {
                let r = mapBox(box.boundingBox, line: line)
                if r.insetBy(dx: -2, dy: -4).contains(CGPoint(x: p.x, y: r.midY)) { found = (w, wr, r); break }
            }
            i = NSMaxRange(wr) + 1
        }
        guard let (word, _, box) = found else { return nil }
        let (ctx, rel) = join(ls, focus: hitIndex, term: word, near: p)
        var c = base
        c.term = word
        c.source = .screen
        c.context = ctx
        c.termRange = rel
        c.anchor = box
        return c
    }

    /// Context for a known term: the lines around where it appears on screen.
    func context(around p: CGPoint, containing term: String) async -> (text: String, range: NSRange?, anchor: CGRect?)? {
        let ls = await lines(around: p)
        guard !ls.isEmpty else { return nil }
        let first = term.split(separator: " ").first.map(String.init) ?? term
        guard let idx = ls.indices.min(by: { a, b in
            let ha = ls[a].text.localizedCaseInsensitiveContains(first) ? 0 : 1
            let hb = ls[b].text.localizedCaseInsensitiveContains(first) ? 0 : 1
            if ha != hb { return ha < hb }
            return abs(ls[a].rect.midY - p.y) < abs(ls[b].rect.midY - p.y)
        }) else { return nil }
        let (ctx, rel) = join(ls, focus: idx, term: term, near: p)
        return (ctx, rel, ls[idx].rect)
    }

    private func join(_ ls: [Line], focus: Int, term: String, near p: CGPoint) -> (String, NSRange?) {
        let lo = max(0, focus - 4), hi = min(ls.count - 1, focus + 4)
        // Merge lines that sit on the same row into one line of text.
        var rows: [String] = []
        var lastY: CGFloat? = nil
        for l in ls[lo...hi] {
            if let y = lastY, abs(l.rect.minY - y) < 4, !rows.isEmpty { rows[rows.count - 1] += "  " + l.text }
            else { rows.append(l.text) }
            lastY = l.rect.minY
        }
        let text = rows.joined(separator: "\n")
        let r = (text as NSString).range(of: term)
        return (text, r.location == NSNotFound ? nil : r)
    }

    /// Vision's word boxes are normalised to the captured image, origin bottom-left.
    private func mapBox(_ bb: CGRect, line: Line) -> CGRect {
        let c = line.capture
        return CGRect(x: c.minX + bb.minX * c.width, y: c.minY + (1 - bb.maxY) * c.height,
                      width: bb.width * c.width, height: bb.height * c.height)
    }
}

extension NSScreen {
    /// This screen's frame in Accessibility coordinates (origin top-left of the primary display).
    var axFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

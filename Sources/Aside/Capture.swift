import AppKit
import ApplicationServices

/// What the reader pointed at, and where.
struct Capture: Equatable {
    enum Source: String { case selection, pointer, clipboard, screen }

    var term: String = ""
    var context: String = ""
    /// The term's range inside `context` (UTF-16), when known.
    var termRange: NSRange? = nil
    var appName: String = ""
    var bundleID: String = ""
    var windowTitle: String = ""
    /// Bounds of the term on screen, in Accessibility coordinates (origin top-left of the primary display).
    var anchor: CGRect? = nil
    var source: Source = .selection
    var captureMs: Double = 0

    var markedContext: String {
        let ns = context as NSString
        if let r = termRange, r.location != NSNotFound, NSMaxRange(r) <= ns.length {
            return ns.replacingCharacters(in: r, with: "⟦\(ns.substring(with: r))⟧")
        }
        if let r = context.range(of: term) {
            var c = context
            c.replaceSubrange(r, with: "⟦\(term)⟧")
            return c
        }
        return context
    }

    var cacheKey: String { "\(term)\u{1}\(context)" }

    static func == (a: Capture, b: Capture) -> Bool {
        a.term == b.term && a.context == b.context && a.bundleID == b.bundleID
    }
}

/// Text-window helpers working in UTF-16 offsets, which is what Accessibility ranges use.
enum ContextText {
    static let budget = 1400

    /// The paragraph holding `range`, grown by neighbouring paragraphs while it fits the budget.
    static func window(_ full: String, _ range: NSRange) -> (String, NSRange) {
        let ns = full as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return ("", NSRange(location: NSNotFound, length: 0)) }
        var win = ns.paragraphRange(for: range)
        // A huge paragraph (or a document with no newlines): take a centred slice.
        if win.length > budget {
            let start = max(0, range.location - budget / 2)
            let end = min(ns.length, max(NSMaxRange(range), start + budget))
            win = NSRange(location: start, length: end - start)
        } else {
            var grew = true
            while grew {
                grew = false
                if win.location > 0 {
                    let prev = ns.paragraphRange(for: NSRange(location: win.location - 1, length: 0))
                    if win.length + prev.length <= budget { win = NSUnionRange(win, prev); grew = true }
                }
                if NSMaxRange(win) < ns.length {
                    let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(win), length: 0))
                    if win.length + next.length <= budget { win = NSUnionRange(win, next); grew = true }
                }
            }
        }
        let text = ns.substring(with: win)
        let rel = NSRange(location: range.location - win.location, length: range.length)
        // Trim surrounding whitespace while keeping the relative range valid.
        let lead = text.prefix(while: { $0.isWhitespace || $0.isNewline }).utf16.count
        let trimmedText = text.trimmed
        return (trimmedText, NSRange(location: max(0, rel.location - lead), length: rel.length))
    }

    /// The word at a UTF-16 offset: letters, digits and joiners like - _ ' and inner dots.
    static func word(in text: String, at offset: Int) -> (String, NSRange)? {
        let ns = text as NSString
        guard offset >= 0, offset < ns.length else { return nil }
        func isWordChar(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length else { return false }
            let c = ns.character(at: i)
            guard let scalar = Unicode.Scalar(c) else { return true } // surrogate halves: part of a word
            if CharacterSet.alphanumerics.contains(scalar) { return true }
            if "-_'’".unicodeScalars.contains(scalar) { return true }
            if scalar == "." { return isAlnum(i - 1) && isAlnum(i + 1) }
            return false
        }
        func isAlnum(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length, let s = Unicode.Scalar(ns.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(s)
        }
        guard isWordChar(offset) else { return nil }
        var a = offset, b = offset
        while isWordChar(a - 1) { a -= 1 }
        while isWordChar(b + 1) { b += 1 }
        var r = NSRange(location: a, length: b - a + 1)
        // Trim joiners at the edges ("'quoted'" → quoted).
        let trimSet = CharacterSet(charactersIn: "-_'’.")
        while r.length > 0, let s = Unicode.Scalar(ns.character(at: r.location)), trimSet.contains(s) { r.location += 1; r.length -= 1 }
        while r.length > 0, let s = Unicode.Scalar(ns.character(at: NSMaxRange(r) - 1)), trimSet.contains(s) { r.length -= 1 }
        guard r.length > 0 else { return nil }
        return (ns.substring(with: r), r)
    }

    /// Drop object-replacement characters (images, embeds) and keep the term's range in step.
    static func clean(_ c: Capture) -> Capture {
        guard c.context.contains("\u{FFFC}") else { return c }
        var c = c
        let ns = c.context as NSString
        var out: [unichar] = []
        out.reserveCapacity(ns.length)
        var shiftBefore = 0
        let loc = c.termRange?.location ?? Int.max
        for i in 0..<ns.length {
            let ch = ns.character(at: i)
            if ch == 0xFFFC { if i < loc { shiftBefore += 1 }; continue }
            out.append(ch)
        }
        if let r = c.termRange { c.termRange = NSRange(location: r.location - shiftBefore, length: r.length) }
        c.context = String(utf16CodeUnits: out, count: out.count)
        return c
    }

    /// A short excerpt around the term for the panel's eyebrow line.
    static func snippet(_ c: Capture, maxLen: Int = 90) -> (before: String, term: String, after: String)? {
        let ns = c.context as NSString
        guard !c.context.isEmpty else { return nil }
        var r = c.termRange ?? NSRange(location: NSNotFound, length: 0)
        if r.location == NSNotFound || NSMaxRange(r) > ns.length {
            let found = ns.range(of: c.term, options: .caseInsensitive)
            guard found.location != NSNotFound else { return nil }
            r = found
        }
        let room = max(0, maxLen - r.length) / 2
        let lineStart = ns.lineRange(for: NSRange(location: r.location, length: 0)).location
        let lineEnd = NSMaxRange(ns.lineRange(for: NSRange(location: max(r.location, NSMaxRange(r) - 1), length: 0)))
        let s = max(lineStart, r.location - room)
        let e = min(lineEnd, NSMaxRange(r) + room)
        let before = ns.substring(with: NSRange(location: s, length: r.location - s))
        let after = ns.substring(with: NSRange(location: NSMaxRange(r), length: max(0, e - NSMaxRange(r))))
        let clean: (String) -> String = { $0.replacingOccurrences(of: "\n", with: " ") }
        return ((s > lineStart ? "…" : "") + clean(before).trimmingCharacters(in: .whitespaces).withTrailingSpace(if: before.last?.isWhitespace == true),
                ns.substring(with: r),
                clean(after).withLeadingSpaceTrimmed(keepOne: after.first?.isWhitespace == true) + (e < lineEnd ? "…" : ""))
    }
}

private extension String {
    func withTrailingSpace(if cond: Bool) -> String { cond && !isEmpty ? self + " " : self }
    func withLeadingSpaceTrimmed(keepOne: Bool) -> String {
        let t = trimmingCharacters(in: .whitespaces)
        return keepOne && !t.isEmpty ? " " + t : t
    }
}

/// Finds what the reader means: their selection, or the word under the pointer, plus the text around it.
@MainActor
final class Capturer {
    private var primed = Set<pid_t>()
    let ocr = ScreenText()
    /// Testing only: read this app instead of the frontmost one.
    var forcedBundleID: String?

    enum Selection { case found(Capture), empty, unknown }

    func capture() async -> Capture? {
        let t0 = CFAbsoluteTimeGetCurrent()
        let forced = forcedBundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        guard let app = forced ?? NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.35)
        prime(appEl, pid: pid, bundleID: app.bundleIdentifier ?? "")

        var base = Capture()
        base.appName = app.localizedName ?? ""
        base.bundleID = app.bundleIdentifier ?? ""
        if let win = AX.element(appEl, kAXFocusedWindowAttribute) {
            base.windowTitle = AX.string(win, kAXTitleAttribute) ?? ""
        }
        let mouse = AX.mouseLocation()

        func done(_ c: Capture) -> Capture {
            var c = ContextText.clean(c)
            c.term = c.term.trimmed
            c.captureMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            return c
        }

        // 1. A selection the app reports through Accessibility.
        var axSaysEmpty = false
        if let focused = AX.element(appEl, kAXFocusedUIElementAttribute) {
            switch selection(in: focused, base) {
            case .found(let c): return done(await enrich(c, near: mouse))
            case .empty: axSaysEmpty = true
            case .unknown: break
            }
        }

        // 2. Apps that hide their selection from Accessibility: copy it, then put the clipboard back.
        if !axSaysEmpty, forcedBundleID == nil, let text = await Clipboard.copySelection() {
            var c = base
            c.term = text
            c.source = .clipboard
            return done(await enrich(c, near: mouse))
        }

        // 3. Nothing selected: the word under the pointer.
        if let c = pointer(at: mouse, base) { return done(c) }
        if let c = await ocr.pointer(at: mouse, base) { return done(c) }
        return nil
    }

    // MARK: Selection

    func selection(in el: AXUIElement, _ base: Capture) -> Selection {
        // Web content (Safari, Chrome, Electron): text markers.
        if let wa = AX.webArea(from: el), let mr = AX.attr(wa, "AXSelectedTextMarkerRange") {
            let sel = (AX.param(wa, "AXStringForTextMarkerRange", mr) as? String)?.trimmed ?? ""
            if !sel.isEmpty {
                var c = base
                c.term = sel
                c.source = .selection
                c.anchor = AX.rect(AX.param(wa, "AXBoundsForTextMarkerRange", mr))
                if let start = AX.startMarker(mr),
                   let end = AX.endMarker(mr) {
                    let (ctx, rel) = webContext(wa, start: start, end: end, selected: sel)
                    c.context = ctx
                    c.termRange = rel
                }
                return .found(c)
            }
            // The web area's selection is empty, but a text field inside it might hold one: fall through.
        }

        let selText = AX.string(el, kAXSelectedTextAttribute)
        let selRange = AX.range(AX.attr(el, kAXSelectedTextRangeAttribute))
        guard let t = selText?.trimmed, !t.isEmpty else {
            // A text element that answers "no selection" is a definite empty; anything else is unknown.
            if selRange != nil || selText != nil { return .empty }
            return .unknown
        }
        var c = base
        c.term = t
        c.source = .selection
        if let r = selRange, r.length > 0 {
            c.anchor = AX.rect(AX.param(el, kAXBoundsForRangeParameterizedAttribute, AX.value(r)))
            if let (ctx, rel) = textContext(el, range: r) {
                c.context = ctx
                c.termRange = rel
            }
        }
        return .found(c)
    }

    /// Context from a plain text element (text views, fields, terminals that expose their buffer).
    private func textContext(_ el: AXUIElement, range r: CFRange) -> (String, NSRange)? {
        let nsr = NSRange(location: r.location, length: r.length)
        let count = (AX.attr(el, kAXNumberOfCharactersAttribute) as? Int) ?? -1
        if count >= 0 && count <= 400_000, let full = AX.string(el, kAXValueAttribute) {
            let out = ContextText.window(full, nsr)
            return out.0.isEmpty ? nil : out
        }
        // Huge buffers: ask for just a slice around the selection.
        let start = max(0, r.location - 1500)
        let len = min(r.location - start + r.length + 1500, max(0, (count > 0 ? count : Int.max) - start))
        if let slice = AX.param(el, kAXStringForRangeParameterizedAttribute, AX.value(CFRange(location: start, length: len))) as? String {
            let out = ContextText.window(slice, NSRange(location: r.location - start, length: r.length))
            return out.0.isEmpty ? nil : out
        }
        return nil
    }

    /// Context from web content: the paragraphs holding the selection, plus neighbours while short.
    /// Paragraphs are read one at a time and joined with newlines, because Chromium's range strings drop the breaks.
    private func webContext(_ wa: AXUIElement, start: CFTypeRef, end: CFTypeRef, selected: String) -> (String, NSRange?) {
        func para(_ m: CFTypeRef?) -> CFTypeRef? { m.flatMap { AX.param(wa, "AXParagraphTextMarkerRangeForTextMarker", $0) } }
        func str(_ r: CFTypeRef?) -> String { r.flatMap { AX.param(wa, "AXStringForTextMarkerRange", $0) as? String } ?? "" }
        func index(_ m: CFTypeRef?) -> Int? { m.flatMap { AX.param(wa, "AXIndexForTextMarker", $0) as? Int } }
        guard let first = para(start) else { return ("", nil) }
        let lo = AX.startMarker(first)
        var hi = AX.endMarker(first)
        if let e = AX.endMarker(para(end)) { hi = e }
        let core = str(AX.markerRange(wa, lo, hi))
        let lead = core.prefix(while: { $0.isWhitespace || $0.isNewline }).utf16.count
        var offset = (str(AX.markerRange(wa, lo, start)) as NSString).length - lead
        var parts = [core.trimmed]
        var total = parts[0].count

        // Lists and short paragraphs: pull in neighbours so "flush" sees "write vs … fsync" and its heading.
        var back = lo, fwd = hi
        var seen: Set<String> = [parts[0]]
        var steps = 0
        while total < 500 && steps < 6 {
            steps += 1
            var changed = false
            if let b = back, let pm = AX.param(wa, "AXPreviousTextMarkerForTextMarker", b),
               let pr = para(pm), !seen.contains(str(pr).trimmed) {
                let t = str(pr).trimmed
                back = AX.startMarker(pr) ?? pm
                seen.insert(t)
                if !t.isEmpty && total + t.count <= ContextText.budget {
                    parts.insert(t, at: 0)
                    offset += (t as NSString).length + 1
                    total += t.count
                }
                changed = true
            }
            if let f = fwd, let nm = AX.param(wa, "AXNextTextMarkerForTextMarker", f),
               let pr = para(nm), !seen.contains(str(pr).trimmed) {
                let t = str(pr).trimmed
                fwd = AX.endMarker(pr) ?? nm
                seen.insert(t)
                if !t.isEmpty && total + t.count <= ContextText.budget {
                    parts.append(t)
                    total += t.count
                }
                changed = true
            }
            if !changed { break }
        }
        let ctx = parts.joined(separator: "\n")
        let ns = ctx as NSString
        let len = (selected as NSString).length
        var rel: NSRange? = nil
        if offset >= 0, offset + len <= ns.length, ns.substring(with: NSRange(location: offset, length: len)) == selected {
            rel = NSRange(location: offset, length: len)
        } else {
            let f = ns.range(of: selected)
            if f.location != NSNotFound { rel = f }
        }
        return (ctx, rel)
    }

    // MARK: Pointer

    func pointer(at p: CGPoint, _ base: Capture) -> Capture? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.3)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &hit) == .success, let el = hit else { return nil }

        if let wa = AX.webArea(from: el), let (m, wordBounds) = webMarker(wa, el, at: p),
           let para = AX.param(wa, "AXParagraphTextMarkerRangeForTextMarker", m),
           let ptext = AX.param(wa, "AXStringForTextMarkerRange", para) as? String,
           let pstart = AX.startMarker(para),
           let prefixRange = AX.markerRange(wa, pstart, m),
           let prefix = AX.param(wa, "AXStringForTextMarkerRange", prefixRange) as? String,
           let (word, wr) = ContextText.word(in: ptext, at: (prefix as NSString).length)
                ?? ContextText.word(in: ptext, at: max(0, (prefix as NSString).length - 1)) {
            var c = base
            c.term = word
            c.source = .pointer
            c.anchor = wordBounds ?? CGRect(x: p.x, y: p.y - 9, width: 1, height: 18)
            let (ctx, rel) = widenWeb(wa, para: para, ptext: ptext, wordRange: wr)
            c.context = ctx
            c.termRange = rel
            return c
        }

        if let r = AX.range(AX.param(el, kAXRangeForPositionParameterizedAttribute, AX.value(p))),
           // Some apps answer with offset 0 for anything; only trust a character that is actually under the pointer.
           let charBounds = AX.rect(AX.param(el, kAXBoundsForRangeParameterizedAttribute, AX.value(CFRange(location: r.location, length: 1)))),
           charBounds.insetBy(dx: -3, dy: -4).contains(p),
           let (ctx, rel) = textContext(el, range: CFRange(location: r.location, length: max(1, r.length))),
           let (word, wr) = ContextText.word(in: ctx, at: rel.location) {
            var c = base
            c.term = word
            c.source = .pointer
            c.context = ctx
            c.termRange = wr
            let absolute = CFRange(location: r.location - (rel.location - wr.location), length: wr.length)
            c.anchor = AX.rect(AX.param(el, kAXBoundsForRangeParameterizedAttribute, AX.value(absolute)))
            return c
        }
        return nil
    }

    /// A text marker inside the word under the pointer, and that word's bounds.
    /// WebKit answers AXTextMarkerForPosition directly; Chromium doesn't, so walk the hovered element's words.
    private func webMarker(_ wa: AXUIElement, _ el: AXUIElement, at p: CGPoint) -> (CFTypeRef, CGRect?)? {
        if let m = AX.param(wa, "AXTextMarkerForPosition", AX.value(p)) {
            var bounds: CGRect? = nil
            if let w = AX.param(wa, "AXRightWordTextMarkerRangeForTextMarker", m) {
                bounds = AX.rect(AX.param(wa, "AXBoundsForTextMarkerRange", w))
            }
            return (m, bounds)
        }
        guard let elRange = AX.param(wa, "AXTextMarkerRangeForUIElement", el),
              var cur = AX.startMarker(elRange) else { return nil }
        let endIndex = AX.endMarker(elRange)
            .flatMap { AX.param(wa, "AXIndexForTextMarker", $0) as? Int } ?? Int.max
        var lastIndex = -1
        for _ in 0..<800 {
            guard let wEnd = AX.param(wa, "AXNextWordEndTextMarkerForTextMarker", cur),
                  let wStart = AX.param(wa, "AXPreviousWordStartTextMarkerForTextMarker", wEnd),
                  let range = AX.markerRange(wa, wStart, wEnd) else { return nil }
            let idx = (AX.param(wa, "AXIndexForTextMarker", wEnd) as? Int) ?? lastIndex + 1
            if idx <= lastIndex || idx > endIndex + 1 { return nil }
            lastIndex = idx
            if let b = AX.rect(AX.param(wa, "AXBoundsForTextMarkerRange", range)) {
                if b.insetBy(dx: -2, dy: -3).contains(p) { return (wStart, b) }
                if b.minY > p.y + 60 { return nil }
            }
            cur = wEnd
        }
        return nil
    }

    private func widenWeb(_ wa: AXUIElement, para: CFTypeRef, ptext: String, wordRange: NSRange) -> (String, NSRange) {
        guard (ptext as NSString).length < 500,
              let s = AX.startMarker(para),
              let e = AX.endMarker(para) else { return (ptext.trimmed, wordRange) }
        var before = ""
        var after = ""
        if let p = AX.param(wa, "AXPreviousParagraphStartTextMarkerForTextMarker", s),
           let r = AX.markerRange(wa, p, s),
           let t = AX.param(wa, "AXStringForTextMarkerRange", r) as? String, t.count < 700 { before = t }
        if let n = AX.param(wa, "AXNextParagraphEndTextMarkerForTextMarker", e),
           let r = AX.markerRange(wa, e, n),
           let t = AX.param(wa, "AXStringForTextMarkerRange", r) as? String, t.count < 700 { after = t }
        // Chromium's range strings drop paragraph breaks; put them back.
        let head = before.isEmpty || before.hasSuffix("\n") ? before : before + "\n"
        let tail = after.isEmpty || after.hasPrefix("\n") ? after : "\n" + after
        let full = head + ptext + tail
        let rel = NSRange(location: wordRange.location + (head as NSString).length, length: wordRange.length)
        let lead = full.prefix(while: { $0.isWhitespace || $0.isNewline }).utf16.count
        return (full.trimmed, NSRange(location: max(0, rel.location - lead), length: rel.length))
    }

    // MARK: Context for a copied selection

    /// A copied selection has no context. Borrow it from the text under the pointer, or from the screen.
    private func enrich(_ c: Capture, near p: CGPoint) async -> Capture {
        guard c.context.isEmpty else { return c }
        var c = c
        if let around = pointer(at: p, c) {
            let r = (around.context as NSString).range(of: c.term, options: .caseInsensitive)
            if r.location != NSNotFound {
                c.context = around.context
                c.termRange = r
                if c.anchor == nil { c.anchor = around.anchor }
                return c
            }
        }
        if (c.term as NSString).length < 120, let shot = await ocr.context(around: p, containing: c.term) {
            c.context = shot.text
            c.termRange = shot.range
            if c.anchor == nil { c.anchor = shot.anchor }
        }
        return c
    }

    // MARK: App priming

    /// Called when an app comes to the front, so its tree is ready before the first look-up.
    func prime(_ app: NSRunningApplication) {
        prime(AXUIElementCreateApplication(app.processIdentifier), pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "")
    }

    /// Chrome and Electron build their accessibility tree only when asked. Ask once per process.
    private func prime(_ appEl: AXUIElement, pid: pid_t, bundleID: String) {
        guard !primed.contains(pid) else { return }
        primed.insert(pid)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let chromiumLike = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
                            "com.vivaldi.Vivaldi", "org.chromium.Chromium", "com.operasoftware.Opera"]
        if chromiumLike.contains(where: { bundleID.hasPrefix($0) }) {
            AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
}

/// Copy the frontmost app's selection with ⌘C, then restore what was on the clipboard.
enum Clipboard {
    @MainActor
    static func copySelection() async -> String? {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        let before = pb.changeCount
        let src = CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(8))
            if pb.changeCount != before { break }
        }
        guard pb.changeCount != before else { return nil }
        try? await Task.sleep(for: .milliseconds(5))
        // Copied files (Finder) or images are not text to look up.
        let isFiles = pb.types?.contains(.fileURL) == true
        let text = isFiles ? nil : pb.string(forType: .string)
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
        return text?.nonEmpty
    }
}

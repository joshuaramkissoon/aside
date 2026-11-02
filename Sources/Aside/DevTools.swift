import AppKit
import SwiftUI

/// Development helpers: real-window screenshots of fixed states, and a capture probe.
@MainActor
enum DevTools {
    static func probe(after delay: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if ProcessInfo.processInfo.environment["DEBUG_POINTER"] != nil { debugPointer(AX.mouseLocation()) }
            if let b = ProcessInfo.processInfo.environment["DEBUG_PARA"] { debugParagraphs(bundleID: b) }
            let capturer = Capturer()
            capturer.forcedBundleID = ProcessInfo.processInfo.environment["PROBE_APP"]
            let cap = await capturer.capture()
            var out: [String: Any] = ["found": cap != nil]
            if let c = cap {
                out["term"] = c.term
                out["source"] = c.source.rawValue
                out["app"] = c.appName
                out["window"] = c.windowTitle
                out["context"] = c.markedContext
                out["anchor"] = c.anchor.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none"
                out["ms"] = Int(c.captureMs)
            }
            let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
            exit(0)
        }
    }

    /// Print how paragraph navigation behaves around the current selection in a web area.
    static func debugParagraphs(bundleID: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let f = AX.element(appEl, kAXFocusedUIElementAttribute), let wa = AX.webArea(from: f),
              let sel = AX.attr(wa, "AXSelectedTextMarkerRange"), let s = AX.startMarker(sel) else { print("no web selection"); return }
        func str(_ r: CFTypeRef?) -> String { r.flatMap { AX.param(wa, "AXStringForTextMarkerRange", $0) as? String } ?? "<nil>" }
        func idx(_ m: CFTypeRef?) -> String { m.flatMap { AX.param(wa, "AXIndexForTextMarker", $0) }.map { "\($0)" } ?? "nil" }
        let para = AX.param(wa, "AXParagraphTextMarkerRangeForTextMarker", s)
        print("start idx", idx(s), "para:", str(para).prefix(50))
        let ps = AX.startMarker(para)
        print("para start idx", idx(ps))
        var m = ps
        for i in 0..<4 {
            m = m.flatMap { AX.param(wa, "AXPreviousTextMarkerForTextMarker", $0) }
            print(" prev[\(i)] idx", idx(m), "para:", str(m.flatMap { AX.param(wa, "AXParagraphTextMarkerRangeForTextMarker", $0) }).prefix(50))
        }
        let pp = ps.flatMap { AX.param(wa, "AXPreviousParagraphStartTextMarkerForTextMarker", $0) }
        print("prevParaStart idx", idx(pp), "para:", str(pp.flatMap { AX.param(wa, "AXParagraphTextMarkerRangeForTextMarker", $0) }).prefix(50))
        let line = AX.param(wa, "AXLineForTextMarker", s)
        print("line", line as Any)
    }

    /// Print what the text-marker API returns under the pointer.
    static func debugPointer(_ p: CGPoint) {
        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit)
        guard let el = hit else { print("no element at \(p)"); return }
        print("hit role:", AX.role(el), "value:", (AX.string(el, kAXValueAttribute) ?? "").prefix(60))
        guard let wa = AX.webArea(from: el) else { print("no web area"); return }
        print("web params:", AX.parameterizedNames(wa).filter { $0.contains("Marker") || $0.contains("Index") }.joined(separator: ", "))
        var rect = CGRect(x: p.x, y: p.y, width: 1, height: 1)
        let viaBounds = AX.param(wa, "AXStartTextMarkerForBounds", AXValueCreate(.cgRect, &rect)!)
        print("marker via bounds:", viaBounds != nil)
        let elRange = AX.param(wa, "AXTextMarkerRangeForUIElement", el)
        print("el range:", elRange != nil, "el range on el:", AX.param(el, "AXTextMarkerRangeForUIElement", el) != nil)
        if let elRange, let s = AX.param(wa, "AXStartTextMarkerForTextMarkerRange", elRange) {
            print("start idx:", AX.param(wa, "AXIndexForTextMarker", s) as Any)
            if let e1 = AX.param(wa, "AXNextWordEndTextMarkerForTextMarker", s) {
                print("first word end idx:", AX.param(wa, "AXIndexForTextMarker", e1) as Any)
                let ws = AX.param(wa, "AXPreviousWordStartTextMarkerForTextMarker", e1)
                print("word start:", ws != nil)
                if let ws, let r = AX.param(wa, "AXTextMarkerRangeForUnorderedTextMarkers", [ws, e1] as CFArray) {
                    print("word:", AX.param(wa, "AXStringForTextMarkerRange", r) as Any, "bounds:", AX.rect(AX.param(wa, "AXBoundsForTextMarkerRange", r)) as Any, "p:", p)
                } else { print("unordered range failed") }
            } else { print("next word end failed") }
        }
        guard let m = AX.param(wa, "AXTextMarkerForPosition", AX.value(p)) ?? viaBounds else { print("no marker"); return }
        let idx = AX.param(wa, "AXIndexForTextMarker", m)
        print("index:", idx as Any)
        if let w = AX.param(wa, "AXRightWordTextMarkerRangeForTextMarker", m) {
            print("right word:", AX.param(wa, "AXStringForTextMarkerRange", w) as Any)
        }
        if let w = AX.param(wa, "AXLeftWordTextMarkerRangeForTextMarker", m) {
            print("left word:", AX.param(wa, "AXStringForTextMarkerRange", w) as Any)
        }
        if let para = AX.param(wa, "AXParagraphTextMarkerRangeForTextMarker", m),
           let s = AX.param(wa, "AXStartTextMarkerForTextMarkerRange", para) {
            print("para start index:", AX.param(wa, "AXIndexForTextMarker", s) as Any)
            let r = AX.param(wa, "AXTextMarkerRangeForUnorderedTextMarkers", [s, m] as CFArray)
            print("prefix range:", r != nil, "prefix:", r.flatMap { AX.param(wa, "AXStringForTextMarkerRange", $0) } as Any)
            let r2 = AX.param(wa, "AXTextMarkerRangeForTextMarkers", [s, m] as CFArray)
            print("ordered range:", r2.flatMap { AX.param(wa, "AXStringForTextMarkerRange", $0) } as Any)
        }
    }

    /// Render the app icon at 1024px (scripts/icon.sh turns it into an .icns).
    static func icon(to path: String) {
        let view = AppIconArt().frame(width: 1024, height: 1024)
        let r = ImageRenderer(content: view)
        r.scale = 1
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }

    static func shots(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            let pc = PanelController()
            let screen = NSScreen.screens[0].frame
            let anchor = CGRect(x: 260, y: 140, width: 60, height: 22)
            var cases: [(String, () -> PanelUI.Mode)] = []
            cases.append(("flush", { .lookup(Fixtures.flush()) }))
            cases.append(("lru", { .lookup(Fixtures.lru()) }))
            cases.append(("thread", { .lookup(Fixtures.thread()) }))
            cases.append(("loading", { .lookup(Fixtures.loading()) }))
            cases.append(("prose", { .lookup(Fixtures.prose()) }))
            cases.append(("error", { .lookup(LookupSession.failedFixture(Fixtures.flushCapture, EngineError.noKey.errorDescription!)) }))
            cases.append(("hint", { .hint(title: "Nothing to look up", body: "Select some text, or point at a word, then press ⌥ Space.", action: nil) }))
            let only = ProcessInfo.processInfo.environment["SHOTS"]?.split(separator: ",").map(String.init)
            let themes = ProcessInfo.processInfo.environment["THEMES"]?.split(separator: ",").map(String.init) ?? Palette.all.map(\.id)
            let looks = ProcessInfo.processInfo.environment["LOOKS"]?.split(separator: ",").map(String.init) ?? ["dark", "light"]
            for theme in themes {
                Settings.shared.theme = theme
                for look in looks {
                    pc.panel.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
                    for (name, make) in cases where only == nil || only!.contains(name) {
                        pc.showFixture(make(), anchor: anchor)
                        try? await Task.sleep(for: .milliseconds(name == "loading" ? 350 : 700))
                        let path = "\(dir)/\(theme)-\(look)-\(name).png"
                        shoot(window: pc.panel.windowNumber, to: path)
                        pc.panel.orderOut(nil)
                    }
                }
            }
            if ProcessInfo.processInfo.environment["SETTINGS"] != nil {
                for look in looks {
                    let w = NSWindow(contentRect: NSRect(x: 80, y: screen.height - 760, width: 540, height: 660),
                                     styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
                    w.titlebarAppearsTransparent = true
                    w.titleVisibility = .hidden
                    w.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
                    w.contentView = NSHostingView(rootView: SettingsView())
                    w.orderFrontRegardless()
                    try? await Task.sleep(for: .milliseconds(800))
                    shoot(window: w.windowNumber, to: "\(dir)/settings-\(look).png")
                    w.orderOut(nil)
                }
            }
            print("shots in \(dir)")
            exit(0)
        }
    }

    private static func shoot(window: Int, to path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-l", String(window), path]
        try? p.run()
        p.waitUntilExit()
    }
}

extension PanelController {
    /// Show a canned state at an anchor (Accessibility coordinates), for screenshots.
    func showFixture(_ mode: PanelUI.Mode, anchor: CGRect) {
        ui.mode = mode
        ui.draft = ""
        ui.selected = nil
        present(anchor: anchor)
    }
}

/// The icon: a margin note. Warm dark card, a serif "a" in paper ink, the rubric highlighter under it.
struct AppIconArt: View {
    var body: some View {
        let s = Palette.named("rubric").dark
        ZStack {
            RoundedRectangle(cornerRadius: 228, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x2A241E), Color(hex: 0x1A1612)], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 28, y: 14)
            // The highlighter stroke, like a ==mark== in an answer.
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(s.accent.opacity(0.92))
                .frame(width: 500, height: 124)
                .rotationEffect(.degrees(-3.5))
                .offset(x: 0, y: 166)
            Text("a")
                .font(.system(size: 640, weight: .semibold, design: .serif))
                .foregroundStyle(s.ink)
                .offset(x: -6, y: -40)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor enum Fixtures {
    static let flushCapture = Capture(
        term: "flush",
        context: "K3 · Caches and durability (about 9,800 words):\nLRU internals and memoisation;\nwrite vs flush vs fsync vs fsyncing the directory;\nframing the records in a write-ahead log, torn writes, compaction and atomic replace, with crash tests;",
        termRange: nil,
        appName: "Claude", bundleID: "com.anthropic.claudefordesktop", windowTitle: "Workbook plan", source: .selection)

    static let flushRaw = """
TERM: flush
EXPANDS:
KIND: I/O operation
GIST: Hands buffered writes to the OS, but does ==not guarantee they reach disk== — that's fsync's job.
- `write` copies into the program's buffer; `flush` pushes it to the kernel's page cache; `fsync` forces it to the physical disk.
- Flushing alone survives a process crash but **not** a power loss — the page cache dies with the machine.
NEXT:
? Why fsync the directory too?
? How does a write-ahead log use this?
"""

    static func flush() -> LookupSession { LookupSession.fixture(flushCapture, [(nil, flushRaw)]) }

    static func lru() -> LookupSession {
        var c = flushCapture
        c.term = "LRU"
        c.termRange = NSRange(location: 49, length: 3)
        return LookupSession.fixture(c, [(nil, """
TERM: LRU
EXPANDS: Least Recently Used
KIND: cache policy
GIST: An eviction rule that ==discards the entry untouched longest== when the cache is full.
- Assumes recent use predicts future use; a one-off scan can **flush** useful entries, the classic scan-resistance problem.
- Contrast with LFU (evicts least *frequently* used) and FIFO (oldest inserted, ignoring reads).
NEXT:
? How does LRU interact with memoisation?
? What is a segmented LRU cache?
""")])
    }

    static func thread() -> LookupSession {
        LookupSession.fixture(flushCapture, [(nil, flushRaw), ("why fsync the directory too?", """
GIST: Creating or renaming a file changes the ==directory entry==, which lives in its own block, so fsyncing the file alone can still lose the name.
- `fsync(file_fd)` makes the *contents* durable; the entry pointing at it needs its own `fsync(dir_fd)`.
- The atomic-replace pattern: write a temp file, `fsync` it, `rename` over the target, then `fsync` the directory.
```c
write(fd, buf, n); fsync(fd); close(fd);
rename("tmp", "target");
int dfd = open(".", O_RDONLY); fsync(dfd);
```
NEXT:
? Does rename ever leave neither name?
? How does SQLite fsync its journal?
""")])
    }

    static func loading() -> LookupSession {
        var c = flushCapture
        c.term = "ahead"
        c.source = .pointer
        return LookupSession.fixture(c, [(nil, "")])
    }

    static func prose() -> LookupSession {
        let c = Capture(term: "flushed",
                        context: "When I mentioned the letter, Miss Kenton flushed and turned quickly to the window, as though something in the garden had caught her attention.",
                        termRange: NSRange(location: 41, length: 7),
                        appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "The Remains of the Day", source: .selection)
        return LookupSession.fixture(c, [(nil, """
TERM: flushed
EXPANDS:
KIND: verb
GIST: Her face ==reddened suddenly==, the telltale blush of embarrassment or strong feeling.
- The quick turn to the window is the giveaway: she's **hiding** her reaction, so the blush betrays more than she wants.
NEXT:
? What does Miss Kenton's blush reveal?
? Other uses of "flush" in English
""")])
    }
}

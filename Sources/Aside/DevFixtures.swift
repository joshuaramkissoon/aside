import AppKit
import SwiftUI

/// Edge-case fixtures and window screenshots for `Aside --shots`.
extension DevTools {
    /// `Aside --selftest`: capture from Aside's own try-it text (selection and pointer), plus word segmentation.
    static func selfTest() {
        Task { @MainActor in
            for (s, i) in [("東京都に住んでいます", 1), ("我喜欢学习中文和历史", 4), ("ภาษาไทยไม่มีช่องว่าง", 2), ("write-ahead log", 3)] {
                let w = ContextText.word(in: s, at: i)
                print("word(\(s), \(i)) =", w?.0 ?? "nil")
            }
            print("capTerm 3000 chars →", ContextText.capTerm(String(repeating: "lorem ipsum ", count: 250)).count, "chars")

            let model = Onboarding(start: .tryIt)
            model.polls = false
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: OnboardingView.size.width, height: OnboardingView.size.height),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Welcome to Aside"
            w.contentView = NSHostingView(rootView: OnboardingView(model: model))
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(600))
            func find(_ v: NSView) -> NSTextView? {
                if let t = v as? NSTextView { return t }
                for s in v.subviews { if let t = find(s) { return t } }
                return nil
            }
            guard let content = w.contentView, let tv = find(content) else { print("no text view"); exit(1) }
            let ns = tv.string as NSString
            let capturer = Capturer()
            var base = Capture()
            base.appName = "Aside"

            // Pointer: the middle of "MVCC", no selection.
            let r = ns.range(of: "MVCC")
            let rect = tv.firstRect(forCharacterRange: NSRange(location: r.location + 1, length: 1), actualRange: nil)
            let p = CGPoint(x: rect.midX, y: rect.midY)
            let byPointer = capturer.ownCapture(base, at: p)
            print("pointer →", byPointer?.term ?? "nil", "| source", byPointer?.source.rawValue ?? "-", "| window", byPointer?.windowTitle ?? "-")

            // Selection: "write-ahead log", through the real capture() entry point (frontmost app is us).
            w.makeFirstResponder(tv)
            tv.setSelectedRange(ns.range(of: "write-ahead log"))
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            print("frontmost is Aside:", front)
            // Only go through capture() when we really are in front: otherwise it would read (and ⌘C) another app.
            let bySel = front ? await capturer.capture() : capturer.ownCapture(base, at: p)
            print("selection →", bySel?.term ?? "nil", "| context has term:", bySel.map { $0.markedContext.contains("⟦write-ahead log⟧") } ?? false,
                  "| ms", Int(bySel?.captureMs ?? -1))
            exit(0)
        }
    }

    static func shoot<V: View>(_ view: V, size: CGSize, to path: String, look: String) async {
        let screen = NSScreen.screens.first?.frame ?? .zero
        let w = NSWindow(contentRect: NSRect(x: 80, y: screen.height - size.height - 100, width: size.width, height: size.height),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        w.contentView = NSHostingView(rootView: view)
        w.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(800))
        shoot(window: w.windowNumber, to: path)
        w.orderOut(nil)
    }

    /// Settings, onboarding and About, each in a real window.
    static func windowShots(into dir: String, looks: [String]) async {
        let env = ProcessInfo.processInfo.environment
        if env["SETTINGS"] != nil {
            for look in looks {
                for pane in SettingsPane.allCases {
                    Settings.shared.pane = pane
                    await shoot(SettingsView(), size: SettingsView.size, to: "\(dir)/settings-\(pane.rawValue)-\(look).png", look: look)
                }
                await shoot(AboutView(), size: CGSize(width: 320, height: 330), to: "\(dir)/about-\(look).png", look: look)
            }
            Settings.shared.pane = .general
        }
        // ONBOARD=1 for every step, or a list like ONBOARD=accessibility,tryIt.
        if let o = env["ONBOARD"] {
            let steps = Onboarding.Step.allCases.filter { o == "1" || o.split(separator: ",").contains(Substring(String(describing: $0))) }
            let saved = UserDefaults.standard.object(forKey: "onboardingStep")
            for look in looks {
                for step in steps {
                    let model = Onboarding(start: step)
                    model.polls = false
                    if step == .tryIt { model.triedIt = env["TRIED"] != nil }
                    if env["NOAX"] != nil { model.axOK = false; model.screenOK = false }
                    await shoot(OnboardingView(model: model), size: OnboardingView.size,
                                to: "\(dir)/onboard-\(step.rawValue)-\(String(describing: step))-\(look).png", look: look)
                    model.stopPolling()
                }
            }
            // Shots mustn't move a real setup along.
            if let saved { UserDefaults.standard.set(saved, forKey: "onboardingStep") }
            else { UserDefaults.standard.removeObject(forKey: "onboardingStep") }
        }
    }
}

extension Fixtures {
    static let futuresCapture = Capture(
        term: "Futures and Promises",
        context: "3. Futures and Promises\nThe <future> and <promise> headers provide a way to pass a value from one thread to another. This method is useful when tasks are independent.",
        termRange: NSRange(location: 3, length: 20),
        appName: "Google Chrome", bundleID: "com.google.Chrome", windowTitle: "Concurrency in C++", source: .selection)

    static func longKind() -> LookupSession {
        LookupSession.fixture(futuresCapture, [(nil, """
TERM: Futures and Promises
EXPANDS:
KIND: c++ concurrency primitives
GIST: A `promise` is where one thread ==writes a value==; the paired `future` is where another thread reads it once it's ready.
- Unlike a condition variable, the handoff is **one-shot**: a promise can be set only once, and `get()` on the future blocks until then.
- Typical use: a worker thread calls `set_value()`, the main thread calls `get()`, with no mutex or predicate loop needed.
NEXT:
? How does this differ from `std::async`?
? What happens if the promise is never set?
""")])
    }

    static func longTitle() -> LookupSession {
        var c = flushCapture
        c.term = "MVCC"
        c.appName = "Microsoft Visual Studio Code Insiders"
        c.bundleID = "com.microsoft.VSCodeInsiders"
        c.context = "Postgres uses MVCC with serializable snapshot isolation, so readers never block writers."
        c.termRange = NSRange(location: 14, length: 4)
        return LookupSession.fixture(c, [(nil, """
TERM: Multi-Version Concurrency Control with Serializable Snapshot Isolation
EXPANDS: Multi-Version Concurrency Control, as implemented by PostgreSQL's Serializable Snapshot Isolation
KIND: database concurrency strategy
GIST: Each transaction reads ==its own snapshot of the data==, so readers never wait for writers and vice versa.
- Old row versions stay until `VACUUM` removes them; a long transaction keeps them alive.
NEXT:
? What does VACUUM actually clean up?
? How is SSI different from plain snapshot isolation?
""")])
    }

    static func passage() -> LookupSession {
        let text = "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife. However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered the rightful property of some one or other of their daughters."
        let c = Capture(term: text, context: text, termRange: NSRange(location: 0, length: (text as NSString).length),
                        appName: "Books", bundleID: "com.apple.iBooksX", windowTitle: "Pride and Prejudice", source: .selection)
        return LookupSession.fixture(c, [(nil, """
TERM: The novel's opening irony
EXPANDS:
KIND: ironic opening
GIST: Austen states the reverse of the truth: it's the ==families who want the rich man==, not the man who wants a wife.
- "Universally acknowledged" is mock-solemn; the narrator is laughing at the neighbourhood's matchmaking.
- *Property* is the sly word: he becomes something the daughters' families feel they own.
NEXT:
? Who is the "single man" here?
? Is this sentence meant seriously?
""")])
    }

    static func markdown() -> LookupSession {
        var c = flushCapture
        c.term = "scoped threads"
        c.appName = "Safari"
        c.bundleID = "com.apple.Safari"
        return LookupSession.fixture(c, [(nil, """
TERM: `std::thread::scope`
EXPANDS:
KIND: rust api
GIST: Lets threads borrow local data, because the scope ==waits for every thread **spawned through its own** `Scope` handle== before returning.
## Why it matters
1. Borrowing works: threads can read `&data` without `Arc`, since nothing outlives the scope.
2. Joining is automatic:
   - the scope joins each thread *before* returning;
   - a panic inside one is ~~swallowed~~ re-raised when the scope ends.
- See [the Rust docs](https://doc.rust-lang.org/std/thread/fn.scope.html) or https://rust-lang.org/learn.
| Spawned with | Joined by scope? |
|---|---|
| `s.spawn` | **yes** |
| `std::thread::spawn` | no, it ==keeps running== |
NEXT:
? How is this different from crossbeam's scope?
? Can a scoped thread return a value?
""")])
    }

    static let scopeRaw = """
GIST: No: a scope waits only for threads ==spawned through its own `Scope` handle==, not for threads started with `std::thread::spawn` inside it.
- `s.spawn(...)` registers the thread with the scope, so the scope joins it before returning.
- A plain `std::thread::spawn(...)` inside the scope is untracked; it keeps running after the scope exits.
```rust
std::thread::scope(|s| {
    s.spawn(|| {});                  // scope waits for this one before it returns
    std::thread::spawn(|| {});       // scope does NOT wait: this thread is detached and may outlive it
});
```
NEXT:
? How do I join a spawn'd thread inside a scope?
? What if a scoped thread panics? Does the scope still wait?
"""

    static func wideCode() -> LookupSession {
        LookupSession.fixture(flushCapture, [(nil, flushRaw), ("Does a scope wait for threads spawned inside it?", scopeRaw)])
    }

    static func longSuggestions() -> LookupSession {
        LookupSession.fixture(flushCapture, [(nil, flushRaw), ("If I call flush on a buffered writer and then the process is killed by the OOM killer before fsync runs, which of my writes are guaranteed to be on disk?", """
GIST: Everything you flushed is ==safe from the process dying==, because it already sits in the kernel's page cache; none of it is safe from a power cut.
- The OOM killer ends the process, not the kernel, so the page cache still writes it back.
NEXT:
? What exactly does the kernel do with dirty pages in its page cache, and how long can they sit there before being written back to disk?
? Does `O_DIRECT` skip the page cache **entirely**, and when is that worth it?
""")])
    }

    static func streaming() -> LookupSession {
        LookupSession.fixture(flushCapture, [(nil, """
TERM: flush
EXPANDS:
KIND: I/O operation
GIST: Hands buffered writes to the OS, but does ==not guarantee they reach **disk
""")], streamingLast: true)
    }

    static func followUpBase() -> LookupSession {
        LookupSession.fixture(flushCapture, [(nil, flushRaw), ("why fsync the directory too?", """
GIST: Creating or renaming a file changes the ==directory entry==, which lives in its own block, so fsyncing the file alone can still lose the name.
- `fsync(file_fd)` makes the *contents* durable; the entry pointing at it needs its own `fsync(dir_fd)`.
- The atomic-replace pattern: write a temp file, `fsync` it, `rename` over the target, then `fsync` the directory.
- On ext4 with `data=ordered`, a rename after a write is usually safe in practice, but POSIX doesn't promise it.
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
}

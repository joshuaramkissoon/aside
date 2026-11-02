import AppKit
import SwiftUI

let args = CommandLine.arguments

if args.contains("--trigger") {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.jkmr.aside.trigger"), object: nil,
                                                                 userInfo: nil, deliverImmediately: true)
    exit(0)
}

// `TOGETHER_API_KEY=… GEMINI_API_KEY=… Aside --import-key` saves whichever keys are set, for Aside.
if args.contains("--import-key") {
    var saved: [String] = []
    for n in KeyStore.Name.allCases {
        if let key = ProcessInfo.processInfo.environment[n.envVar]?.nonEmpty {
            KeyStore.save(key, as: n)
            saved.append(n.envVar)
        }
    }
    print(saved.isEmpty ? "Set TOGETHER_API_KEY and/or GEMINI_API_KEY to import them." : "Saved \(saved.joined(separator: ", ")).")
    exit(saved.isEmpty ? 1 : 0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    if let i = args.firstIndex(of: "--probe") {
        let delay = (i + 1 < args.count ? Double(args[i + 1]) : nil) ?? 3
        DevTools.probe(after: delay)
        app.run()
    } else if let i = args.firstIndex(of: "--ask"), i + 1 < args.count {
        DevTools.ask(term: args[i + 1], context: i + 2 < args.count ? args[i + 2] : "")
        app.run()
    } else if let i = args.firstIndex(of: "--icon") {
        DevTools.icon(to: i + 1 < args.count ? args[i + 1] : "icon.png")
    } else if let i = args.firstIndex(of: "--shots") {
        let dir = i + 1 < args.count ? args[i + 1] : "shots"
        DevTools.shots(into: dir)
        app.run()
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

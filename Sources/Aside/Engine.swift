import Foundation
import Security

enum EngineError: LocalizedError {
    case noKey
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "Add your Together API key in Settings."
        case .http(let code, let body):
            if code == 401 { return "Together rejected the API key. Check it in Settings." }
            if code == 429 { return "Together is rate limiting. Try again in a moment." }
            return "Together returned \(code). \(body.prefix(140))"
        }
    }
}

/// Streams chat completions from Together over one long-lived HTTP/2 connection.
final class Engine: @unchecked Sendable {
    static let shared = Engine()
    static let defaultModel = "deepseek-ai/DeepSeek-V4.1-Flash"
    private let base = URL(string: "https://api.together.xyz/v1")!
    private let session: URLSession
    private var lastTouch = Date.distantPast
    private let lock = NSLock()

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
    }

    /// Open (or keep open) the TLS connection so the next look-up skips the handshake.
    func prewarm(force: Bool = false) {
        lock.lock()
        let cold = Date().timeIntervalSince(lastTouch) > 20
        if cold || force { lastTouch = Date() }
        lock.unlock()
        guard cold || force else { return }
        var r = URLRequest(url: base.appendingPathComponent("models"))
        r.httpMethod = "HEAD"
        r.setValue("Aside/1.0", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: r).resume()
    }

    func stream(_ messages: [[String: String]], maxTokens: Int = 520) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    guard let key = KeyStore.apiKey else { throw EngineError.noKey }
                    var req = URLRequest(url: base.appendingPathComponent("chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Aside/1.0", forHTTPHeaderField: "User-Agent")
                    let body: [String: Any] = [
                        "model": Prefs.model,
                        "messages": messages,
                        "stream": true,
                        "temperature": 0.3,
                        "max_tokens": maxTokens,
                        // DeepSeek V4.1 Flash thinks by default; off, the first token lands in ~0.3s.
                        "reasoning": ["enabled": false],
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    lock.withLock { lastTouch = Date() }

                    let (bytes, resp) = try await session.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 600 { break } }
                        throw EngineError.http(http.statusCode, text)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String, !content.isEmpty else { continue }
                        cont.yield(content)
                    }
                    lock.withLock { lastTouch = Date() }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

/// The API key lives in a file only your user can read (like an .env), not the Keychain:
/// the login keychain ties items to one exact build, so every update would ask for your password.
enum KeyStore {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aside", isDirectory: true)
        return dir.appendingPathComponent("together-api-key")
    }
    private static var cached: String?

    static var apiKey: String? {
        if let cached { return cached }
        if let env = ProcessInfo.processInfo.environment["TOGETHER_API_KEY"]?.nonEmpty { cached = env; return env }
        guard let s = try? String(contentsOf: url, encoding: .utf8).nonEmpty else { return nil }
        cached = s
        return s
    }

    static func save(_ key: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        fm.createFile(atPath: url.path, contents: Data(key.trimmed.utf8), attributes: [.posixPermissions: 0o600])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        cached = key.trimmed.nonEmpty
    }
}

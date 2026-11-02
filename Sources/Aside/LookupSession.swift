import Foundation
import SwiftUI

/// One look-up and its follow-ups.
@MainActor
final class LookupSession: ObservableObject, Identifiable {
    struct Turn: Identifiable, Equatable {
        /// `searching` carries the web query while Aside looks up a term the model didn't know.
        enum State: Equatable { case waiting, searching(String), streaming, done, failed(String) }
        let id = UUID()
        var question: String?
        var raw = ""
        var answer = Answer()
        var state: State = .waiting
        var firstTokenMs: Double?
        /// Web pages the answer was grounded in (empty when the model answered from its own knowledge).
        var sources: [WebSource] = []

        var isBusy: Bool {
            switch state {
            case .waiting, .searching, .streaming: return true
            default: return false
            }
        }
    }

    struct WebSource: Equatable, Hashable, Identifiable {
        let title: String
        let url: URL
        /// Set when the URL is a redirect (Gemini's grounding links), so the label still names the real site.
        var siteName: String? = nil
        var id: URL { url }
        /// "www.theverge.com" → "theverge.com", for a compact label.
        var site: String {
            let h = siteName ?? url.host() ?? url.absoluteString
            // Drop "www.", "m." and language subdomains like "en.": en.wikipedia.org → wikipedia.org.
            var parts = h.split(separator: ".").map(String.init)
            if parts.count > 2, let first = parts.first, first == "www" || first == "m" || first.count == 2 { parts.removeFirst() }
            return parts.joined(separator: ".")
        }
    }

    let id = UUID()
    let capture: Capture
    @Published private(set) var turns: [Turn] = []
    private var history: [[String: String]] = []
    private var task: Task<Void, Never>?

    /// Answers already given, so pressing the shortcut again on the same text is instant.
    private static var cache: [String: Cached] = [:]

    init(capture: Capture) {
        self.capture = capture
    }

    var title: String { turns.first?.answer.term ?? capture.term }
    var isBusy: Bool { turns.last?.isBusy ?? false }
    var suggestions: [String] {
        guard let last = turns.last, last.state == .done else { return [] }
        return last.answer.next
    }

    func start() {
        history = [["role": "system", "content": Prompt.system],
                   ["role": "user", "content": Prompt.lookupMessage(capture)]]
        if let c = Self.cache[capture.cacheKey] {
            var t = Turn()
            t.raw = c.raw
            t.answer = Answer.parse(c.raw, streaming: false)
            t.state = .done
            t.firstTokenMs = 0
            t.sources = c.sources
            turns = [t]
            history[1]["content"] = c.request
            history.append(["role": "assistant", "content": c.raw])
            return
        }
        turns = [Turn()]
        run(index: 0)
    }

    func ask(_ question: String) {
        let q = question.trimmed
        guard !q.isEmpty, !isBusy else { return }
        var t = Turn()
        t.question = q
        turns.append(t)
        history.append(["role": "user", "content": Prompt.followUpMessage(q)])
        run(index: turns.count - 1)
    }

    func retry() {
        guard let last = turns.indices.last, case .failed = turns[last].state else { return }
        turns[last].raw = ""
        turns[last].answer = Answer()
        turns[last].state = .waiting
        run(index: last)
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private struct Cached { let raw: String; let sources: [WebSource]; let request: String }
    private enum Outcome { case answered, search(String) }

    /// Ask the model. If it doesn't know the term it replies `SEARCH: query`; then search the web
    /// and ask again with the results, so the answer is grounded and shows its sources.
    private func run(index: Int) {
        task?.cancel()
        let started = CFAbsoluteTimeGetCurrent()
        let isFirst = index == 0
        let key = capture.cacheKey
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.stream(into: index, allowSearch: true, started: started)
                if case .search(let query) = outcome {
                    self.turns[index].state = .searching(query)
                    self.turns[index].raw = ""
                    let results = await WebSearch.run(query, term: index == 0 ? self.capture.term : "")
                    guard !Task.isCancelled else { return }
                    let request = self.history.last?["content"] ?? ""
                    self.history[self.history.count - 1]["content"] = results.isEmpty
                        ? request + "\n\n(A web search for \"\(query)\" found nothing. Give your best reading from the surrounding text, say plainly that you couldn't confirm it, and don't reply with SEARCH.)"
                        : Prompt.grounded(request, query: query, results: results)
                    self.turns[index].sources = results.sources
                    _ = try await self.stream(into: index, allowSearch: false, started: nil)
                }
                guard !Task.isCancelled else { return }
                let raw = self.turns[index].raw
                self.turns[index].answer = Answer.parse(raw, streaming: false)
                self.turns[index].state = .done
                if isFirst && !raw.isEmpty {
                    Self.cache[key] = Cached(raw: raw, sources: self.turns[index].sources, request: self.history.last?["content"] ?? "")
                }
                self.history.append(["role": "assistant", "content": raw])
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.turns[index].state = .failed(message)
            }
        }
    }

    /// Stream one reply into a turn. A reply that starts `SEARCH:` is held back and returned as a search request.
    private func stream(into index: Int, allowSearch: Bool, started: CFAbsoluteTime?) async throws -> Outcome {
        var raw = ""
        var decided = false
        func searchQuery(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.uppercased().hasPrefix("SEARCH:") else { return nil }
            let line = t.dropFirst("SEARCH:".count).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            return line.trimmed
        }
        for try await chunk in Engine.shared.stream(history) {
            if Task.isCancelled { return .answered }
            raw += chunk
            if !decided {
                let head = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if head.hasPrefix("SEARCH:") {
                    // Wait for the whole query line, then stop the stream: the model has nothing else to say.
                    if allowSearch, raw.trimmingCharacters(in: .whitespaces).dropFirst().contains("\n"),
                       let q = searchQuery(raw), !q.isEmpty { return .search(q) }
                    continue
                }
                if head.isEmpty || "SEARCH:".hasPrefix(head) { continue }
                decided = true
            }
            if let started, turns[index].firstTokenMs == nil {
                turns[index].firstTokenMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
            }
            turns[index].raw = raw
            turns[index].answer = Answer.parse(raw, streaming: true)
            turns[index].state = .streaming
        }
        if allowSearch, let q = searchQuery(raw), !q.isEmpty { return .search(q) }
        if searchQuery(raw) != nil {
            // Asked to search again after searching: drop that line rather than show it.
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", maxSplits: 1).dropFirst().joined()
            if raw.trimmed.isEmpty { raw = "GIST: Couldn't find what this refers to, even with a web search." }
        }
        turns[index].raw = raw
        return .answered
    }

    /// For snapshots and previews: a finished session from canned text.
    static func fixture(_ capture: Capture, _ raws: [(String?, String)], streamingLast: Bool = false) -> LookupSession {
        let s = LookupSession(capture: capture)
        s.turns = raws.enumerated().map { i, pair in
            var t = Turn()
            t.question = pair.0
            t.raw = pair.1
            let streaming = streamingLast && i == raws.count - 1
            t.answer = Answer.parse(pair.1, streaming: streaming)
            t.state = pair.1.isEmpty ? .waiting : (streaming ? .streaming : .done)
            t.firstTokenMs = 342
            return t
        }
        return s
    }

    static func searchingFixture(_ capture: Capture, query: String) -> LookupSession {
        let s = LookupSession(capture: capture)
        var t = Turn()
        t.state = .searching(query)
        s.turns = [t]
        return s
    }

    /// For snapshots: add a follow-up as if it had just been asked, part-way through streaming.
    func appendFixtureTurn(question: String, raw: String, streaming: Bool) {
        var t = Turn()
        t.question = question
        t.raw = raw
        t.answer = Answer.parse(raw, streaming: streaming)
        t.state = streaming ? .streaming : .done
        turns.append(t)
    }

    /// Attach web sources to the first turn of a fixture.
    func withSources(_ sources: [WebSource]) -> LookupSession {
        if !turns.isEmpty { turns[0].sources = sources }
        return self
    }

    static func failedFixture(_ capture: Capture, _ message: String) -> LookupSession {
        let s = LookupSession(capture: capture)
        var t = Turn()
        t.state = .failed(message)
        s.turns = [t]
        return s
    }
}

import Foundation
import SwiftUI

/// One look-up and its follow-ups.
@MainActor
final class LookupSession: ObservableObject, Identifiable {
    struct Turn: Identifiable, Equatable {
        enum State: Equatable { case waiting, streaming, done, failed(String) }
        let id = UUID()
        var question: String?
        var raw = ""
        var answer = Answer()
        var state: State = .waiting
        var firstTokenMs: Double?
    }

    let id = UUID()
    let capture: Capture
    @Published private(set) var turns: [Turn] = []
    private var history: [[String: String]] = []
    private var task: Task<Void, Never>?

    /// Answers already given, so pressing the shortcut again on the same text is instant.
    private static var cache: [String: String] = [:]

    init(capture: Capture) {
        self.capture = capture
    }

    var title: String { turns.first?.answer.term ?? capture.term }
    var isBusy: Bool { turns.last.map { $0.state == .waiting || $0.state == .streaming } ?? false }
    var suggestions: [String] {
        guard let last = turns.last, last.state == .done else { return [] }
        return last.answer.next
    }

    func start() {
        history = [["role": "system", "content": Prompt.system],
                   ["role": "user", "content": Prompt.lookupMessage(capture)]]
        if let raw = Self.cache[capture.cacheKey] {
            var t = Turn()
            t.raw = raw
            t.answer = Answer.parse(raw, streaming: false)
            t.state = .done
            t.firstTokenMs = 0
            turns = [t]
            history.append(["role": "assistant", "content": raw])
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

    private func run(index: Int) {
        task?.cancel()
        let messages = history
        let started = CFAbsoluteTimeGetCurrent()
        let isFirst = index == 0
        let key = capture.cacheKey
        task = Task { [weak self] in
            do {
                for try await chunk in Engine.shared.stream(messages) {
                    guard let self, !Task.isCancelled else { return }
                    if self.turns[index].firstTokenMs == nil {
                        self.turns[index].firstTokenMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
                    }
                    self.turns[index].raw += chunk
                    self.turns[index].answer = Answer.parse(self.turns[index].raw, streaming: true)
                    self.turns[index].state = .streaming
                }
                guard let self, !Task.isCancelled else { return }
                let raw = self.turns[index].raw
                self.turns[index].answer = Answer.parse(raw, streaming: false)
                self.turns[index].state = .done
                self.history.append(["role": "assistant", "content": raw])
                if isFirst && !raw.isEmpty { Self.cache[key] = raw }
            } catch {
                guard let self, !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.turns[index].state = .failed(message)
            }
        }
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

    static func failedFixture(_ capture: Capture, _ message: String) -> LookupSession {
        let s = LookupSession(capture: capture)
        var t = Turn()
        t.state = .failed(message)
        s.turns = [t]
        return s
    }
}

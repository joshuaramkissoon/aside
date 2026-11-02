import Foundation

/// What a web search found: an optional summary (Gemini) and the pages behind it, each with the relevant text.
struct SearchResults {
    struct Hit {
        let source: LookupSession.WebSource
        var snippet: String
    }
    var summary: String = ""
    var hits: [Hit] = []

    var isEmpty: Bool { summary.trimmed.isEmpty && hits.allSatisfy { $0.snippet.trimmed.isEmpty } }
    var sources: [LookupSession.WebSource] {
        var seen = Set<URL>()
        return hits.map(\.source).filter { seen.insert($0.url).inserted }
    }
}

/// Looks up terms the model doesn't know. Wikipedia needs no key and is fast; with a Gemini key,
/// Google Search grounding also covers news and anything Wikipedia hasn't caught up with.
enum WebSearch {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()
    private static let userAgent = "Aside/1.0 (https://github.com/joshuaramkissoon/aside)"

    /// Search for `query`; if that finds nothing, fall back to the bare `term` the reader pointed at.
    static func run(_ query: String, term: String) async -> SearchResults {
        let first = await run(query)
        let bare = term.trimmed
        guard first.isEmpty, !bare.isEmpty, bare.lowercased() != query.lowercased(), bare.count < 80 else { return first }
        return await run(bare)
    }

    static func run(_ query: String) async -> SearchResults {
        let wiki = await wikipedia(query)
        // Wikipedia found the term itself: good enough, and fast.
        if wiki.hits.contains(where: { mentions($0.snippet, query) }) || KeyStore.get(.gemini) == nil {
            return wiki
        }
        var g = await gemini(query)
        // Keep any Wikipedia text too: more to ground on, and the model ignores what doesn't fit.
        g.hits += wiki.hits.filter { mentions($0.snippet, query) }
        return g.isEmpty ? wiki : g
    }

    // MARK: Wikipedia

    static func wikipedia(_ query: String) async -> SearchResults {
        var c = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        c.queryItems = [.init(name: "action", value: "query"), .init(name: "list", value: "search"),
                        .init(name: "srsearch", value: query), .init(name: "srlimit", value: "5"),
                        .init(name: "srprop", value: "snippet"), .init(name: "format", value: "json")]
        guard let url = c.url, let obj = await json(url),
              let results = (obj["query"] as? [String: Any])?["search"] as? [[String: Any]] else { return SearchResults() }
        var hits: [SearchResults.Hit] = results.compactMap { r in
            guard let title = r["title"] as? String, let page = pageURL(title) else { return nil }
            return .init(source: .init(title: title, url: page), snippet: clean(r["snippet"] as? String ?? ""))
        }
        // The best two pages that mention the term: pull the sentences around it, for real context.
        let key = distinctiveWord(query)
        let detailed = hits.indices.filter { mentions(hits[$0].snippet, key) }.prefix(2)
        await withTaskGroup(of: (Int, String).self) { group in
            for i in detailed {
                let title = hits[i].source.title
                group.addTask { (i, await sentences(in: title, about: key)) }
            }
            for await (i, text) in group where !text.isEmpty { hits[i].snippet = text }
        }
        // Pages that never mention the term are noise (a glasswing butterfly is not Project Glasswing).
        let relevant = hits.filter { mentions($0.snippet, key) }
        return SearchResults(hits: Array((relevant.isEmpty ? hits : relevant).prefix(4)))
    }

    private static func sentences(in title: String, about word: String) async -> String {
        var c = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        c.queryItems = [.init(name: "action", value: "query"), .init(name: "prop", value: "extracts"),
                        .init(name: "explaintext", value: "1"), .init(name: "titles", value: title),
                        .init(name: "format", value: "json")]
        guard let url = c.url, let obj = await json(url),
              let pages = (obj["query"] as? [String: Any])?["pages"] as? [String: Any],
              let page = pages.values.first as? [String: Any],
              let text = page["extract"] as? String else { return "" }
        let all = text.components(separatedBy: CharacterSet(charactersIn: "\n"))
            .flatMap { $0.components(separatedBy: ". ") }
            .map { $0.trimmed }
        let hits = all.filter { mentions($0, word) }.prefix(4)
        return String(hits.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ").prefix(700))
    }

    // MARK: Gemini with Google Search grounding

    static func gemini(_ query: String) async -> SearchResults {
        guard let key = KeyStore.get(.gemini),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent") else {
            return SearchResults()
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let prompt = "Search the web for \"\(query)\". In 3 to 5 plain factual sentences, say what it is, who is behind it, and when it happened or was announced. Use exact dates and names. No preamble."
        let body: [String: Any] = ["contents": [["role": "user", "parts": [["text": prompt]]]],
                                   "tools": [["google_search": [String: Any]()]]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cand = (obj["candidates"] as? [[String: Any]])?.first else { return SearchResults() }
        let parts = ((cand["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        let chunks = ((cand["groundingMetadata"] as? [String: Any])?["groundingChunks"] as? [[String: Any]]) ?? []
        let hits: [SearchResults.Hit] = chunks.prefix(4).compactMap { ch in
            guard let web = ch["web"] as? [String: Any], let uri = web["uri"] as? String, let u = URL(string: uri) else { return nil }
            // Grounding links are redirects; their title is the site's domain.
            let title = (web["title"] as? String) ?? u.host() ?? uri
            return .init(source: .init(title: title, url: u, siteName: title), snippet: "")
        }
        return SearchResults(summary: String(text.prefix(1400)), hits: hits)
    }

    // MARK: Helpers

    private static func json(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func pageURL(_ title: String) -> URL? {
        let path = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        return URL(string: "https://en.wikipedia.org/wiki/\(path)")
    }

    private static func clean(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&quot;", "\""), ("&#039;", "'"), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s.trimmed
    }

    /// The word that identifies the thing: the longest query word that isn't a common one.
    /// ("Anthropic Glasswing" → "Glasswing" would be wrong if Anthropic were longer, so prefer capitalised rare words.)
    static func distinctiveWord(_ query: String) -> String {
        let common: Set<String> = ["the", "and", "what", "is", "of", "in", "for", "project", "anthropic", "google", "openai",
                                   "apple", "microsoft", "meta", "company", "model", "release", "announced", "news"]
        let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).map(String.init)
        let candidates = words.filter { !common.contains($0.lowercased()) && $0.count > 2 }
        return candidates.max(by: { $0.count < $1.count }) ?? words.last ?? query
    }

    static func mentions(_ text: String, _ query: String) -> Bool {
        text.range(of: distinctiveWord(query), options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

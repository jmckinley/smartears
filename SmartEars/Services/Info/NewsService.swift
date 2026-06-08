import Foundation

// MARK: - Info / News
//
// `NewsService` (the protocol) is declared in Models.swift — NOT redefined
// here. This file provides:
//   * `NewsSpeech` — a spoken phrasing helper for `[NewsHeadline]`.
//   * `RemoteNewsService` — a URLSession-backed skeleton against a generic news
//     API. The API key is read from `AppConfig` / Keychain placeholders ONLY;
//     there are NO secrets in source. The fetch/parse path is a TODO skeleton.
//   * `StubNewsService` — returns realistic sample "breaking news" headlines so
//     the app compiles and runs with no key.

// MARK: - Spoken phrasing helper

/// Pure phrasing for news headlines shared by live + stub services.
public enum NewsSpeech {

    /// Phrases a set of headlines for speech, e.g.
    /// "Here are the top 3 headlines. One, from Reuters: ... Two: ... Three: ..."
    public static func report(for headlines: [NewsHeadline], topic: String? = nil) -> String {
        guard !headlines.isEmpty else {
            if let topic, !topic.isEmpty {
                return "I couldn't find any news about \(topic) right now."
            }
            return "I couldn't find any news right now."
        }

        let intro: String
        if let topic, !topic.isEmpty {
            intro = "Here\(headlines.count == 1 ? "'s" : " are") the top \(headlines.count) " +
                    "\(headlines.count == 1 ? "headline" : "headlines") about \(topic)."
        } else {
            intro = "Here\(headlines.count == 1 ? "'s" : " are") the top \(headlines.count) " +
                    "\(headlines.count == 1 ? "headline" : "headlines")."
        }

        let items = headlines.enumerated().map { index, item -> String in
            let ordinal = spokenOrdinal(index + 1)
            if let source = item.source, !source.isEmpty {
                return "\(ordinal), from \(source): \(item.headline)."
            }
            return "\(ordinal): \(item.headline)."
        }

        return ([intro] + items).joined(separator: " ")
    }

    private static func spokenOrdinal(_ n: Int) -> String {
        switch n {
        case 1: return "One"
        case 2: return "Two"
        case 3: return "Three"
        case 4: return "Four"
        case 5: return "Five"
        default: return "\(n)"
        }
    }
}

// MARK: - Remote (skeleton) implementation

/// URLSession-backed news provider skeleton. Wire to a real news API (e.g.
/// NewsAPI.org / GNews) by completing the request + decode below.
///
/// SECURITY: the API key is injected from resolved config (Info.plist xcconfig
/// placeholder or Keychain) — NEVER hardcode it. If no key resolves, the
/// `ServiceFactory` should pick `StubNewsService` instead.
public final class RemoteNewsService: NewsService {

    private let apiKey: String
    private let session: URLSession
    private let baseURL: URL

    /// - Parameter apiKey: resolved from `AppConfig.newsAPIKey` / Keychain.
    public init(
        apiKey: String,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://example.invalid/v2")!
    ) {
        self.apiKey = apiKey
        self.session = session
        self.baseURL = baseURL
    }

    public func headlines(topic: String?, limit: Int) async throws -> [NewsHeadline] {
        guard !apiKey.isEmpty else {
            throw SmartEarsError.missingCredential("news API key")
        }

        // TODO: Replace the placeholder endpoint + query shape with the chosen
        // provider's contract. Example (NewsAPI-style):
        //   GET {base}/top-headlines?q={topic}&pageSize={limit}&apiKey={KEY}
        let path = (topic?.isEmpty == false) ? "everything" : "top-headlines"
        var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)
        var query = [
            URLQueryItem(name: "pageSize", value: String(max(1, limit))),
            URLQueryItem(name: "apiKey", value: apiKey)
        ]
        if let topic, !topic.isEmpty {
            query.append(URLQueryItem(name: "q", value: topic))
        }
        components?.queryItems = query
        guard let url = components?.url else {
            throw SmartEarsError.other("Failed to build news request URL.")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw SmartEarsError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SmartEarsError.network("News provider returned a non-success status.")
        }

        // TODO: Decode the provider payload into `[NewsHeadline]`. The mapping
        // below is illustrative; adapt field names to the chosen API.
        do {
            let wire = try JSONDecoder().decode(WireResponse.self, from: data)
            return wire.articles.prefix(max(1, limit)).map { article in
                NewsHeadline(
                    headline: article.title,
                    source: article.source?.name,
                    summary: article.description,
                    url: article.url.flatMap(URL.init(string:)),
                    publishedAt: Self.parseDate(article.publishedAt) ?? Date()
                )
            }
        } catch {
            throw SmartEarsError.decoding(error.localizedDescription)
        }
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    /// Illustrative wire shape — adapt to the chosen provider's JSON.
    private struct WireResponse: Decodable {
        let articles: [WireArticle]
    }
    private struct WireArticle: Decodable {
        let title: String
        let description: String?
        let url: String?
        let publishedAt: String?
        let source: WireSource?
    }
    private struct WireSource: Decodable {
        let name: String?
    }
}

// MARK: - Stub implementation

/// Realistic sample headlines so the app runs with no key. Provides generic
/// "breaking news" by default and topic-tailored samples when a topic is given.
public final class StubNewsService: NewsService {

    private let breaking: [NewsHeadline]

    public init(breaking: [NewsHeadline]? = nil) {
        self.breaking = breaking ?? [
            NewsHeadline(
                headline: "Central bank holds interest rates steady amid cooling inflation",
                source: "Reuters",
                summary: "Policymakers signaled a patient stance as recent data showed price growth easing.",
                url: URL(string: "https://example.com/news/rates"),
                publishedAt: Date().addingTimeInterval(-1_800)
            ),
            NewsHeadline(
                headline: "Major tech firms unveil new on-device AI features at developer conference",
                source: "Associated Press",
                summary: "Announcements focused on privacy-preserving, locally-run assistant capabilities.",
                url: URL(string: "https://example.com/news/ai"),
                publishedAt: Date().addingTimeInterval(-3_600)
            ),
            NewsHeadline(
                headline: "Severe weather system moves across the region, prompting travel advisories",
                source: "National Weather Desk",
                summary: "Forecasters urged residents to prepare for heavy rain and gusty winds overnight.",
                url: URL(string: "https://example.com/news/weather"),
                publishedAt: Date().addingTimeInterval(-5_400)
            )
        ]
    }

    public func headlines(topic: String?, limit: Int) async throws -> [NewsHeadline] {
        let count = max(1, min(limit, breaking.count + 1))
        guard let topic, !topic.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Array(breaking.prefix(count))
        }

        // Synthesize believable topic-specific headlines on top of the breaking set.
        let topical = NewsHeadline(
            headline: "Latest developments on \(topic): analysts weigh in on what's next",
            source: "SmartEars Wire",
            summary: "A roundup of recent reporting and expert commentary about \(topic).",
            url: URL(string: "https://example.com/news/topic"),
            publishedAt: Date().addingTimeInterval(-600)
        )
        return Array(([topical] + breaking).prefix(count))
    }
}

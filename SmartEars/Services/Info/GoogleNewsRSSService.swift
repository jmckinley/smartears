import Foundation

// MARK: - GoogleNewsRSSService (free, NO API key)
//
// Pulls breaking headlines from Google News' public RSS feeds — free, no key:
//   top stories : https://news.google.com/rss
//   by topic    : https://news.google.com/rss/search?q={query}
// Parsed with Foundation's XMLParser (no dependencies). Each <item> yields a
// headline, source, link, and publish date.

public struct GoogleNewsRSSService: NewsService {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func headlines(topic: String?, limit: Int) async throws -> [NewsHeadline] {
        let url: URL
        if let topic, !topic.trimmingCharacters(in: .whitespaces).isEmpty {
            var c = URLComponents(string: "https://news.google.com/rss/search")!
            c.queryItems = [
                .init(name: "q", value: topic),
                .init(name: "hl", value: "en-US"), .init(name: "gl", value: "US"), .init(name: "ceid", value: "US:en"),
            ]
            url = c.url!
        } else {
            url = URL(string: "https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en")!
        }

        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw SmartEarsError.network("News service returned an error.")
        }
        let items = RSSParser.parse(data)
        guard !items.isEmpty else { throw SmartEarsError.other("No headlines available right now.") }

        return items.prefix(max(1, limit)).map { item in
            NewsHeadline(
                headline: item.cleanTitle,
                source: item.source,
                summary: nil,
                url: item.link.flatMap(URL.init(string:)),
                publishedAt: item.date ?? Date()
            )
        }
    }
}

// MARK: - Minimal RSS parser

private struct RSSItem {
    var title: String = ""
    var link: String?
    var source: String?
    var date: Date?
    /// Google News titles often end with " - Source"; strip that for clean speech.
    var cleanTitle: String {
        if let source, title.hasSuffix(" - \(source)") {
            return String(title.dropLast(source.count + 3))
        }
        return title
    }
}

private final class RSSParser: NSObject, XMLParserDelegate {
    private var items: [RSSItem] = []
    private var current: RSSItem?
    private var element = ""
    private var text = ""

    static func parse(_ data: Data) -> [(cleanTitle: String, link: String?, source: String?, date: Date?)] {
        let p = RSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.items.map { ($0.cleanTitle, $0.link, $0.source, $0.date) }
    }

    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName qn: String?, attributes: [String: String]) {
        element = el
        text = ""
        if el == "item" { current = RSSItem() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName qn: String?) {
        guard current != nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch el {
        case "title":  current?.title = value
        case "link":   current?.link = value
        case "source": current?.source = value
        case "pubDate": current?.date = Self.rfc822.date(from: value)
        case "item":   if let c = current { items.append(c) }; current = nil
        default: break
        }
    }
}

import Foundation

// MARK: - Info / Stocks
//
// `StockService` (the protocol) is declared in Models.swift — NOT redefined
// here. This file provides:
//   * `StockSpeech` — a spoken phrasing helper for `StockQuote`.
//   * `RemoteStockService` — a URLSession-backed skeleton. The API key is read
//     from `AppConfig` / Keychain placeholders ONLY; there are NO secrets in
//     source. The HTTP/parse path is intentionally a TODO skeleton.
//   * `StubStockService` — returns realistic sample quotes so the app compiles
//     and runs with no key.

// MARK: - Spoken phrasing helper

/// Pure phrasing for stock quotes shared by live + stub services.
public enum StockSpeech {

    /// Phrases a quote for speech, e.g.
    /// "Apple is trading at 192 dollars and 14 cents, up 1.2 percent on the day."
    public static func report(for quote: StockQuote) -> String {
        let name = quote.companyName ?? quote.symbol
        let priceText = money(quote.price, currency: quote.currency)
        let direction = quote.isUp ? "up" : "down"
        let pct = String(format: "%.1f", abs(quote.changePercent))
        return "\(name) is trading at \(priceText), \(direction) \(pct) percent on the day."
    }

    /// Spoken money phrasing: "192 dollars and 14 cents" (USD) or a generic
    /// fallback for other currencies.
    private static func money(_ value: Double, currency: String) -> String {
        guard currency.uppercased() == "USD" else {
            return String(format: "%.2f %@", value, currency.uppercased())
        }
        let whole = Int(value)
        let cents = Int((value - Double(whole)) * 100 + 0.5)
        let dollarWord = whole == 1 ? "dollar" : "dollars"
        if cents == 0 { return "\(whole) \(dollarWord)" }
        let centWord = cents == 1 ? "cent" : "cents"
        return "\(whole) \(dollarWord) and \(cents) \(centWord)"
    }
}

// MARK: - Remote (skeleton) implementation

/// URLSession-backed stock provider skeleton. Wire to a real quote API (e.g.
/// Finnhub / Alpha Vantage / IEX) by completing the request + decode below.
///
/// SECURITY: the API key is injected from resolved config (Info.plist xcconfig
/// placeholder or Keychain) — NEVER hardcode it. If no key resolves, the
/// `ServiceFactory` should pick `StubStockService` instead and this type is not
/// constructed.
public final class RemoteStockService: StockService {

    private let apiKey: String
    private let session: URLSession
    private let baseURL: URL

    /// - Parameter apiKey: resolved from `AppConfig.stocksAPIKey` / Keychain.
    ///   Passing an empty key throws on use (caller should have chosen the stub).
    public init(
        apiKey: String,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://example.invalid/v1")!
    ) {
        self.apiKey = apiKey
        self.session = session
        self.baseURL = baseURL
    }

    public func quote(symbol: String) async throws -> StockQuote {
        guard !apiKey.isEmpty else {
            throw SmartEarsError.missingCredential("stocks API key")
        }
        let cleanSymbol = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !cleanSymbol.isEmpty else {
            throw SmartEarsError.other("No ticker symbol provided.")
        }

        // TODO: Replace the placeholder endpoint + query shape with the chosen
        // provider's contract. Example (Finnhub-style):
        //   GET {base}/quote?symbol={SYM}&token={KEY}
        var components = URLComponents(url: baseURL.appendingPathComponent("quote"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "symbol", value: cleanSymbol),
            URLQueryItem(name: "token", value: apiKey)
        ]
        guard let url = components?.url else {
            throw SmartEarsError.other("Failed to build stocks request URL.")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw SmartEarsError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SmartEarsError.network("Stocks provider returned a non-success status.")
        }

        // TODO: Decode the provider payload into `StockQuote`. The mapping below
        // is illustrative; adapt field names to the chosen API.
        do {
            let wire = try JSONDecoder().decode(WireQuote.self, from: data)
            let change = wire.current - wire.previousClose
            let pct = wire.previousClose == 0 ? 0 : (change / wire.previousClose) * 100
            return StockQuote(
                symbol: cleanSymbol,
                companyName: wire.name,
                price: wire.current,
                changeAbsolute: change,
                changePercent: pct
            )
        } catch {
            throw SmartEarsError.decoding(error.localizedDescription)
        }
    }

    /// Illustrative wire shape — adapt to the chosen provider's JSON.
    private struct WireQuote: Decodable {
        let name: String?
        let current: Double
        let previousClose: Double

        enum CodingKeys: String, CodingKey {
            case name = "n"
            case current = "c"
            case previousClose = "pc"
        }
    }
}

// MARK: - Stub implementation

/// Realistic sample quotes so the app runs with no key. Returns a believable
/// quote for any symbol, with a few well-known names pre-filled.
public final class StubStockService: StockService {

    private let samples: [String: StockQuote]

    public init(samples: [StockQuote]? = nil) {
        let defaults: [StockQuote] = samples ?? [
            StockQuote(symbol: "AAPL", companyName: "Apple", price: 192.14,
                       changeAbsolute: 2.31, changePercent: 1.22),
            StockQuote(symbol: "TSLA", companyName: "Tesla", price: 248.50,
                       changeAbsolute: -5.10, changePercent: -2.01),
            StockQuote(symbol: "MSFT", companyName: "Microsoft", price: 415.26,
                       changeAbsolute: 3.88, changePercent: 0.94),
            StockQuote(symbol: "NVDA", companyName: "NVIDIA", price: 121.40,
                       changeAbsolute: 1.05, changePercent: 0.87)
        ]
        self.samples = Dictionary(uniqueKeysWithValues: defaults.map { ($0.symbol, $0) })
    }

    public func quote(symbol: String) async throws -> StockQuote {
        let key = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !key.isEmpty else { throw SmartEarsError.other("No ticker symbol provided.") }
        if let known = samples[key] { return known }
        // Deterministic, plausible synthetic quote for unknown symbols.
        let basePrice = 50 + Double(abs(key.hashValue) % 450)
        let change = Double((abs(key.hashValue) % 600) - 300) / 100.0
        let pct = basePrice == 0 ? 0 : (change / basePrice) * 100
        return StockQuote(
            symbol: key,
            companyName: nil,
            price: (basePrice * 100).rounded() / 100,
            changeAbsolute: (change * 100).rounded() / 100,
            changePercent: (pct * 100).rounded() / 100
        )
    }
}

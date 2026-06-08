import Foundation

// MARK: - YahooStockService (free, NO API key)
//
// Uses Yahoo Finance's public chart endpoint — free, no key, no signup:
//   https://query1.finance.yahoo.com/v8/finance/chart/{SYMBOL}
// The `meta` block carries the current price, previous close, and currency, from
// which we derive the change. A browser-like User-Agent avoids throttling.
//
// NOTE: this is Yahoo's undocumented public endpoint (the same one countless
// finance tools use). It needs no credentials; if Yahoo ever changes it, swap the
// implementation here — the StockService protocol stays the same.

public struct YahooStockService: StockService {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func quote(symbol: String) async throws -> StockQuote {
        let ticker = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !ticker.isEmpty else { throw SmartEarsError.other("No ticker symbol provided.") }

        var c = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(ticker)")!
        c.queryItems = [.init(name: "range", value: "1d"), .init(name: "interval", value: "1d")]
        var request = URLRequest(url: c.url!)
        // Yahoo throttles default URLSession agents; present a browser UA.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw SmartEarsError.network("Stock service returned an error for \(ticker).")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = root["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let meta = results.first?["meta"] as? [String: Any],
              let price = (meta["regularMarketPrice"] as? Double)
        else { throw SmartEarsError.other("I couldn't find a quote for \(ticker).") }

        let prevClose = (meta["chartPreviousClose"] as? Double)
            ?? (meta["previousClose"] as? Double) ?? price
        let change = price - prevClose
        let changePct = prevClose != 0 ? (change / prevClose) * 100 : 0
        let currency = (meta["currency"] as? String) ?? "USD"
        let name = (meta["longName"] as? String) ?? (meta["shortName"] as? String)

        return StockQuote(
            symbol: (meta["symbol"] as? String) ?? ticker,
            companyName: name,
            price: price,
            currency: currency,
            changeAbsolute: change,
            changePercent: changePct
        )
    }
}

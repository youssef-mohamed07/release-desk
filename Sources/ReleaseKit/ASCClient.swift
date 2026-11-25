import Foundation

/// A thin App Store Connect API client: signs requests, follows pages,
/// retries rate limits and turns JSON:API errors into readable messages.
public actor ASCClient {
    public let key: ASCKey
    private var cached: (token: String, until: Date)?
    private let session: URLSession
    private let base = URL(string: "https://api.appstoreconnect.apple.com")!

    public init(key: ASCKey) {
        self.key = key
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.httpAdditionalHeaders = ["User-Agent": "ReleaseDesk/1.0"]
        session = URLSession(configuration: config)
    }

    private func token() throws -> String {
        if let cached, cached.until > Date() { return cached.token }
        let t = try key.token()
        cached = (t, Date().addingTimeInterval(15 * 60))
        return t
    }

    /// One request. `path` starts with `/v1/…`, or is a full `links.next` URL.
    @discardableResult
    public func send(_ method: String = "GET", _ path: String, query: [String: String] = [:],
                     body: JSONValue? = nil) async throws -> JSONValue {
        var url: URL
        if path.hasPrefix("https://") {
            url = URL(string: path)!
        } else {
            var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty {
                comps.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
            }
            url = comps.url!
        }
        var attempt = 0
        while true {
            attempt += 1
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONEncoder().encode(body)
            }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch is CancellationError {
                throw ReleaseError.cancelled
            } catch {
                if attempt < 3 { try await Task.sleep(for: .seconds(2 * attempt)); continue }
                throw ReleaseError.network(error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.isEmpty ? JSONValue.null : ((try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null)
            if (200..<300).contains(status) { return json }
            if (status == 429 || status >= 500), attempt < 4 {
                try await Task.sleep(for: .seconds(3 * attempt))
                continue
            }
            if status == 401 { cached = nil }
            let messages = json["errors"].array.map { e in
                [e["code"].string, e["detail"].string ?? e["title"].string].compactMap { $0 }.joined(separator: " ")
            }
            throw ReleaseError.api(status: status, path: url.path, messages: messages.isEmpty ? [HTTPURLResponse.localizedString(forStatusCode: status)] : messages)
        }
    }

    /// Every page of a collection: the resources and everything they included.
    public func all(_ path: String, query: [String: String] = [:], maxPages: Int = 20) async throws -> (data: [JSONValue], included: [JSONValue]) {
        var data: [JSONValue] = []
        var included: [JSONValue] = []
        var page = try await send("GET", path, query: query)
        for _ in 0..<maxPages {
            data += page["data"].array
            included += page["included"].array
            guard let next = page["links"]["next"].string else { break }
            page = try await send("GET", next)
        }
        return (data, included)
    }
}

/// Looks up `included` resources by type and id.
struct Included {
    private var map: [String: JSONValue] = [:]
    init(_ items: [JSONValue]) {
        for i in items {
            if let t = i["type"].string, let id = i["id"].string { map["\(t)/\(id)"] = i }
        }
    }
    func resource(for relationship: JSONValue) -> JSONValue? {
        let d = relationship["data"]
        guard let t = d["type"].string, let id = d["id"].string else { return nil }
        return map["\(t)/\(id)"]
    }
}

import Foundation

/// An app in Partner Center, as Release Desk shows it.
public struct MSApp: Sendable, Hashable {
    public let id: String
    public let name: String
    public let packageIdentityName: String
    public let firstPublished: Date?
    public let lastSubmissionID: String?
    public let pendingSubmissionID: String?
    /// Filled when the app page reads its submissions.
    public var lastStatus: String?
    public var pendingStatus: String?
    public var listingLanguages: [String] = []
    public var releaseNotes: [String: String] = [:]
}

/// Partner Center's Microsoft Store submission API (MSIX apps), with a
/// Microsoft Entra app added to Partner Center with the Manager role.
public actor MicrosoftStoreClient {
    public static let base = "https://manage.devcenter.microsoft.com/v1.0/my/"
    public let tenantID: String
    public let clientID: String
    private let secret: String
    private var cached: (token: String, until: Date)?
    private let session: URLSession

    public init(tenantID: String, clientID: String, secret: String) {
        self.tenantID = tenantID
        self.clientID = clientID
        self.secret = secret
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        session = URLSession(configuration: config)
    }

    private func token() async throws -> String {
        if let cached, cached.until > Date() { return cached.token }
        let url = "https://login.microsoftonline.com/\(tenantID)/oauth2/token"
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        req.httpBody = Data("grant_type=client_credentials&client_id=\(enc(clientID))&client_secret=\(enc(secret))&resource=\(enc("https://manage.devcenter.microsoft.com"))".utf8)
        let (data, response) = try await session.data(for: req)
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard (response as? HTTPURLResponse)?.statusCode == 200, let t = json["access_token"].string else {
            let message = json["error_description"].string?.split(separator: "\r\n").first.map(String.init) ?? json["error"].string ?? "Microsoft Entra refused the client"
            throw ReleaseError.api(status: (response as? HTTPURLResponse)?.statusCode ?? 0, path: url, messages: [message])
        }
        cached = (t, Date().addingTimeInterval(TimeInterval((json["expires_in"].int ?? 3600) - 120)))
        return t
    }

    @discardableResult
    public func send(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        let url = path.hasPrefix("https://") ? path : Self.base + path
        var attempt = 0
        while true {
            attempt += 1
            var req = URLRequest(url: URL(string: url)!)
            req.httpMethod = method
            req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONEncoder().encode(body)
            } else if method == "POST" {
                req.setValue("0", forHTTPHeaderField: "Content-Length")
            }
            let data: Data, response: URLResponse
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
            if status == 429 || status >= 500, attempt < 4 { try await Task.sleep(for: .seconds(4 * attempt)); continue }
            if status == 401 { cached = nil }
            let message = json["message"].string ?? json["error"]["message"].string ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw ReleaseError.api(status: status, path: url, messages: [message])
        }
    }

    static func app(_ j: JSONValue) -> MSApp {
        MSApp(id: j["id"].string ?? "", name: j["primaryName"].string ?? j["id"].string ?? "?",
              packageIdentityName: j["packageIdentityName"].string ?? "", firstPublished: j["firstPublishedDate"].date,
              lastSubmissionID: j["lastPublishedApplicationSubmission"]["id"].string,
              pendingSubmissionID: j["pendingApplicationSubmission"]["id"].string)
    }

    public func applications() async throws -> [MSApp] {
        var out: [MSApp] = []
        var next: String? = "applications?top=100&skip=0"
        var pages = 0
        while let path = next, pages < 20 {
            let r = try await send("GET", path)
            out += r["value"].array.map(Self.app)
            next = r["@nextLink"].string
            pages += 1
        }
        return out
    }

    public func application(_ id: String) async throws -> MSApp {
        Self.app(try await send("GET", "applications/\(id)"))
    }

    public func submission(appID: String, id: String) async throws -> JSONValue {
        try await send("GET", "applications/\(appID)/submissions/\(id)")
    }

    public func status(appID: String, submissionID: String) async throws -> (status: String, errors: [String]) {
        let r = try await send("GET", "applications/\(appID)/submissions/\(submissionID)/status")
        let errors = r["statusDetails"]["errors"].array.map { "\($0["code"].string ?? "") \($0["details"].string ?? "")".trimmingCharacters(in: .whitespaces) }
        return (r["status"].string ?? "?", errors)
    }

    /// The app with its submissions read: status, listing languages and release notes.
    public func details(_ id: String) async throws -> MSApp {
        var app = try await application(id)
        if let sub = app.pendingSubmissionID {
            app.pendingStatus = try? await status(appID: id, submissionID: sub).status
        }
        if let sub = app.pendingSubmissionID ?? app.lastSubmissionID, let s = try? await submission(appID: id, id: sub) {
            if app.pendingSubmissionID == nil { app.lastStatus = s["status"].string }
            for (lang, listing) in s["listings"].dictionary {
                app.listingLanguages.append(lang)
                if let notes = listing["baseListing"]["releaseNotes"].string, !notes.isEmpty { app.releaseNotes[lang] = notes }
            }
            app.listingLanguages.sort()
        }
        if app.lastStatus == nil, let sub = app.lastSubmissionID {
            app.lastStatus = try? await status(appID: id, submissionID: sub).status
        }
        return app
    }

    /// Writes release notes into the languages the submission has; returns a line per language.
    public func setReleaseNotes(appID: String, submissionID: String, notes: [String: String]) async throws -> [String] {
        var s = try await submission(appID: appID, id: submissionID)
        let languages = Set(s["listings"].dictionary.keys)
        var lines: [String] = []
        for (lang, text) in notes.sorted(by: { $0.key < $1.key }) {
            let key = lang.lowercased()
            guard languages.contains(key) else { lines.append("\(key): no listing in this language on the Store, skipped"); continue }
            s = s.setting(["listings", key, "baseListing", "releaseNotes"], to: .string(text))
            lines.append("\(key): written")
        }
        if lines.contains(where: { $0.hasSuffix("written") }) {
            try await send("PUT", "applications/\(appID)/submissions/\(submissionID)", body: s)
        }
        return lines
    }

    public func commit(appID: String, submissionID: String) async throws {
        try await send("POST", "applications/\(appID)/submissions/\(submissionID)/commit")
    }
}

import Foundation

/// An app on Huawei AppGallery, as Release Desk shows it.
public struct AGCApp: Sendable, Hashable {
    public let appID: String
    public let package: String
    public var name: String
    /// The version being prepared (draft or in review) and the one on sale.
    public var version: String?
    public var versionOnShelf: String?
    public var releaseState: Int?
    public var reviewNote: String?
    /// What's new per language of the version being prepared.
    public var newFeatures: [String: String]
    public var phasedState: String?

    /// AppGallery's release states, in words.
    public var stateTitle: String {
        guard let releaseState else { return "Unknown" }
        return AGCApp.stateTitles[releaseState] ?? "State \(releaseState)"
    }

    static let stateTitles = [
        0: "Released", 1: "Release rejected", 2: "Removed", 3: "Releasing", 4: "In review", 5: "Update in review",
        6: "Removal requested", 7: "Draft", 8: "Update rejected", 9: "Removal rejected", 10: "Removed by you",
        11: "Release canceled", 12: "In pre-review", 13: "Pre-review failed",
    ]
}

/// How an AppGallery release goes out once it passes review.
public enum AGCRelease: Sendable, Hashable {
    case afterReview
    /// Phased release to a percentage of users, over `days`.
    case phased(percent: Double, days: Int)
}

/// Huawei AppGallery Connect's Publishing API, with an API client (client ID
/// and key) made under Users and permissions → API key → Connect API.
public actor AppGalleryClient {
    public static let base = "https://connect-api.cloud.huawei.com/api"
    public let clientID: String
    private let secret: String
    private var cached: (token: String, until: Date)?
    private let session: URLSession

    public init(clientID: String, secret: String) {
        self.clientID = clientID
        self.secret = secret
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: config)
    }

    /// The Keychain account that holds an API client's key.
    public static func keychainAccount(clientID: String) -> String { "agc:\(clientID)" }

    private func token() async throws -> String {
        if let cached, cached.until > Date() { return cached.token }
        var req = URLRequest(url: URL(string: Self.base + "/oauth2/v1/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(JSONValue.object([
            "grant_type": "client_credentials", "client_id": .string(clientID), "client_secret": .string(secret),
        ]))
        let (data, response) = try await session.data(for: req)
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard (response as? HTTPURLResponse)?.statusCode == 200, let t = json["access_token"].string else {
            throw ReleaseError.api(status: (response as? HTTPURLResponse)?.statusCode ?? 0, path: Self.base + "/oauth2/v1/token",
                                   messages: [json["ret"]["msg"].string ?? "AppGallery Connect refused the client ID and key"])
        }
        cached = (t, Date().addingTimeInterval(TimeInterval((json["expires_in"].int ?? 172_800) - 300)))
        return t
    }

    /// Calls the Publishing API. AppGallery answers 200 with a `ret.code`
    /// that is not 0 when something is wrong, so both are checked.
    @discardableResult
    public func send(_ method: String, _ path: String, query: [String: String] = [:], body: JSONValue? = nil) async throws -> JSONValue {
        var comps = URLComponents(string: Self.base + path)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var attempt = 0
        while true {
            attempt += 1
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.setValue(clientID, forHTTPHeaderField: "client_id")
            req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONEncoder().encode(body)
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
            let code = json["ret"]["code"].int ?? 0
            if (200..<300).contains(status), code == 0 { return json }
            if status >= 500, attempt < 4 { try await Task.sleep(for: .seconds(3 * attempt)); continue }
            if status == 401 { cached = nil }
            let message = json["ret"]["msg"].string ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw ReleaseError.api(status: code != 0 ? code : status, path: Self.base + path, messages: [message])
        }
    }

    /// App IDs and names for package names (50 at a time).
    public func appIDs(packages: [String]) async throws -> [String: (appID: String, name: String)] {
        var out: [String: (appID: String, name: String)] = [:]
        for chunk in stride(from: 0, to: packages.count, by: 50).map({ Array(packages[$0..<min($0 + 50, packages.count)]) }) {
            let r = try await send("GET", "/publish/v2/appid-list", query: ["packageName": chunk.joined(separator: ",")])
            // The list keeps the order of the request.
            for (i, item) in r["appids"].array.enumerated() where i < chunk.count {
                if let id = item["value"].string { out[chunk[i]] = (id, item["key"].string ?? chunk[i]) }
            }
        }
        return out
    }

    /// Every Android app of the team, when the API client may read projects.
    public func allApps() async throws -> [(appID: String, package: String, name: String)] {
        var out: [(appID: String, package: String, name: String)] = []
        var page = 1
        while page < 20 {
            let r = try await send("GET", "/project-service/v1/projects", query: ["fromPage": "\(page)", "pageSize": "100"])
            let projects = r["projectList"].array
            for p in projects {
                for a in p["appList"].array where (a["appType"].int ?? 1) == 1 {
                    if let id = a["appId"].string ?? a["appId"].int.map(String.init), let pkg = a["packageName"].string {
                        out.append((id, pkg, a["appName"].string ?? pkg))
                    }
                }
            }
            if projects.count < 100 { break }
            page += 1
        }
        return out
    }

    public func app(appID: String, package: String) async throws -> AGCApp {
        let r = try await send("GET", "/publish/v2/app-info", query: ["appId": appID, "releaseType": "1"])
        let info = r["appInfo"]
        let languages = r["languages"].array
        let defaultLang = info["defaultLang"].string
        let name = languages.first { $0["lang"].string == defaultLang }?["appName"].string ?? languages.first?["appName"].string ?? package
        var features: [String: String] = [:]
        for l in languages { if let lang = l["lang"].string, let f = l["newFeatures"].string, !f.isEmpty { features[lang] = f } }
        return AGCApp(appID: appID, package: package, name: name, version: info["versionNumber"].string,
                      versionOnShelf: info["onShelfVersionNumber"].string, releaseState: info["releaseState"].int,
                      reviewNote: r["auditInfo"]["auditOpinion"].string, newFeatures: features,
                      phasedState: r["phasedReleaseInfo"]["state"].string)
    }

    /// Uploads an app bundle or APK, attaches it to the version being
    /// prepared and waits until AppGallery has processed it.
    public func upload(appID: String, file: URL, log: @Sendable (String) -> Void) async throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        if file.pathExtension == "aab", size > 150 * 1024 * 1024 {
            throw ReleaseError.precondition("AppGallery takes app bundles up to 150 MB; this one is \(size / 1024 / 1024) MB.")
        }
        let r = try await send("GET", "/publish/v2/upload-url/for-obs", query: [
            "appId": appID, "fileName": file.lastPathComponent, "contentLength": "\(size)", "chineseMainlandFlag": "0",
        ])
        let info = r["urlInfo"]
        guard let url = info["url"].string.flatMap(URL.init(string:)), let objectID = info["objectId"].string else {
            throw ReleaseError.precondition("AppGallery gave no upload address")
        }
        var put = URLRequest(url: url)
        put.httpMethod = info["method"].string ?? "PUT"
        for (k, v) in info["headers"].dictionary { if let v = v.string { put.setValue(v, forHTTPHeaderField: k) } }
        log("Uploading \(file.lastPathComponent) (\(size / 1024 / 1024) MB)")
        let (data, response) = try await session.upload(for: put, fromFile: file)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ReleaseError.api(status: status, path: url.absoluteString, messages: [String(data: data, encoding: .utf8)?.prefix(300).description ?? "Upload failed"])
        }
        let bound = try await send("PUT", "/publish/v2/app-file-info", query: ["appId": appID, "releaseType": "1"], body: [
            "fileType": 5, "files": [["fileName": .string(file.lastPathComponent), "fileDestUrl": .string(objectID)]],
        ])
        guard let pkg = bound["pkgVersion"].array.first?.string else { log("Attached to the version"); return }
        log("Attached to the version; AppGallery is processing it")
        for _ in 0..<45 {
            try await Task.sleep(for: .seconds(20))
            let s = try await send("GET", "/publish/v2/package/compile/status", query: ["appId": appID, "pkgIds": pkg])
            switch s["pkgStateList"].array.first?["successStatus"].int {
            case 0: log("Processed"); return
            case 2: throw ReleaseError.precondition("AppGallery could not process the package. Check it in AppGallery Connect.")
            default: continue
            }
        }
        throw ReleaseError.precondition("AppGallery is still processing the package after 15 minutes.")
    }

    /// Writes What's new for each language (adding the language when needed).
    public func setWhatsNew(appID: String, notes: [String: String]) async throws {
        for (lang, text) in notes.sorted(by: { $0.key < $1.key }) {
            try await send("PUT", "/publish/v2/app-language-info", query: ["appId": appID, "releaseType": "1"],
                           body: ["lang": .string(Self.language(lang)), "newFeatures": .string(text)])
        }
    }

    /// Sends the version for review. A phased release needs a version released before.
    public func submit(appID: String, release: AGCRelease) async throws {
        switch release {
        case .afterReview:
            try await send("POST", "/publish/v2/app-submit", query: ["appId": appID])
        case .phased(let percent, let days):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            let start = Date().addingTimeInterval(10 * 60)
            try await send("POST", "/publish/v2/app-submit", query: ["appId": appID, "releaseType": "3"], body: [
                "phasedReleaseStartTime": .string(f.string(from: start)),
                "phasedReleaseEndTime": .string(f.string(from: start.addingTimeInterval(TimeInterval(max(1, days)) * 86_400))),
                "phasedReleasePercent": .string(String(format: "%.2f", percent)),
                "phasedReleaseDescription": "Phased release from Release Desk",
            ])
        }
    }

    /// AppGallery's language codes: mostly Play's, but Hebrew is he_IL.
    public static func language(_ code: String) -> String {
        switch code {
        case "iw-IL", "he-IL", "he": "he_IL"
        default: code
        }
    }
}

import Foundation
import Security

/// A Google service account key (the JSON file Google Cloud gives you).
// SecKey is immutable and safe to share across threads.
public struct ServiceAccount: @unchecked Sendable {
    public let email: String
    public let projectID: String
    public let tokenURI: String
    let privateKey: SecKey
    public let json: String

    public init(json: String) throws {
        guard let obj = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
              obj["type"].string == "service_account",
              let email = obj["client_email"].string,
              let pem = obj["private_key"].string else {
            throw ReleaseError.invalidKey("That file is not a Google service account key (JSON with type service_account).")
        }
        self.email = email
        self.projectID = obj["project_id"].string ?? ""
        self.tokenURI = obj["token_uri"].string ?? "https://oauth2.googleapis.com/token"
        self.json = json
        privateKey = try Self.rsaKey(fromPEM: pem)
    }

    /// PKCS#8 PEM → SecKey. Security wants the inner PKCS#1 key, so the
    /// PKCS#8 wrapper is peeled off with a tiny DER reader.
    static func rsaKey(fromPEM pem: String) throws -> SecKey {
        let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { throw ReleaseError.invalidKey("The service account's private key is not base64.") }
        let pkcs1 = (try? DER.pkcs1(fromPKCS8: der)) ?? der
        var error: Unmanaged<CFError>?
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else {
            throw ReleaseError.invalidKey("The service account's private key could not be read.")
        }
        return key
    }

    func assertion(scopes: [String]) throws -> String {
        let now = Date().timeIntervalSince1970.rounded(.down)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let header: [String: String] = ["alg": "RS256", "typ": "JWT"]
        let claims: [String: JSONValue] = [
            "iss": .string(email), "scope": .string(scopes.joined(separator: " ")), "aud": .string(tokenURI),
            "iat": .number(now), "exp": .number(now + 3600),
        ]
        let input = try enc.encode(header).base64URL + "." + enc.encode(claims).base64URL
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, &error) as Data? else {
            throw ReleaseError.invalidKey("Could not sign with the service account key.")
        }
        return input + "." + sig.base64URL
    }
}

enum DER {
    /// PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE, privateKey OCTET STRING }
    static func pkcs1(fromPKCS8 der: Data) throws -> Data {
        var i = der.startIndex
        func readLength() throws -> Int {
            let first = der[i]; i += 1
            if first < 0x80 { return Int(first) }
            let n = Int(first & 0x7f)
            var len = 0
            for _ in 0..<n { len = (len << 8) | Int(der[i]); i += 1 }
            return len
        }
        guard der[i] == 0x30 else { throw ReleaseError.invalidKey("not DER") }
        i += 1; _ = try readLength()
        guard der[i] == 0x02 else { throw ReleaseError.invalidKey("no version") }
        i += 1; let vlen = try readLength(); i += vlen
        guard der[i] == 0x30 else { throw ReleaseError.invalidKey("no algorithm") }
        i += 1; let alen = try readLength(); i += alen
        guard der[i] == 0x04 else { throw ReleaseError.invalidKey("no key") }
        i += 1; let klen = try readLength()
        return der.subdata(in: i..<(i + klen))
    }
}

public struct PlayApp: Identifiable, Hashable, Sendable, Codable {
    public var id: String { packageName }
    public let packageName: String
    public var name: String
}

public struct PlayRelease: Hashable, Sendable, Identifiable {
    public var id: String { "\(name)-\(versionCodes.joined(separator: ","))-\(status)" }
    public let name: String
    public let versionCodes: [String]
    public let status: String
    public let userFraction: Double?
    public let notes: [String: String]

    public var maxCode: Int { versionCodes.compactMap(Int.init).max() ?? 0 }
}

public struct PlayTrack: Hashable, Sendable, Identifiable {
    public var id: String { track }
    public let track: String
    public let releases: [PlayRelease]

    public var title: String {
        switch track {
        case "internal": "Internal testing"
        case "alpha": "Closed testing"
        case "beta": "Open testing"
        case "production": "Production"
        default: track.replacingOccurrences(of: ":", with: " · ").capitalized
        }
    }

    /// Lower sorts first: internal → closed → open → production → the rest.
    public var order: Int {
        ["internal": 0, "alpha": 1, "beta": 2, "production": 3][track] ?? 4
    }
}

public struct PlayAppDetails: Sendable, Hashable {
    public let title: String?
    public let iconURL: String?
    public let defaultLanguage: String?
    public let contactEmail: String?
}

/// How a Play client signs its calls: as a service account, or as a person
/// signed in with their own Google account.
public enum PlayAuth: Sendable {
    case serviceAccount(ServiceAccount)
    case user(GoogleUser)

    public var email: String {
        switch self {
        case .serviceAccount(let s): s.email
        case .user(let u): u.email
        }
    }
}

/// Google Play Developer API (androidpublisher v3) and the Reporting API's
/// app search.
public actor PlayClient {
    public let auth: PlayAuth
    private var cached: (token: String, until: Date)?
    private let session: URLSession
    static let scopes = ["https://www.googleapis.com/auth/androidpublisher", "https://www.googleapis.com/auth/playdeveloperreporting"]
    static let api = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"

    public init(account: ServiceAccount) { self.init(auth: .serviceAccount(account)) }

    public init(auth: PlayAuth) {
        self.auth = auth
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: config)
    }

    private func token() async throws -> String {
        if let cached, cached.until > Date() { return cached.token }
        let account: ServiceAccount
        switch auth {
        case .user(let user):
            let t = try await GoogleSignIn.accessToken(for: user)
            cached = (t.token, Date().addingTimeInterval(TimeInterval(t.expiresIn - 120)))
            return t.token
        case .serviceAccount(let a):
            account = a
        }
        var req = URLRequest(url: URL(string: account.tokenURI)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let assertion = try account.assertion(scopes: Self.scopes)
        req.httpBody = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)".utf8)
        let (data, response) = try await session.data(for: req)
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard (response as? HTTPURLResponse)?.statusCode == 200, let t = json["access_token"].string else {
            throw ReleaseError.api(status: (response as? HTTPURLResponse)?.statusCode ?? 0, path: "oauth token",
                                   messages: [json["error_description"].string ?? json["error"].string ?? "Google refused the service account"])
        }
        cached = (t, Date().addingTimeInterval(TimeInterval((json["expires_in"].int ?? 3600) - 120)))
        return t
    }

    @discardableResult
    public func send(_ method: String, _ url: String, body: JSONValue? = nil, upload: URL? = nil) async throws -> JSONValue {
        var attempt = 0
        while true {
            attempt += 1
            var req = URLRequest(url: URL(string: url)!)
            req.httpMethod = method
            req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
            let data: Data
            let response: URLResponse
            do {
                if let upload {
                    req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    (data, response) = try await session.upload(for: req, fromFile: upload)
                } else {
                    if let body {
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.httpBody = try JSONEncoder().encode(body)
                    }
                    (data, response) = try await session.data(for: req)
                }
            } catch is CancellationError {
                throw ReleaseError.cancelled
            } catch {
                if attempt < 3, upload == nil { try await Task.sleep(for: .seconds(2 * attempt)); continue }
                throw ReleaseError.network(error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.isEmpty ? JSONValue.null : ((try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null)
            if (200..<300).contains(status) { return json }
            if (status == 429 || status >= 500), attempt < 4, upload == nil {
                try await Task.sleep(for: .seconds(3 * attempt))
                continue
            }
            if status == 401 { cached = nil }
            let message = json["error"]["message"].string ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw ReleaseError.api(status: status, path: url, messages: [message])
        }
    }

    /// Apps this account can see. Needs the Play Developer Reporting API
    /// enabled in the service account's Cloud project; nil when it is not.
    public func searchApps() async throws -> [PlayApp]? {
        var apps: [PlayApp] = []
        var page: String?
        repeat {
            var url = "https://playdeveloperreporting.googleapis.com/v1beta1/apps:search?pageSize=100"
            if let page { url += "&pageToken=\(page)" }
            let r: JSONValue
            do { r = try await send("GET", url) } catch let e as ReleaseError where e.httpStatus == 403 || e.httpStatus == 404 {
                return nil
            }
            apps += r["apps"].array.compactMap { a in
                a["packageName"].string.map { PlayApp(packageName: $0, name: a["displayName"].string ?? $0) }
            }
            page = r["nextPageToken"].string
        } while page != nil
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Edits

    func openEdit(_ package: String) async throws -> String {
        let r = try await send("POST", "\(Self.api)/\(package)/edits", body: [:])
        guard let id = r["id"].string else { throw ReleaseError.precondition("Play did not open an edit for \(package)") }
        return id
    }

    func closeEdit(_ package: String, _ edit: String) async {
        _ = try? await send("DELETE", "\(Self.api)/\(package)/edits/\(edit)")
    }

    /// Tracks, their releases and the store listing title, read in a
    /// throwaway edit.
    public func overview(package: String) async throws -> (tracks: [PlayTrack], details: PlayAppDetails) {
        let edit = try await openEdit(package)
        do {
            let t = try await send("GET", "\(Self.api)/\(package)/edits/\(edit)/tracks")
            let d = try? await send("GET", "\(Self.api)/\(package)/edits/\(edit)/details")
            let lang = d?["defaultLanguage"].string
            var title: String?
            var icon: String?
            if let lang, let l = try? await send("GET", "\(Self.api)/\(package)/edits/\(edit)/listings/\(lang)") {
                title = l["title"].string
                icon = (try? await send("GET", "\(Self.api)/\(package)/edits/\(edit)/listings/\(lang)/icon"))?["images"][0]["url"].string
            }
            await closeEdit(package, edit)
            let tracks = t["tracks"].array.map { tr in
                PlayTrack(track: tr["track"].string ?? "?", releases: tr["releases"].array.map(Self.release))
            }.sorted { ($0.order, $0.track) < ($1.order, $1.track) }
            return (tracks, PlayAppDetails(title: title, iconURL: icon, defaultLanguage: lang, contactEmail: d?["contactEmail"].string))
        } catch {
            await closeEdit(package, edit)
            throw error
        }
    }

    static func release(_ r: JSONValue) -> PlayRelease {
        PlayRelease(name: r["name"].string ?? "", versionCodes: r["versionCodes"].array.compactMap(\.string),
                    status: r["status"].string ?? "?", userFraction: r["userFraction"].isNull ? nil : r["userFraction"].int.map(Double.init) ?? Double(r["userFraction"].string ?? ""),
                    notes: Dictionary(r["releaseNotes"].array.compactMap { n in n["language"].string.map { ($0, n["text"].string ?? "") } },
                                      uniquingKeysWith: { a, _ in a }))
    }

    /// Uploads an .aab and releases it to a track in one edit.
    /// `log` receives progress lines. Returns the version code Play read.
    public func release(package: String, bundle: URL, track: String, name: String, status: String, userFraction: Double?,
                        notes: [String: String], log: @Sendable (String) -> Void) async throws -> (versionCode: String, status: String) {
        let edit = try await openEdit(package)
        do {
            log("Uploading \(bundle.lastPathComponent) to edit \(edit)…")
            let up = try await send("POST", "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/\(package)/edits/\(edit)/bundles?uploadType=media",
                                    upload: bundle)
            guard let code = up["versionCode"].string else { throw ReleaseError.precondition("Play did not return a version code") }
            log("Play read version code \(code)")
            var finalStatus = status
            for attempt in 0..<2 {
                var rel: [String: JSONValue] = ["name": .string(name), "versionCodes": [.string(code)], "status": .string(finalStatus)]
                if finalStatus == "inProgress", let f = userFraction { rel["userFraction"] = .number(f) }
                let ns = notes.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
                if !ns.isEmpty { rel["releaseNotes"] = .array(ns.map { ["language": .string($0.key), "text": .string($0.value)] }) }
                do {
                    try await send("PUT", "\(Self.api)/\(package)/edits/\(edit)/tracks/\(track)",
                                   body: ["track": .string(track), "releases": [.object(rel)]])
                    break
                } catch let e as ReleaseError where attempt == 0 && e.localizedDescription.lowercased().contains("draft app") {
                    // Apps never published yet only take draft releases.
                    log("This app is still a draft on Play, so the release goes in as a draft.")
                    finalStatus = "draft"
                }
            }
            log("Track \(track) → \(name) (\(code)), \(finalStatus)")
            try await send("POST", "\(Self.api)/\(package)/edits/\(edit):commit")
            log("Edit committed")
            return (code, finalStatus)
        } catch {
            await closeEdit(package, edit)
            throw error
        }
    }
}

import CryptoKit
import Foundation
import Network

/// The OAuth client Release Desk signs in to Google with (a "Desktop app"
/// client from Google Cloud, the client_secret_….json file).
public struct OAuthClient: Sendable, Codable, Hashable {
    public let clientID: String
    public let clientSecret: String
    public let projectID: String?

    public init(json: String) throws {
        guard let obj = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else {
            throw ReleaseError.invalidKey("That file is not JSON.")
        }
        let c = obj["installed"].isNull ? obj["web"] : obj["installed"]
        guard let id = c["client_id"].string, let secret = c["client_secret"].string else {
            throw ReleaseError.invalidKey("That file is not a Google OAuth client (client_secret_….json).")
        }
        clientID = id
        clientSecret = secret
        projectID = c["project_id"].string
    }

    public static let keychainAccount = "google-oauth-client"

    /// The client saved in the Keychain, if any.
    public static func saved() -> OAuthClient? {
        guard let s = try? Keychain.read(account: keychainAccount), let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OAuthClient.self, from: data)
    }

    public func save() throws {
        try Keychain.save(String(decoding: try JSONEncoder().encode(self), as: UTF8.self), account: Self.keychainAccount)
    }
}

/// A person signed in with their own Google account: what Release Desk
/// keeps (in the Keychain) to get fresh access tokens.
public struct GoogleUser: Sendable, Codable, Hashable {
    public let email: String
    public let refreshToken: String
    public let client: OAuthClient
}

public enum GoogleSignIn {
    public static let scopes = [
        "openid", "email",
        "https://www.googleapis.com/auth/androidpublisher",
        "https://www.googleapis.com/auth/playdeveloperreporting",
    ]

    /// Opens Google's sign-in in the browser and waits for it to come back to
    /// a one-time listener on 127.0.0.1 (OAuth for installed apps, with PKCE).
    public static func signIn(client: OAuthClient, loginHint: String? = nil,
                              open: @Sendable @escaping (URL) -> Void) async throws -> GoogleUser {
        let verifier = randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomString(24)
        let listener = try LoopbackListener()
        let port = try await listener.start()
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: client.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),
        ] + (loginHint.map { [URLQueryItem(name: "login_hint", value: $0)] } ?? [])
        open(comps.url!)

        let query = try await listener.waitForRedirect(timeout: 300)
        listener.stop()
        if let error = query["error"] {
            throw ReleaseError.precondition(error == "access_denied" ? "Google sign-in was cancelled." : "Google said: \(error)")
        }
        guard query["state"] == state, let code = query["code"] else {
            throw ReleaseError.precondition("Google's answer did not match this sign-in. Try again.")
        }

        let token = try await tokenRequest([
            "code": code, "client_id": client.clientID, "client_secret": client.clientSecret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let refresh = token["refresh_token"].string else {
            throw ReleaseError.precondition("Google gave no refresh token. Remove Release Desk at myaccount.google.com/permissions and sign in again.")
        }
        var email = "Google account"
        if let idToken = token["id_token"].string {
            let parts = idToken.split(separator: ".")
            if parts.count > 1, let payload = Data(base64URL: String(parts[1])),
               let claims = try? JSONDecoder().decode(JSONValue.self, from: payload), let e = claims["email"].string {
                email = e
            }
        }
        return GoogleUser(email: email, refreshToken: refresh, client: client)
    }

    /// A fresh access token for a signed-in user.
    static func accessToken(for user: GoogleUser) async throws -> (token: String, expiresIn: Int) {
        let r = try await tokenRequest([
            "client_id": user.client.clientID, "client_secret": user.client.clientSecret,
            "refresh_token": user.refreshToken, "grant_type": "refresh_token",
        ])
        guard let t = r["access_token"].string else {
            throw ReleaseError.precondition("Google did not refresh the sign-in for \(user.email). Sign in again.")
        }
        return (t, r["expires_in"].int ?? 3600)
    }

    static func tokenRequest(_ form: [String: String]) async throws -> JSONValue {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ReleaseError.api(status: (response as? HTTPURLResponse)?.statusCode ?? 0, path: "oauth token",
                                   messages: [json["error_description"].string ?? json["error"].string ?? "Google refused the sign-in"])
        }
        return json
    }

    static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var g = SystemRandomNumberGenerator()
        return String((0..<n).map { _ in chars[Int(g.next() % UInt64(chars.count))] })
    }
}

extension Data {
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}

/// A tiny HTTP listener on 127.0.0.1 that takes one OAuth redirect.
final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "releasedesk.oauth")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?
    private let lock = NSLock()

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            // The handler runs on `queue` only, one call at a time.
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let e):
                    resumed = true
                    cont.resume(throwing: e)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
                lock.lock()
                if let result {
                    lock.unlock()
                    cont.resume(with: result)
                    return
                }
                continuation = cont
                lock.unlock()
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(ReleaseError.precondition("Google sign-in timed out. Try again.")))
                }
            }
        } onCancel: {
            self.finish(.failure(ReleaseError.cancelled))
        }
    }

    private func finish(_ r: Result<[String: String], Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: r)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else { conn.cancel(); return }
            let parts = line.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : "/"
            guard let comps = URLComponents(string: "http://127.0.0.1\(target)"), comps.path == "/" else {
                self.reply(conn, status: "404 Not Found", body: "")
                return
            }
            var query: [String: String] = [:]
            for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }
            let ok = query["code"] != nil
            self.reply(conn, status: "200 OK", body: Self.page(ok: ok))
            self.finish(.success(query))
        }
    }

    private func reply(_ conn: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in conn.cancel() })
    }

    static func page(ok: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Release Desk</title>
        <style>body{margin:0;height:100vh;display:grid;place-items:center;font:16px -apple-system,system-ui;background:#0b0d1a;color:#fff}
        .c{text-align:center}.i{font-size:56px}h1{font-weight:700;margin:.3em 0}p{color:#aab}</style></head>
        <body><div class="c"><div class="i">\(ok ? "✈️" : "✋")</div><h1>\(ok ? "You're signed in" : "Sign-in stopped")</h1>
        <p>\(ok ? "Go back to Release Desk. You can close this tab." : "Go back to Release Desk and try again.")</p></div></body></html>
        """
    }
}

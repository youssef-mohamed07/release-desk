import CryptoKit
import Foundation
import Security

/// An App Store Connect API key: the public part (ids) plus the private key,
/// which only ever lives in the Keychain or in memory.
public struct ASCKey: Sendable {
    public let keyID: String
    public let issuerID: String
    let privateKey: P256.Signing.PrivateKey
    let pem: String

    public init(keyID: String, issuerID: String, pem: String) throws {
        self.keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.issuerID = issuerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pem = pem
        do {
            privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw ReleaseError.invalidKey("That file is not an App Store Connect private key (.p8).")
        }
    }

    /// A signed ES256 token, valid for 19 minutes (Apple allows at most 20).
    public func token(lifetime: TimeInterval = 19 * 60) throws -> String {
        let now = Date()
        let header: [String: String] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let payload: [String: JSONValue] = [
            "iss": .string(issuerID),
            "iat": .number(now.timeIntervalSince1970.rounded(.down)),
            "exp": .number(now.addingTimeInterval(lifetime).timeIntervalSince1970.rounded(.down)),
            "aud": "appstoreconnect-v1",
        ]
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let signingInput = try enc.encode(header).base64URL + "." + enc.encode(payload).base64URL
        // CryptoKit's raw representation is r‖s, exactly what JOSE expects.
        let signature = try privateKey.signature(for: Data(signingInput.utf8)).rawRepresentation
        return signingInput + "." + signature.base64URL
    }

    /// Writes the key to a private temporary file for tools that need a path
    /// (xcodebuild, altool). The caller deletes it when the run ends.
    public func materialize(in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("AuthKey_\(keyID).p8")
        FileManager.default.createFile(atPath: url.path, contents: Data(pem.utf8),
                                       attributes: [.posixPermissions: 0o600])
        return url
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Secrets in the login Keychain, one generic password per credential.
public enum Keychain {
    public static let service = "app.releasedesk.credentials"

    public static func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Release Desk: \(account)"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ReleaseError.keychain(status) }
    }

    public static func read(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8) else {
            throw ReleaseError.keychain(status)
        }
        return s
    }

    public static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public enum ReleaseError: LocalizedError, Sendable {
    case invalidKey(String)
    case keychain(OSStatus)
    case api(status: Int, path: String, messages: [String])
    case network(String)
    case command(String, code: Int32, tail: String)
    case precondition(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidKey(let m): return m
        case .keychain(let s):
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "status \(s)"
            return "Keychain: \(msg)"
        case .api(let status, let path, let messages):
            let google = path.contains("googleapis.com") || path.contains("androidpublisher") || path == "oauth token"
            let store = path.contains("huawei.com") || path.contains("myhuaweicloud") ? "AppGallery"
                : path.contains("microsoft") || path.contains("windows.net") ? "Microsoft Store"
                : google ? "Google Play" : "App Store Connect"
            let shown = URL(string: path).flatMap { $0.host != nil ? $0.path : nil } ?? path
            return "\(store) \(status) on \(shown): \(messages.joined(separator: "; "))"
        case .network(let m): return m
        case .command(let c, let code, let tail):
            return "\(c) failed (exit \(code))" + (tail.isEmpty ? "" : "\n\(tail)")
        case .precondition(let m): return m
        case .cancelled: return "Cancelled"
        }
    }

    /// Google answers 403 "The caller does not have permission" when the
    /// service account is not a user of the Play Console account.
    public var isPlayPermission: Bool {
        if case .api(403, let path, _) = self { return path.contains("googleapis.com") }
        return false
    }

    public var httpStatus: Int? {
        if case .api(let s, _, _) = self { return s }
        return nil
    }
}

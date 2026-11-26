import Foundation

public enum StoreProvider: String, Codable, Sendable, Hashable, CaseIterable {
    case apple, google, huawei, microsoft

    public var title: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google Play"
        case .huawei: "AppGallery"
        case .microsoft: "Microsoft Store"
        }
    }

    /// The prefix of app ids from this store ("" for App Store Connect, whose ids are Apple's).
    public var appPrefix: String {
        switch self {
        case .apple: ""
        case .google: "play:"
        case .huawei: "agc:"
        case .microsoft: "msstore:"
        }
    }

    /// The store an app id belongs to.
    public static func of(appID: String) -> StoreProvider {
        allCases.first { !$0.appPrefix.isEmpty && appID.hasPrefix($0.appPrefix) } ?? .apple
    }
}

/// A person's sign-in with a store (an Apple ID, a Google account). It holds
/// the developer teams that person reaches.
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var provider: StoreProvider
    public var name: String
    public var email: String?
    public var teams: [Team] = []

    public init(provider: StoreProvider, name: String, email: String? = nil) {
        self.provider = provider
        self.name = name
        self.email = email
    }
}

/// One developer team (Apple) or developer account (Play), and how Release
/// Desk reaches it. The secret part is in the Keychain under `secretAccount`.
public struct Team: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var teamID: String?
    public var credential: Credential
    /// Play apps added by package name (Play has no list of a developer's
    /// apps unless the Reporting API is on).
    public var packages: [String]?

    public init(name: String, teamID: String?, credential: Credential) {
        self.name = name
        self.teamID = teamID
        self.credential = credential
    }
}

public enum Credential: Codable, Hashable, Sendable {
    case appStoreConnectKey(keyID: String, issuerID: String)
    case playServiceAccount(email: String)
    /// Signed in with a person's own Google account.
    case googleUser(email: String)
    /// AppGallery Connect API client (Connect API, team level); the key is the secret.
    case agcClient(clientID: String)
    /// A Microsoft Entra app added to Partner Center as Manager; the client secret is the secret.
    case partnerCenter(tenantID: String, clientID: String, sellerID: String)

    public var secretAccount: String {
        switch self {
        case .appStoreConnectKey(let keyID, _): "asc:\(keyID)"
        case .playServiceAccount(let email): "play:\(email)"
        case .googleUser(let email): "google:\(email)"
        case .agcClient(let id): "agc:\(id)"
        case .partnerCenter(_, let clientID, _): "ms:\(clientID)"
        }
    }

    public var summary: String {
        switch self {
        case .appStoreConnectKey(let keyID, _): "API key \(keyID)"
        case .playServiceAccount(let email): email
        case .googleUser(let email): "Signed in as \(email)"
        case .agcClient(let id): "API client \(id)"
        case .partnerCenter(_, _, let seller): "Seller \(seller)"
        }
    }

    public var store: StoreProvider {
        switch self {
        case .appStoreConnectKey: .apple
        case .playServiceAccount, .googleUser: .google
        case .agcClient: .huawei
        case .partnerCenter: .microsoft
        }
    }

    public var isGoogle: Bool { store == .google }

    /// Stores where apps are added by package name when the API can't list them.
    public var takesPackages: Bool { store == .google || store == .huawei }
}

public enum ProjectKind: String, Codable, Sendable { case flutter }

/// A store app tied to the source folder it is built from, with the recipe
/// the pipeline follows for it.
public struct ProjectLink: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var appID: String
    public var path: String
    public var kind: ProjectKind = .flutter
    public var recipe = IOSRecipe()

    public init(appID: String, path: String) {
        self.appID = appID
        self.path = path
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

public struct IOSRecipe: Codable, Hashable, Sendable {
    /// Relative to the project folder. Generated per run when missing.
    public var exportOptions = "ios/ExportOptions.plist"
    public var entitlements = "ios/Runner/Runner.entitlements"
    /// Archive unsigned, ad-hoc sign, then let cloud signing make the real
    /// signature at export. Needed by teams with no registered devices.
    public var cloudSigning = true
    public var writeBuildNumber = true
    public var groupIDs: [String] = []
    public var submitForReview = true
    /// Languages of What to Test (TestFlight).
    public var locales = ["ar-SA", "en-US"]
    /// Languages of the App Store version's What's New; nil means the same as `locales`.
    public var appStoreLocales: [String]?
    /// Languages of a Google Play release's What's new; nil means English and Arabic.
    public var playLocales: [String]?
    /// A Google Play app whose builds also go to AppGallery.
    public var agcToo: Bool?
    /// Languages of a Microsoft Store release's What's new (listing keys like en-us).
    public var msLocales: [String]?
    /// Microsoft Store package rollout percentage used last time (0 = everyone).
    public var msRollout: Int?
    /// iOS: "github" to build on GitHub Actions instead of this Mac.
    public var buildOn: String?
    /// Android: "github" to build the app bundle on GitHub Actions.
    public var androidBuildOn: String?
    /// Android: the track and status used last time.
    public var playTrack: String?
    public var playStatus: String?

    public init() {}
}

public struct RunRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var appID: String
    public var appName: String
    public var version: String
    public var build: Int
    public var started: Date
    public var finished: Date?
    public var outcome: String
    public var failedStep: String?
    public var logPath: String?

    public init(id: UUID, appID: String, appName: String, version: String, build: Int, started: Date, finished: Date?,
                outcome: String, failedStep: String?, logPath: String?) {
        self.id = id
        self.appID = appID
        self.appName = appName
        self.version = version
        self.build = build
        self.started = started
        self.finished = finished
        self.outcome = outcome
        self.failedStep = failedStep
        self.logPath = logPath
    }
}

public struct Workspace: Codable, Sendable {
    public var accounts: [Account] = []
    public var links: [ProjectLink] = []
    public var runs: [RunRecord] = []

    public init() {}

    public func link(for appID: String) -> ProjectLink? { links.first { $0.appID == appID } }

    public func team(_ id: UUID) -> (Account, Team)? {
        for a in accounts { if let t = a.teams.first(where: { $0.id == id }) { return (a, t) } }
        return nil
    }
}

public enum WorkspaceStore {
    public static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Release Desk", isDirectory: true)
    }
    static var file: URL { folder.appendingPathComponent("workspace.json") }
    public static var logs: URL { folder.appendingPathComponent("Logs", isDirectory: true) }

    public static func load() -> Workspace {
        guard let data = try? Data(contentsOf: file) else { return Workspace() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(Workspace.self, from: data)) ?? Workspace()
    }

    public static func save(_ ws: Workspace) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(ws).write(to: file, options: .atomic)
    }
}

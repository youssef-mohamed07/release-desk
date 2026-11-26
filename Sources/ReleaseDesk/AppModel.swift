import AppKit
import ReleaseKit
import SwiftUI
import UserNotifications

enum Route: Hashable {
    case overview
    case activity
    case team(UUID)
    case app(String)
    case ship(String)
}

struct TeamState {
    var apps: [ASCApp] = []
    var loading = false
    var error: String?
    var refreshed: Date?
}

struct AppState {
    var tracks: [PlayTrack] = []
    var play: PlayAppDetails?
    var agc: AGCApp?
    var ms: MSApp?
    var builds: [ASCBuild] = []
    var groups: [ASCBetaGroup] = []
    var versions: [ASCVersion] = []
    var loading = false
    var error: String?
    var refreshed: Date?
    var detailed = false
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var workspace: Workspace
    var route: Route? = .overview
    var teams: [UUID: TeamState] = [:]
    var apps: [String: AppState] = [:]
    var runs: [ReleaseRun] = []
    var connecting: StoreProvider?
    var alert: String?

    @ObservationIgnored private var clients: [UUID: ASCClient] = [:]
    @ObservationIgnored private var playClients: [UUID: PlayClient] = [:]
    @ObservationIgnored private var agcClients: [UUID: AppGalleryClient] = [:]
    @ObservationIgnored private var msClients: [UUID: MicrosoftStoreClient] = [:]
    /// AppGallery's own app ids, by Release Desk app id ("agc:<package>").
    @ObservationIgnored private(set) var agcAppIDs: [String: String] = [:]
    @ObservationIgnored let github = GitHubClient()
    var palette = false
    var newApp = false
    /// An app whose page should open the App Review sheet.
    var pendingReview: String?
    var privacy: Bool = UserDefaults.standard.bool(forKey: "privacyMode") {
        didSet { UserDefaults.standard.set(privacy, forKey: "privacyMode") }
    }
    /// A key file dropped on the window, handed to the Connect sheet.
    var droppedKey: URL?
    @ObservationIgnored private var appTeam: [String: UUID] = [:]
    /// Icon templates remembered between launches so the sidebar has icons at once.
    private var icons: [String: String] = UserDefaults.standard.dictionary(forKey: "icons") as? [String: String] ?? [:]

    init() {
        workspace = WorkspaceStore.load()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Lookups

    var appleTeams: [(account: Account, team: Team)] { teams(of: .apple) }
    var playTeams: [(account: Account, team: Team)] { teams(of: .google) }
    var allTeams: [(account: Account, team: Team)] { workspace.accounts.flatMap { a in a.teams.map { (a, $0) } } }

    func teams(of provider: StoreProvider) -> [(account: Account, team: Team)] {
        workspace.accounts.filter { $0.provider == provider }.flatMap { a in a.teams.map { (a, $0) } }
    }

    var allApps: [ASCApp] { allTeams.flatMap { teams[$0.team.id]?.apps ?? [] } }

    func app(_ id: String) -> ASCApp? {
        for s in teams.values { if let a = s.apps.first(where: { $0.id == id }) { return a } }
        return nil
    }

    func team(ofApp id: String) -> Team? {
        appTeam[id].flatMap { workspace.team($0)?.1 }
    }

    func iconURL(_ appID: String, size: Int = 256) -> URL? {
        let store = StoreProvider.of(appID: appID)
        if store == .huawei || store == .microsoft {
            let pkg = app(appID)?.bundleID ?? ""
            if let twin = allApps.first(where: { $0.bundleID == pkg && [.apple, .google].contains(StoreProvider.of(appID: $0.id)) }) {
                return iconURL(twin.id, size: size)
            }
            return nil
        }
        if appID.isPlay {
            if let u = apps[appID]?.play?.iconURL ?? icons[appID] { return URL(string: u + "=s\(size)") }
            // The same app on the App Store lends its icon.
            let pkg = appID.playPackage
            if let twin = allApps.first(where: { $0.store == .apple && $0.bundleID == pkg }) { return iconURL(twin.id, size: size) }
            return nil
        }
        if let b = apps[appID]?.builds.first(where: { $0.iconTemplate != nil }) { return b.iconURL(size: size) }
        guard let t = icons[appID] else { return nil }
        return URL(string: t.replacingOccurrences(of: "{w}", with: "\(size)").replacingOccurrences(of: "{h}", with: "\(size)")
            .replacingOccurrences(of: "{f}", with: "png"))
    }

    func activeRun(for appID: String) -> ReleaseRun? {
        runs.last { $0.plan.app.id == appID && ($0.phase == .running || $0.phase == .ready) }
    }

    func latestRun(for appID: String) -> ReleaseRun? { runs.last { $0.plan.app.id == appID } }

    var runningCount: Int { runs.filter { $0.phase == .running }.count }

    // MARK: - Clients

    func client(for team: Team) throws -> ASCClient {
        if let c = clients[team.id] { return c }
        guard case .appStoreConnectKey(let keyID, let issuer) = team.credential else {
            throw ReleaseError.precondition("\(team.name) is not an App Store Connect team")
        }
        let pem = try Keychain.read(account: team.credential.secretAccount)
        let c = ASCClient(key: try ASCKey(keyID: keyID, issuerID: issuer, pem: pem))
        clients[team.id] = c
        return c
    }

    func playClient(for team: Team) throws -> PlayClient {
        if let c = playClients[team.id] { return c }
        let json = try Keychain.read(account: team.credential.secretAccount)
        let c: PlayClient
        if case .googleUser = team.credential {
            c = PlayClient(auth: .user(try JSONDecoder().decode(GoogleUser.self, from: Data(json.utf8))))
        } else {
            c = PlayClient(account: try ServiceAccount(json: json))
        }
        playClients[team.id] = c
        return c
    }

    func agcClient(for team: Team) throws -> AppGalleryClient {
        if let c = agcClients[team.id] { return c }
        guard case .agcClient(let id) = team.credential else { throw ReleaseError.precondition("\(team.name) is not an AppGallery team") }
        let c = AppGalleryClient(clientID: id, secret: try Keychain.read(account: team.credential.secretAccount))
        agcClients[team.id] = c
        return c
    }

    func msClient(for team: Team) throws -> MicrosoftStoreClient {
        if let c = msClients[team.id] { return c }
        guard case .partnerCenter(let tenant, let clientID, _) = team.credential else {
            throw ReleaseError.precondition("\(team.name) is not a Partner Center account")
        }
        let c = MicrosoftStoreClient(tenantID: tenant, clientID: clientID, secret: try Keychain.read(account: team.credential.secretAccount))
        msClients[team.id] = c
        return c
    }

    func client(forApp id: String) throws -> ASCClient {
        guard let t = team(ofApp: id) else { throw ReleaseError.precondition("No team for this app") }
        return try client(for: t)
    }

    // MARK: - Loading

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { g in
            for (_, team) in allTeams { g.addTask { await self.refresh(team: team) } }
        }
    }

    func refresh(team: Team) async {
        switch team.credential.store {
        case .google: return await refreshPlay(team: team)
        case .huawei: return await refreshAppGallery(team: team)
        case .microsoft: return await refreshMicrosoft(team: team)
        case .apple: break
        }
        teams[team.id, default: TeamState()].loading = true
        defer { teams[team.id]?.loading = false }
        do {
            let c = try client(for: team)
            let list = try await c.apps()
            teams[team.id]?.apps = list
            teams[team.id]?.error = nil
            teams[team.id]?.refreshed = Date()
            for a in list { appTeam[a.id] = team.id }
            // A light pass for every app: the latest builds give icons and states.
            await withTaskGroup(of: (String, [ASCBuild]?).self) { g in
                for a in list {
                    g.addTask { (a.id, try? await c.builds(appID: a.id, limit: 3)) }
                }
                for await (id, builds) in g {
                    guard let builds else { continue }
                    if apps[id]?.detailed != true { apps[id, default: AppState()].builds = builds }
                    if let t = builds.first(where: { $0.iconTemplate != nil })?.iconTemplate { icons[id] = t }
                }
            }
            UserDefaults.standard.set(icons, forKey: "icons")
        } catch {
            teams[team.id]?.error = error.localizedDescription
        }
    }

    // MARK: - Google Play

    func refreshPlay(team: Team) async {
        teams[team.id, default: TeamState()].loading = true
        defer { teams[team.id]?.loading = false }
        do {
            let c = try playClient(for: team)
            var packages = team.packages ?? []
            if let found = try await c.searchApps() {
                for a in found where !packages.contains(a.packageName) { packages.append(a.packageName) }
            }
            var list = packages.map { ASCApp(id: "play:\($0)", name: knownName(for: $0), bundleID: $0, sku: "", primaryLocale: "") }
            for a in list { appTeam[a.id] = team.id }
            teams[team.id]?.apps = list
            teams[team.id]?.error = nil
            await withTaskGroup(of: (String, Result<(tracks: [PlayTrack], details: PlayAppDetails), Error>).self) { g in
                for a in list {
                    g.addTask { (a.id, await Result { try await c.overview(package: a.bundleID) }) }
                }
                for await (id, result) in g {
                    switch result {
                    case .success(let o):
                        apps[id, default: AppState()].tracks = o.tracks
                        apps[id]?.play = o.details
                        apps[id]?.error = nil
                        apps[id]?.detailed = true
                        if let icon = o.details.iconURL { icons[id] = icon }
                        if let title = o.details.title, let i = list.firstIndex(where: { $0.id == id }) {
                            list[i] = ASCApp(id: id, name: title, bundleID: list[i].bundleID, sku: "", primaryLocale: o.details.defaultLanguage ?? "")
                        }
                    case .failure(let e):
                        apps[id, default: AppState()].error = playMessage(e, team: team)
                    }
                }
            }
            teams[team.id]?.apps = list
            teams[team.id]?.refreshed = Date()
            UserDefaults.standard.set(icons, forKey: "icons")
        } catch {
            teams[team.id]?.error = playMessage(error, team: team)
        }
    }

    // MARK: - AppGallery

    func refreshAppGallery(team: Team) async {
        teams[team.id, default: TeamState()].loading = true
        defer { teams[team.id]?.loading = false }
        do {
            let c = try agcClient(for: team)
            var found: [String: (appID: String, name: String)] = [:]
            // Every app of the team when the API client may read projects; else the packages named.
            if let all = try? await c.allApps() { for a in all { found[a.package] = (a.appID, a.name) } }
            let named = (team.packages ?? []).filter { found[$0] == nil }
            if !named.isEmpty { for (k, v) in try await c.appIDs(packages: named) { found[k] = v } }
            var list = found.keys.sorted().map { ASCApp(id: "agc:\($0)", name: found[$0]!.name, bundleID: $0, sku: "", primaryLocale: "") }
            for a in list { appTeam[a.id] = team.id; agcAppIDs[a.id] = found[a.bundleID]!.appID }
            teams[team.id]?.apps = list
            teams[team.id]?.error = (team.packages ?? []).isEmpty && found.isEmpty
                ? "No apps yet. Add their package names on this team's page." : nil
            await withTaskGroup(of: (String, Result<AGCApp, Error>).self) { g in
                for a in list {
                    let appID = found[a.bundleID]!.appID
                    g.addTask { (a.id, await Result { try await c.app(appID: appID, package: a.bundleID) }) }
                }
                for await (id, result) in g {
                    switch result {
                    case .success(let info):
                        apps[id, default: AppState()].agc = info
                        apps[id]?.error = nil
                        apps[id]?.detailed = true
                        if let i = list.firstIndex(where: { $0.id == id }) {
                            list[i] = ASCApp(id: id, name: info.name, bundleID: list[i].bundleID, sku: "", primaryLocale: "")
                        }
                    case .failure(let e):
                        apps[id, default: AppState()].error = e.localizedDescription
                    }
                }
            }
            teams[team.id]?.apps = list
            teams[team.id]?.refreshed = Date()
        } catch {
            teams[team.id]?.error = error.localizedDescription
        }
    }

    /// Checks an API client without saving anything: the token, then the apps it sees.
    func verifyAppGallery(clientID: String, secret: String, packages: [String]) async throws -> [(package: String, name: String)] {
        let c = AppGalleryClient(clientID: clientID, secret: secret)
        var found: [String: String] = [:]
        if let all = try? await c.allApps() { for a in all { found[a.package] = a.name } }
        let named = packages.filter { found[$0] == nil }
        if !named.isEmpty { for (k, v) in try await c.appIDs(packages: named) { found[k] = v.name } }
        if found.isEmpty, packages.isEmpty { _ = try await c.appIDs(packages: ["com.example.check"]) }
        return found.keys.sorted().map { ($0, found[$0]!) }
    }

    func connectAppGallery(accountID: UUID?, newAccountName: String, teamName: String, clientID: String, secret: String, packages: [String]) throws {
        let credential = Credential.agcClient(clientID: clientID)
        try Keychain.save(secret, account: credential.secretAccount)
        var team = Team(name: teamName, teamID: nil, credential: credential)
        team.packages = packages
        add(team, provider: .huawei, accountID: accountID, newAccountName: newAccountName, email: nil)
    }

    // MARK: - Microsoft Store

    func refreshMicrosoft(team: Team) async {
        teams[team.id, default: TeamState()].loading = true
        defer { teams[team.id]?.loading = false }
        do {
            let c = try msClient(for: team)
            let found = try await c.applications()
            let list = found.map { ASCApp(id: "msstore:\($0.id)", name: $0.name, bundleID: $0.packageIdentityName, sku: "", primaryLocale: "") }
            for (a, m) in zip(list, found) {
                appTeam[a.id] = team.id
                if apps[a.id]?.detailed != true { apps[a.id, default: AppState()].ms = m }
            }
            teams[team.id]?.apps = list
            teams[team.id]?.error = list.isEmpty ? "Partner Center lists no apps for this account." : nil
            teams[team.id]?.refreshed = Date()
        } catch {
            teams[team.id]?.error = error.localizedDescription
        }
    }

    func refreshMicrosoft(appID: String) async {
        guard let team = team(ofApp: appID), let c = try? msClient(for: team) else { return }
        apps[appID, default: AppState()].loading = true
        defer { apps[appID]?.loading = false }
        do {
            apps[appID]?.ms = try await c.details(String(appID.dropFirst("msstore:".count)))
            apps[appID]?.error = nil
            apps[appID]?.refreshed = Date()
            apps[appID]?.detailed = true
        } catch {
            if !isCancellation(error) { apps[appID]?.error = error.localizedDescription }
        }
    }

    /// Checks Partner Center credentials without saving anything; returns the apps.
    func verifyMicrosoft(tenantID: String, clientID: String, secret: String) async throws -> [MSApp] {
        try await MicrosoftStoreClient(tenantID: tenantID, clientID: clientID, secret: secret).applications()
    }

    func connectMicrosoft(accountID: UUID?, newAccountName: String, teamName: String, tenantID: String, clientID: String,
                          sellerID: String, secret: String) throws {
        let credential = Credential.partnerCenter(tenantID: tenantID, clientID: clientID, sellerID: sellerID)
        try Keychain.save(secret, account: credential.secretAccount)
        add(Team(name: teamName, teamID: sellerID, credential: credential), provider: .microsoft, accountID: accountID,
            newAccountName: newAccountName, email: nil)
    }

    /// Before Play gives a title, a linked project or the App Store twin names the app.
    private func knownName(for package: String) -> String {
        if let twin = allApps.first(where: { $0.store == .apple && $0.bundleID == package }) { return twin.name }
        if let n = teams.values.flatMap(\.apps).first(where: { $0.bundleID == package && $0.isPlay && $0.name != package })?.name { return n }
        return package
    }

    func playMessage(_ error: Error, team: Team) -> String {
        if let e = error as? ReleaseError, e.isPlayPermission {
            switch team.credential {
            case .playServiceAccount(let email):
                return "Play Console has not given \(email) access to this app yet. Invite it in Play Console → Users and permissions, with the Release permissions for the app."
            case .googleUser(let email):
                return "\(email) has no access to this app on Play Console, or the app is in another developer account."
            default: break
            }
        }
        return error.localizedDescription
    }

    /// Saves a person's Google sign-in and shows their Play apps as one
    /// developer account.
    func connectGoogleUser(_ user: GoogleUser, accountID: UUID?, teamName: String, packages: [String]) throws {
        let credential = Credential.googleUser(email: user.email)
        try Keychain.save(String(decoding: try JSONEncoder().encode(user), as: UTF8.self), account: credential.secretAccount)
        var team = Team(name: teamName, teamID: nil, credential: credential)
        team.packages = packages
        add(team, provider: .google, accountID: accountID, newAccountName: user.email, email: user.email)
    }

    func connectGoogle(accountID: UUID?, newAccountName: String, teamName: String, json: String, packages: [String]) throws {
        let sa = try ServiceAccount(json: json)
        let credential = Credential.playServiceAccount(email: sa.email)
        try Keychain.save(json, account: credential.secretAccount)
        var team = Team(name: teamName, teamID: sa.projectID, credential: credential)
        team.packages = packages
        add(team, provider: .google, accountID: accountID, newAccountName: newAccountName, email: nil)
    }

    func setPackages(_ packages: [String], team: Team) {
        for i in workspace.accounts.indices {
            if let j = workspace.accounts[i].teams.firstIndex(where: { $0.id == team.id }) { workspace.accounts[i].teams[j].packages = packages }
        }
        save()
        if let t = workspace.team(team.id)?.1 { Task { await refresh(team: t) } }
    }

    private func add(_ team: Team, provider: StoreProvider, accountID: UUID?, newAccountName: String, email: String?) {
        if let accountID, let i = workspace.accounts.firstIndex(where: { $0.id == accountID && $0.provider == provider }) {
            workspace.accounts[i].teams.append(team)
        } else {
            var a = Account(provider: provider, name: newAccountName, email: email)
            a.teams = [team]
            workspace.accounts.append(a)
        }
        save()
        route = .team(team.id)
        Task { await refresh(team: team) }
    }

    func refresh(appID: String) async {
        if StoreProvider.of(appID: appID) == .huawei {
            guard let team = team(ofApp: appID), let c = try? agcClient(for: team), let id = agcAppIDs[appID] else { return }
            apps[appID, default: AppState()].loading = true
            defer { apps[appID]?.loading = false }
            do {
                apps[appID]?.agc = try await c.app(appID: id, package: app(appID)?.bundleID ?? "")
                apps[appID]?.error = nil
                apps[appID]?.refreshed = Date()
                apps[appID]?.detailed = true
            } catch {
                if !isCancellation(error) { apps[appID]?.error = error.localizedDescription }
            }
            return
        }
        if StoreProvider.of(appID: appID) == .microsoft { return await refreshMicrosoft(appID: appID) }
        if appID.isPlay {
            guard let team = team(ofApp: appID), let c = try? playClient(for: team) else { return }
            apps[appID, default: AppState()].loading = true
            defer { apps[appID]?.loading = false }
            do {
                let o = try await c.overview(package: appID.playPackage)
                apps[appID]?.tracks = o.tracks
                apps[appID]?.play = o.details
                apps[appID]?.error = nil
                apps[appID]?.refreshed = Date()
                apps[appID]?.detailed = true
            } catch {
                if !isCancellation(error) { apps[appID]?.error = playMessage(error, team: team) }
            }
            return
        }
        guard let c = try? client(forApp: appID) else { return }
        apps[appID, default: AppState()].loading = true
        defer { apps[appID]?.loading = false }
        do {
            async let builds = c.builds(appID: appID, limit: 40)
            async let groups = c.betaGroups(appID: appID)
            async let versions = c.versions(appID: appID)
            let (b, g, v) = try await (builds, groups, versions)
            apps[appID]?.builds = b
            apps[appID]?.groups = g
            apps[appID]?.versions = v
            apps[appID]?.error = nil
            apps[appID]?.refreshed = Date()
            apps[appID]?.detailed = true
        } catch {
            if !isCancellation(error) { apps[appID]?.error = error.localizedDescription }
        }
    }

    /// A page that went away cancels its loads; that is not an error to show.
    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let e = error as? URLError, e.code == .cancelled { return true }
        if let e = error as? ReleaseError, case .cancelled = e { return true }
        return false
    }

    // MARK: - Accounts

    /// Checks a key against App Store Connect without saving anything.
    func verifyApple(keyID: String, issuerID: String, pem: String) async throws -> (teamID: String?, apps: [ASCApp]) {
        let c = ASCClient(key: try ASCKey(keyID: keyID, issuerID: issuerID, pem: pem))
        let apps = try await c.apps()
        let team = try? await c.teamID()
        return (team, apps)
    }

    func connectApple(accountID: UUID?, newAccountName: String, email: String?, teamName: String, teamID: String?,
                      keyID: String, issuerID: String, pem: String) throws {
        let credential = Credential.appStoreConnectKey(keyID: keyID, issuerID: issuerID)
        try Keychain.save(pem, account: credential.secretAccount)
        let team = Team(name: teamName, teamID: teamID, credential: credential)
        add(team, provider: .apple, accountID: accountID, newAccountName: newAccountName, email: email)
    }

    func remove(team: Team) {
        // Its apps' project links go too, unless another team shows the same app.
        let ids = Set(teams[team.id]?.apps.map(\.id) ?? [])
        workspace.links.removeAll { ids.contains($0.appID) }
        for id in ids { apps[id] = nil; appTeam[id] = nil }
        Keychain.delete(account: team.credential.secretAccount)
        clients[team.id] = nil
        playClients[team.id] = nil
        agcClients[team.id] = nil
        msClients[team.id] = nil
        teams[team.id] = nil
        for i in workspace.accounts.indices { workspace.accounts[i].teams.removeAll { $0.id == team.id } }
        workspace.accounts.removeAll { $0.teams.isEmpty }
        save()
        route = .overview
    }

    func rename(team: Team, to name: String) {
        for i in workspace.accounts.indices {
            if let j = workspace.accounts[i].teams.firstIndex(where: { $0.id == team.id }) { workspace.accounts[i].teams[j].name = name }
        }
        save()
    }

    // MARK: - Projects and runs

    /// Links a store app to its source folder, and the same app on the other
    /// store (same bundle id / package) when it has no folder yet.
    func link(appID: String, path: String) {
        func set(_ id: String) {
            if let i = workspace.links.firstIndex(where: { $0.appID == id }) {
                workspace.links[i].path = path
            } else {
                workspace.links.append(ProjectLink(appID: id, path: path))
            }
        }
        set(appID)
        if let app = app(appID), let p = try? FlutterProject.inspect(URL(fileURLWithPath: path)) {
            let ids = Set([p.iosBundleID, p.androidPackage].compactMap { $0 })
            for twin in allApps where twin.id != appID && ids.contains(twin.bundleID) && twin.store != app.store
                && workspace.link(for: twin.id) == nil {
                set(twin.id)
            }
        }
        save()
    }

    func updateRecipe(appID: String, _ change: (inout IOSRecipe) -> Void) {
        guard let i = workspace.links.firstIndex(where: { $0.appID == appID }) else { return }
        change(&workspace.links[i].recipe)
        save()
    }

    func launch(_ plan: ReleasePlan) throws -> ReleaseRun {
        let run: ReleaseRun
        if plan.platform == .windows {
            guard let team = team(ofApp: plan.app.id) else { throw ReleaseError.precondition("No Partner Center account for this app") }
            run = ReleaseRun(plan: plan, microsoft: try msClient(for: team), github: github)
        } else if plan.platform == .android {
            let pkg = plan.app.bundleID
            let playTeam = plan.play == nil ? nil : team(ofApp: "play:\(pkg)")
            let agcTeam = plan.appGallery == nil ? nil : team(ofApp: "agc:\(pkg)")
            if plan.play != nil, playTeam == nil { throw ReleaseError.precondition("No Google Play account for \(pkg)") }
            if plan.appGallery != nil, agcTeam == nil { throw ReleaseError.precondition("No AppGallery account for \(pkg)") }
            run = ReleaseRun(plan: plan, play: try playTeam.map { try playClient(for: $0) }, appGallery: try agcTeam.map { try agcClient(for: $0) },
                             github: plan.cloud != nil ? github : nil)
        } else {
            run = ReleaseRun(plan: plan, apple: try client(forApp: plan.app.id), github: plan.cloud != nil ? github : nil)
        }
        run.onFinish = { [weak self] r in self?.finished(r) }
        runs.append(run)
        run.start()
        updateDock()
        return run
    }

    /// Puts the team's App Store Connect key into the repository's Actions
    /// secrets, so the cloud workflow can sign and upload.
    func setCloudSecrets(appID: String, repo: GitHubRepo, target: CloudTarget = .ios, projectRoot: URL? = nil) async throws {
        if target == .windows {
            guard let team = team(ofApp: appID), case .partnerCenter(let tenant, let clientID, let seller) = team.credential else {
                throw ReleaseError.precondition("This app has no Partner Center account")
            }
            let secret = try Keychain.read(account: team.credential.secretAccount)
            try await github.setSecret("MS_TENANT_ID", value: tenant, repo: repo)
            try await github.setSecret("MS_SELLER_ID", value: seller, repo: repo)
            try await github.setSecret("MS_CLIENT_ID", value: clientID, repo: repo)
            try await github.setSecret("MS_CLIENT_SECRET", value: secret, repo: repo)
            return
        }
        if target == .android {
            // The upload key from android/key.properties, as the workflow expects it.
            guard let root = projectRoot else { throw ReleaseError.precondition("No project folder") }
            let android = root.appendingPathComponent("android")
            guard let text = try? String(contentsOf: android.appendingPathComponent("key.properties"), encoding: .utf8) else {
                throw ReleaseError.precondition("This project has no android/key.properties with its upload key.")
            }
            var props: [String: String] = [:]
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, !parts[0].hasPrefix("#") { props[parts[0]] = parts[1] }
            }
            guard let store = props["storeFile"], let storePass = props["storePassword"], let alias = props["keyAlias"],
                  let keyPass = props["keyPassword"] else {
                throw ReleaseError.precondition("android/key.properties needs storeFile, storePassword, keyAlias and keyPassword.")
            }
            // Gradle resolves a relative storeFile from android/app.
            let expanded = NSString(string: store).expandingTildeInPath
            let file = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : android.appendingPathComponent("app").appendingPathComponent(expanded)
            guard let keystore = try? Data(contentsOf: file) else { throw ReleaseError.precondition("Cannot read the keystore at \(file.path)") }
            try await github.setSecret("ANDROID_KEYSTORE_BASE64", value: keystore.base64EncodedString(), repo: repo)
            try await github.setSecret("ANDROID_KEYSTORE_PASSWORD", value: storePass, repo: repo)
            try await github.setSecret("ANDROID_KEY_ALIAS", value: alias, repo: repo)
            try await github.setSecret("ANDROID_KEY_PASSWORD", value: keyPass, repo: repo)
            return
        }
        guard let team = team(ofApp: appID), case .appStoreConnectKey(let keyID, let issuer) = team.credential else {
            throw ReleaseError.precondition("This app has no App Store Connect key")
        }
        let pem = try Keychain.read(account: team.credential.secretAccount)
        try await github.setSecret("ASC_KEY_ID", value: keyID, repo: repo)
        try await github.setSecret("ASC_ISSUER_ID", value: issuer, repo: repo)
        try await github.setSecret("ASC_PRIVATE_KEY", value: pem, repo: repo)
    }

    /// Runs a failed iOS release again from Apple processing (the upload is
    /// done), or a failed Android release from the start.
    func resume(_ run: ReleaseRun) throws -> ReleaseRun {
        var plan = run.plan
        let uploaded = run.plan.platform == .ios && run.step(.upload).state == .done
        plan.startAt = uploaded ? .processing : nil
        return try launch(plan)
    }

    private func finished(_ run: ReleaseRun) {
        let failed = run.steps.first { if case .failed = $0.state { true } else { false } }
        workspace.runs.insert(RunRecord(id: run.id, appID: run.plan.app.id, appName: run.plan.app.name, version: run.plan.version,
                                        build: run.plan.build, started: run.started ?? Date(), finished: run.finished,
                                        outcome: run.plan.rehearsal && run.phase == .succeeded ? "rehearsed" : "\(run.phase)",
                                        failedStep: failed?.id.title, logPath: run.logFile.path), at: 0)
        if workspace.runs.count > 200 { workspace.runs.removeLast(workspace.runs.count - 200) }
        save()
        updateDock()
        notify(run)
        Task { await refresh(appID: run.plan.app.id) }
    }

    func updateDock() {
        let n = runningCount
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    private func notify(_ run: ReleaseRun) {
        let content = UNMutableNotificationContent()
        let name = "\(run.plan.app.name) \(run.plan.version) (\(run.plan.build))"
        switch run.phase {
        case .succeeded:
            content.title = run.plan.rehearsal ? "Rehearsal passed" : "Shipped \(name)"
            content.body = run.plan.rehearsal ? "\(name) built and signed." : run.plan.platform == .windows
                ? "It is in Microsoft Store certification." : (run.plan.platform == .android
                ? [run.plan.play.map { "It is on Google Play, \($0.track) track." }, run.plan.appGallery.map { _ in "AppGallery is reviewing it." }]
                    .compactMap { $0 }.joined(separator: " ")
                : "It is on TestFlight for \(run.plan.groups.map(\.name).joined(separator: ", ")).")
        case .failed:
            content.title = "\(name) stopped"
            content.body = run.failure ?? "A step failed."
        default:
            content.title = "\(name) cancelled"
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: run.id.uuidString, content: content, trigger: nil))
    }

    func save() {
        do { try WorkspaceStore.save(workspace) } catch { alert = "Could not save: \(error.localizedDescription)" }
    }
}

extension String {
    var isPlay: Bool { hasPrefix("play:") }
    var playPackage: String { String(dropFirst(5)) }
}

extension ASCApp {
    var isPlay: Bool { id.isPlay }
    var store: StoreProvider { StoreProvider.of(appID: id) }
}

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
    var workspace: Workspace
    var route: Route? = .overview
    var teams: [UUID: TeamState] = [:]
    var apps: [String: AppState] = [:]
    var runs: [ReleaseRun] = []
    var connecting: StoreProvider?
    var alert: String?

    @ObservationIgnored private var clients: [UUID: ASCClient] = [:]
    @ObservationIgnored private var appTeam: [String: UUID] = [:]
    /// Icon templates remembered between launches so the sidebar has icons at once.
    private var icons: [String: String] = UserDefaults.standard.dictionary(forKey: "icons") as? [String: String] ?? [:]

    init() {
        workspace = WorkspaceStore.load()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Lookups

    var appleTeams: [(account: Account, team: Team)] {
        workspace.accounts.filter { $0.provider == .apple }.flatMap { a in a.teams.map { (a, $0) } }
    }

    func app(_ id: String) -> ASCApp? {
        for s in teams.values { if let a = s.apps.first(where: { $0.id == id }) { return a } }
        return nil
    }

    func team(ofApp id: String) -> Team? {
        appTeam[id].flatMap { workspace.team($0)?.1 }
    }

    func iconURL(_ appID: String, size: Int = 256) -> URL? {
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

    func client(forApp id: String) throws -> ASCClient {
        guard let t = team(ofApp: id) else { throw ReleaseError.precondition("No team for this app") }
        return try client(for: t)
    }

    // MARK: - Loading

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { g in
            for (_, team) in appleTeams { g.addTask { await self.refresh(team: team) } }
        }
    }

    func refresh(team: Team) async {
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

    func refresh(appID: String) async {
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
            apps[appID]?.error = error.localizedDescription
        }
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
        if let accountID, let i = workspace.accounts.firstIndex(where: { $0.id == accountID }) {
            workspace.accounts[i].teams.append(team)
        } else {
            var a = Account(provider: .apple, name: newAccountName, email: email)
            a.teams = [team]
            workspace.accounts.append(a)
        }
        save()
        route = .team(team.id)
        Task { await refresh(team: team) }
    }

    func remove(team: Team) {
        Keychain.delete(account: team.credential.secretAccount)
        clients[team.id] = nil
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

    func link(appID: String, path: String) {
        if let i = workspace.links.firstIndex(where: { $0.appID == appID }) {
            workspace.links[i].path = path
        } else {
            workspace.links.append(ProjectLink(appID: appID, path: path))
        }
        save()
    }

    func updateRecipe(appID: String, _ change: (inout IOSRecipe) -> Void) {
        guard let i = workspace.links.firstIndex(where: { $0.appID == appID }) else { return }
        change(&workspace.links[i].recipe)
        save()
    }

    func launch(_ plan: ReleasePlan) throws -> ReleaseRun {
        let run = ReleaseRun(plan: plan, client: try client(forApp: plan.app.id))
        run.onFinish = { [weak self] r in self?.finished(r) }
        runs.append(run)
        run.start()
        updateDock()
        return run
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
            content.body = run.plan.rehearsal ? "\(name) archived, signed and exported." : "It is on TestFlight for \(run.plan.groups.map(\.name).joined(separator: ", "))."
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

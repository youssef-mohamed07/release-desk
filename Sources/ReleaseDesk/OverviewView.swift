import ReleaseKit
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        if model.workspace.accounts.isEmpty {
            WelcomeView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if !model.runs.filter({ $0.phase == .running }).isEmpty { inFlight }
                    ForEach(model.appleTeams, id: \.team.id) { pair in
                        teamGrid(pair.account, pair.team)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 26)
            }
            .background(alignment: .top) { AmbientGlow(url: nil).frame(height: 420) }
            .searchable(text: $query, placement: .toolbar, prompt: "Find an app or bundle id")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.refreshAll() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
            }
            .navigationTitle("")
        }
    }

    private var header: some View {
        let appsCount = model.teams.values.reduce(0) { $0 + $1.apps.count }
        let teamCount = model.appleTeams.count
        let testing = model.apps.values.filter { $0.builds.first?.externalState == "IN_BETA_TESTING" || $0.builds.first?.internalState == "IN_BETA_TESTING" }.count
        return VStack(alignment: .leading, spacing: 6) {
            Text(greeting).font(.system(size: 30, weight: .bold, design: .rounded))
            HStack(spacing: 14) {
                Stat(value: "\(appsCount)", label: "apps")
                Stat(value: "\(teamCount)", label: teamCount == 1 ? "team" : "teams")
                Stat(value: "\(testing)", label: "on TestFlight")
                if model.runningCount > 0 { Stat(value: "\(model.runningCount)", label: "shipping now", tint: Palette.cyan) }
            }
        }
    }

    private var greeting: String {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")
        return first.isEmpty ? part : "\(part), \(first)"
    }

    private var inFlight: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Shipping now", symbol: "paperplane.fill")
            ForEach(model.runs.filter { $0.phase == .running }) { run in
                Button { model.route = .ship(run.plan.app.id) } label: {
                    MiniRun(run: run).card(radius: 14, padding: 12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func teamGrid(_ account: Account, _ team: Team) -> some View {
        let state = model.teams[team.id]
        let apps = (state?.apps ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ProviderMark(provider: account.provider, size: 15)
                Text(team.name).font(.title3.weight(.semibold))
                if let id = team.teamID { Text(id).font(.callout.monospaced()).foregroundStyle(.secondary) }
                Text("· \(account.name)").font(.callout).foregroundStyle(.tertiary)
                Spacer()
                if state?.loading == true { ProgressView().controlSize(.small) }
            }
            if let error = state?.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 400), spacing: 14)], spacing: 14) {
                ForEach(apps) { app in
                    AppCard(app: app)
                }
            }
        }
    }
}

struct Stat: View {
    let value: String
    let label: String
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label).foregroundStyle(.secondary)
        }
    }
}

struct AppCard: View {
    let app: ASCApp
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        let latest = model.apps[app.id]?.builds.first
        Button { model.route = .app(app.id) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    AppIcon(url: model.iconURL(app.id), name: app.name, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.headline).lineLimit(1)
                        Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let run = model.activeRun(for: app.id) {
                        Image(systemName: "paperplane.fill").foregroundStyle(Palette.cyan).symbolEffect(.pulse, options: .repeating)
                            .help("Shipping \(run.plan.version) (\(run.plan.build))")
                    }
                }
                if let latest {
                    HStack(alignment: .center) {
                        Text("\(latest.version) (\(latest.number))").font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                        Spacer()
                        Text(latest.uploaded?.relative ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    BuildLane(build: latest)
                } else {
                    HStack {
                        Text(model.teams.values.contains { $0.loading } ? "Loading builds…" : "No builds yet")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    BuildLane(build: nil)
                }
            }
            .card(radius: 18, padding: 16)
            .background(alignment: .topLeading) {
                AmbientGlow(url: model.iconURL(app.id, size: 64), intensity: hover ? 0.5 : 0.28)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .scaleEffect(hover ? 1.012 : 1)
            .animation(.spring(duration: 0.25), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Five lights for the road a build takes: upload, processing, internal
/// testers, beta review, external testers.
struct BuildLane: View {
    let build: ASCBuild?
    var labels = true

    static let stages = ["Uploaded", "Processed", "Internal", "Review", "External"]

    var body: some View {
        let lit = stagesLit
        HStack(spacing: 0) {
            ForEach(Array(Self.stages.enumerated()), id: \.offset) { i, stage in
                VStack(spacing: 5) {
                    ZStack {
                        if lit[i] == .active {
                            Circle().stroke(lit[i].color.opacity(0.45), lineWidth: 2).frame(width: 15, height: 15)
                        }
                        Circle().fill(lit[i] == .muted ? Color.secondary.opacity(0.22) : lit[i].color).frame(width: 9, height: 9)
                            .shadow(color: lit[i] == .muted ? .clear : lit[i].color.opacity(0.6), radius: 3)
                    }
                    .frame(height: 15)
                    if labels {
                        Text(stage).font(.system(size: 9.5, weight: .medium)).foregroundStyle(lit[i] == .muted ? .tertiary : .secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(alignment: .top) {
            GeometryReader { g in
                let w = g.size.width / CGFloat(Self.stages.count)
                ForEach(0..<(Self.stages.count - 1), id: \.self) { i in
                    Capsule()
                        .fill(lit[i + 1] == .muted ? Color.secondary.opacity(0.18) : lit[i + 1].color.opacity(0.55))
                        .frame(width: max(0, w - 18), height: 1.5)
                        .position(x: w * CGFloat(i + 1), y: 7.5)
                }
            }
        }
    }

    private var stagesLit: [StateTone] {
        guard let b = build else { return Array(repeating: .muted, count: 5) }
        var s: [StateTone] = [.good, .muted, .muted, .muted, .muted]
        switch b.processingState {
        case "VALID": s[1] = .good
        case "PROCESSING": s[1] = .active
        case "FAILED", "INVALID": s[1] = .bad
        default: break
        }
        if b.expired { return s.map { $0 == .good ? .muted : $0 } }
        switch b.internalState {
        case "IN_BETA_TESTING": s[2] = .good
        case "PROCESSING", "READY_FOR_BETA_TESTING": s[2] = .active
        case "MISSING_EXPORT_COMPLIANCE": s[2] = .waiting
        default: break
        }
        switch b.reviewState ?? b.externalState {
        case "APPROVED", "BETA_APPROVED", "IN_BETA_TESTING": s[3] = .good
        case "WAITING_FOR_REVIEW", "IN_REVIEW", "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW": s[3] = .active
        case "REJECTED", "BETA_REJECTED": s[3] = .bad
        case "READY_FOR_BETA_SUBMISSION": s[3] = .waiting
        default: break
        }
        if b.externalState == "IN_BETA_TESTING" { s[4] = .good }
        return s
    }
}

struct TeamView: View {
    let teamID: UUID
    @Environment(AppModel.self) private var model

    var body: some View {
        if let (account, team) = model.workspace.team(teamID) {
            let state = model.teams[team.id]
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary)
                            ProviderMark(provider: account.provider, size: 26)
                        }
                        .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(team.name).font(.system(size: 26, weight: .bold, design: .rounded))
                            Text([team.teamID.map { "Team \($0)" }, team.credential.summary, account.name].compactMap { $0 }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await model.refresh(team: team) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .buttonStyle(.glass)
                            .disabled(state?.loading == true)
                    }
                    if let e = state?.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 400), spacing: 14)], spacing: 14) {
                        ForEach(state?.apps ?? []) { AppCard(app: $0) }
                    }
                }
                .padding(32)
            }
            .background(alignment: .top) { AmbientGlow(url: nil).frame(height: 380) }
        } else {
            ContentUnavailableView("Team not found", systemImage: "questionmark.folder")
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var appear = false

    var body: some View {
        ZStack {
            AnimatedMesh(palette: .idle).ignoresSafeArea()
            VStack(spacing: 30) {
                BrandGlyph(size: 92)
                    .scaleEffect(appear ? 1 : 0.8)
                    .opacity(appear ? 1 : 0)
                VStack(spacing: 10) {
                    Text("Every release, one desk.")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("Connect your store accounts. Release Desk keeps each team apart, shows every app, build and tester group, and ships updates from archive to testers' phones.")
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 620)
                }
                HStack(spacing: 18) {
                    ProviderTile(title: "App Store Connect", subtitle: "API key (.p8) per team", symbol: "apple.logo", enabled: true) {
                        model.connecting = .apple
                    }
                    ProviderTile(title: "Google Play", subtitle: "Service account per developer account", symbol: nil, enabled: false) {}
                }
                Text("Keys go to your Keychain. Nothing leaves this Mac except calls to Apple and Google.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            .padding(40)
        }
        .environment(\.colorScheme, .dark)
        .onAppear { withAnimation(.spring(duration: 0.8, bounce: 0.35)) { appear = true } }
    }
}

struct ProviderTile: View {
    let title: String
    let subtitle: String
    let symbol: String?
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    if let symbol { Image(systemName: symbol).font(.system(size: 26)) } else { PlayMark(size: 28) }
                    Spacer()
                    if !enabled {
                        Text("Coming next").font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: .capsule)
                    } else {
                        Image(systemName: "arrow.right").font(.headline).opacity(hover ? 1 : 0.4)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(width: 270, alignment: .leading)
            .padding(20)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
            .scaleEffect(hover && enabled ? 1.03 : 1)
            .animation(.spring(duration: 0.3), value: hover)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.6)
        .onHover { hover = $0 }
    }
}

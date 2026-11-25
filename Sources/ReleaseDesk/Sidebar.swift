import ReleaseKit
import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var collapsed: Set<UUID> = []
    @State private var confirmRemove: Team?

    var body: some View {
        // The ship page belongs to its app's row; nil writes (a row that is
        // not on screen) are ignored so the page never jumps by itself.
        let selection = Binding<Route?>(
            get: {
                if case .ship(let id) = model.route { return .app(id) }
                return model.route
            },
            set: { new in
                guard let new else { return }
                if case .app(let id) = new, case .ship(let current) = model.route, current == id { return }
                model.route = new
            })
        List(selection: selection) {
            Section {
                Label("Overview", systemImage: "square.grid.2x2").tag(Route.overview)
                Label {
                    HStack {
                        Text("Activity")
                        Spacer()
                        if model.runningCount > 0 {
                            Text("\(model.runningCount)").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Palette.cyan.opacity(0.25), in: .capsule)
                        }
                    }
                } icon: { Image(systemName: "waveform.path.ecg") }
                .tag(Route.activity)
            }

            ForEach(model.workspace.accounts) { account in
                Section {
                    ForEach(account.teams) { team in
                        teamRow(team)
                    }
                } header: {
                    HStack(spacing: 6) {
                        ProviderMark(provider: account.provider, size: 11)
                        Text(account.name)
                        if let email = account.email { Text(email).foregroundStyle(.tertiary) }
                    }
                }
            }

            Section("Connect") {
                Button { model.connecting = .apple } label: {
                    Label { Text("App Store Connect") } icon: { Image(systemName: "apple.logo") }
                }
                .buttonStyle(.plain)
                Label {
                    HStack {
                        Text("Google Play")
                        Spacer()
                        Text("Next").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: .capsule)
                    }
                } icon: { PlayMark(size: 14) }
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 10) {
                BrandGlyph(size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Release Desk").font(.headline)
                    Text("Apple · Google Play").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
        .confirmationDialog("Remove \(confirmRemove?.name ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove team and its key", role: .destructive) {
                if let t = confirmRemove { model.remove(team: t) }
            }
        } message: {
            Text("Release Desk forgets this team and deletes its API key from your Keychain. The key stays valid in App Store Connect.")
        }
    }

    @ViewBuilder
    private func teamRow(_ team: Team) -> some View {
        let state = model.teams[team.id]
        DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(team.id) }, set: { if $0 { collapsed.remove(team.id) } else { collapsed.insert(team.id) } })) {
            ForEach(state?.apps ?? []) { app in
                HStack(spacing: 8) {
                    AppIcon(url: model.iconURL(app.id, size: 64), name: app.name, size: 18)
                    Text(app.name).lineLimit(1)
                    Spacer(minLength: 4)
                    if model.activeRun(for: app.id) != nil {
                        Image(systemName: "paperplane.fill").font(.caption2).foregroundStyle(Palette.cyan)
                            .symbolEffect(.pulse, options: .repeating)
                    } else if let b = model.apps[app.id]?.builds.first {
                        Circle().fill(describeState(b.externalState ?? b.processingState).tone.color).frame(width: 6, height: 6)
                    }
                }
                .tag(Route.app(app.id))
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.2.crop.square.stack").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(team.name).lineLimit(1)
                    Text([team.teamID, state.map { "\($0.apps.count) apps" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if state?.loading == true { ProgressView().controlSize(.mini) }
                if state?.error != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
            }
            .tag(Route.team(team.id))
            .contextMenu {
                Button("Refresh") { Task { await model.refresh(team: team) } }
                Button("Remove…", role: .destructive) { confirmRemove = team }
            }
        }
    }
}

/// The Release Desk mark: a paper plane leaving a trail through a gradient tile.
struct BrandGlyph: View {
    var size: CGFloat = 28
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(MeshGradient(width: 2, height: 2, points: [[0, 0], [1, 0], [0, 1], [1, 1]],
                                   colors: [Palette.indigo, Palette.violet, Palette.cyan, Palette.indigo]))
            Image(systemName: "paperplane.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(-8))
                .offset(x: size * 0.03, y: -size * 0.02)
        }
        .frame(width: size, height: size)
        .shadow(color: Palette.violet.opacity(0.45), radius: size * 0.2, y: size * 0.08)
    }
}

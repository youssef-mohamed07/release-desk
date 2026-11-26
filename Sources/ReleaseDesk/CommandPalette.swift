import ReleaseKit
import SwiftUI

/// ⌘K: type a few letters of an app or an action and press return.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String?
        let appID: String?
        let provider: StoreProvider?
        let run: @MainActor (AppModel) -> Void
    }

    private var items: [Item] {
        var all: [Item] = []
        for (account, team) in model.allTeams {
            for app in model.teams[team.id]?.apps ?? [] {
                let store = account.provider == .apple ? "App Store" : account.provider.title
                all.append(Item(id: "ship-\(app.id)", title: "Ship \(app.name)", subtitle: "\(store) · \(team.name)", symbol: nil,
                                appID: app.id, provider: account.provider) { $0.route = .ship(app.id) })
                all.append(Item(id: "open-\(app.id)", title: app.name, subtitle: "\(app.bundleID) · \(store) · \(team.name)", symbol: nil,
                                appID: app.id, provider: account.provider) { $0.route = .app(app.id) })
            }
            all.append(Item(id: "team-\(team.id)", title: team.name, subtitle: "\(account.name) · \(team.teamID ?? "")", symbol: "person.2",
                            appID: nil, provider: account.provider) { $0.route = .team(team.id) })
        }
        all += [
            Item(id: "overview", title: "Overview", subtitle: "Every app on every team", symbol: "square.grid.2x2", appID: nil, provider: nil) { $0.route = .overview },
            Item(id: "activity", title: "Activity", subtitle: "Releases and their logs", symbol: "waveform.path.ecg", appID: nil, provider: nil) { $0.route = .activity },
            Item(id: "new-app", title: "New app", subtitle: "Bundle id, store records, groups and upload key", symbol: "sparkles", appID: nil, provider: nil) { $0.newApp = true },
            Item(id: "connect-apple", title: "Connect App Store Connect", subtitle: "Add a team with its API key", symbol: "apple.logo", appID: nil, provider: nil) { $0.connecting = .apple },
            Item(id: "connect-google", title: "Connect Google Play", subtitle: "Sign in with Google, or use a service account", symbol: "play.fill", appID: nil, provider: nil) { $0.connecting = .google },
            Item(id: "connect-huawei", title: "Connect AppGallery", subtitle: "Add a Huawei team with its API client", symbol: "bag.fill", appID: nil, provider: nil) { $0.connecting = .huawei },
            Item(id: "connect-microsoft", title: "Connect Microsoft Store", subtitle: "Add a Partner Center account", symbol: "storefront", appID: nil, provider: nil) { $0.connecting = .microsoft },
            Item(id: "refresh", title: "Refresh everything", subtitle: "Ask both stores again", symbol: "arrow.clockwise", appID: nil, provider: nil) { m in Task { await m.refreshAll() } },
        ]
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else {
            // Nothing typed: apps first, then the places.
            return all.filter { !$0.id.hasPrefix("ship-") }
        }
        return all
            .filter { item in words.allSatisfy { w in (item.title + " " + item.subtitle).lowercased().contains(w) } }
            .sorted { score($0, words) > score($1, words) }
    }

    private func score(_ item: Item, _ words: [String]) -> Int {
        let t = item.title.lowercased()
        var s = 0
        if t.hasPrefix(words[0]) { s += 4 }
        if words.first == "ship", item.id.hasPrefix("ship-") { s += 6 }
        if item.appID != nil { s += 1 }
        return s
    }

    var body: some View {
        let list = items
        ZStack(alignment: .top) {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { model.palette = false }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                    TextField("Ship, open, connect…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .medium))
                        .focused($focused)
                        .onSubmit { pick(list) }
                        .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, list.count - 1)); return .handled }
                        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                        .onKeyPress(.escape) { model.palette = false; return .handled }
                    Text("esc").font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
                .padding(18)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(list.prefix(60).enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == selection)
                                    .id(i)
                                    .onTapGesture { selection = i; pick(list) }
                            }
                            if list.isEmpty {
                                Text("Nothing matches “\(query)”").foregroundStyle(.secondary).padding(24)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: min(CGFloat(max(list.count, 1)) * 46 + 16, 380))
                    .onChange(of: selection) { proxy.scrollTo(selection, anchor: .center) }
                }
            }
            .frame(width: 640)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
            .padding(.top, 90)
        }
        .onAppear { focused = true; selection = 0 }
        .onChange(of: query) { selection = 0 }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 12) {
            if let appID = item.appID, let app = model.app(appID) {
                AppIcon(url: model.iconURL(appID, size: 64), name: app.name, size: 28).sensitive(6)
                    .overlay(alignment: .bottomTrailing) {
                        if item.id.hasPrefix("ship-") {
                            Image(systemName: "paperplane.circle.fill").font(.system(size: 13)).foregroundStyle(.white, Palette.indigo).offset(x: 4, y: 4)
                        }
                    }
            } else {
                Image(systemName: item.symbol ?? "circle").frame(width: 28, height: 28)
                    .background(.quaternary, in: .rect(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.body.weight(.medium)).sensitive(item.appID != nil || item.id.hasPrefix("team-") ? 5 : 0)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .sensitive(item.appID != nil || item.id.hasPrefix("team-") ? 4 : 0)
            }
            Spacer()
            if let p = item.provider { ProviderMark(provider: p, size: 12).foregroundStyle(.secondary) }
            if selected { Image(systemName: "return").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Palette.indigo.opacity(0.18) : .clear, in: .rect(cornerRadius: 10))
        .contentShape(.rect)
    }

    private func pick(_ list: [Item]) {
        guard list.indices.contains(selection) else { return }
        let item = list[selection]
        model.palette = false
        query = ""
        item.run(model)
    }
}

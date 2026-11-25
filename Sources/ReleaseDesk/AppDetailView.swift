import AppKit
import ReleaseKit
import SwiftUI

struct AppDetailView: View {
    let appID: String
    @Environment(AppModel.self) private var model
    @State private var selectedBuild: ASCBuild?

    var body: some View {
        if let app = model.app(appID) {
            let state = model.apps[appID] ?? AppState()
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    hero(app, state)
                    if let e = state.error {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    buildsSection(state)
                    groupsSection(state)
                    versionsSection(state)
                }
                .padding(.horizontal, 34)
                .padding(.top, 30)
                .padding(.bottom, 40)
            }
            .background(alignment: .top) { AmbientGlow(url: model.iconURL(appID), intensity: 0.6).frame(height: 520) }
            .task(id: appID) { await model.refresh(appID: appID) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.refresh(appID: appID) } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            .sheet(item: $selectedBuild) { b in BuildSheet(app: app, build: b, groups: state.groups) }
        } else {
            ContentUnavailableView("Loading app…", systemImage: "app.dashed")
        }
    }

    private func hero(_ app: ASCApp, _ state: AppState) -> some View {
        let team = model.team(ofApp: appID)
        let link = model.workspace.link(for: appID)
        let run = model.activeRun(for: appID)
        return HStack(alignment: .center, spacing: 22) {
            AppIcon(url: model.iconURL(appID, size: 512), name: app.name, size: 104)
            VStack(alignment: .leading, spacing: 8) {
                Text(app.name).font(.system(size: 34, weight: .bold, design: .rounded))
                HStack(spacing: 10) {
                    Chip(text: app.bundleID, symbol: "shippingbox", mono: true)
                    if let team { Chip(text: team.name, symbol: "person.2") }
                    Chip(text: app.primaryLocale, symbol: "globe")
                    if let link { Chip(text: (link.path as NSString).abbreviatingWithTildeInPath, symbol: "folder", mono: true) }
                }
                if let latest = state.builds.first {
                    HStack(spacing: 8) {
                        Text("Latest").foregroundStyle(.secondary)
                        Text("\(latest.version) (\(latest.number))").font(.body.weight(.semibold).monospacedDigit())
                        StatePill(raw: latest.externalState ?? latest.processingState)
                        if let up = latest.uploaded { Text(up.relative).foregroundStyle(.secondary) }
                    }
                    .font(.callout)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                Button {
                    model.route = .ship(appID)
                } label: {
                    Label(run != nil ? "Shipping \(run!.plan.version) (\(run!.plan.build))…" : "Ship an update", systemImage: "paperplane.fill")
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.indigo)
                .controlSize(.extraLarge)
                Link(destination: URL(string: "https://appstoreconnect.apple.com/apps/\(appID)/testflight/ios")!) {
                    Label("Open in App Store Connect", systemImage: "arrow.up.right.square").font(.callout)
                }
            }
        }
    }

    private func buildsSection(_ state: AppState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Builds", subtitle: state.builds.isEmpty ? nil : "\(state.builds.count) most recent", symbol: "shippingbox")
            if state.builds.isEmpty {
                Text(state.loading ? "Loading…" : "No builds uploaded yet.").foregroundStyle(.secondary).card()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(state.builds) { b in
                            BuildTicket(build: b, groups: state.groups, latest: b.id == state.builds.first?.id)
                                .onTapGesture { selectedBuild = b }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
                .scrollClipDisabled()
            }
        }
    }

    private func groupsSection(_ state: AppState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "TestFlight groups", subtitle: state.groups.isEmpty ? nil : "\(state.groups.count)", symbol: "person.3")
            if state.groups.isEmpty {
                Text(state.loading ? "Loading…" : "No tester groups yet.").foregroundStyle(.secondary).card()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(state.groups) { g in GroupCard(group: g, builds: state.builds) }
                }
            }
        }
    }

    private func versionsSection(_ state: AppState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "App Store versions", symbol: "bag")
            if state.versions.isEmpty {
                Text(state.loading ? "Loading…" : "No App Store versions yet.").foregroundStyle(.secondary).card()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(state.versions.enumerated()), id: \.element.id) { i, v in
                        HStack {
                            Text(v.version).font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                                .frame(width: 90, alignment: .leading)
                            Text(v.platform == "IOS" ? "iOS" : v.platform).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                            StatePill(raw: v.state)
                            Spacer()
                            if let c = v.created { Text("Created \(c.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(.secondary).font(.callout) }
                        }
                        .padding(.vertical, 10)
                        if i < state.versions.count - 1 { Divider() }
                    }
                }
                .card(padding: 14)
                Text("Submitting a version for App Review is the next slice: Release Desk will check screenshots, the privacy answers and the build before it sends anything.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

struct Chip: View {
    let text: String
    var symbol: String? = nil
    var mono = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.caption2) }
            Text(text).font(mono ? .caption.monospaced() : .caption).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

/// One build as a ticket stub: the build number big, its road below.
struct BuildTicket: View {
    let build: ASCBuild
    let groups: [ASCBetaGroup]
    var latest = false
    @State private var hover = false

    var body: some View {
        let tone = describeState(build.expired ? "EXPIRED" : (build.externalState ?? build.processingState)).tone
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(build.number)
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(latest ? AnyShapeStyle(LinearGradient(colors: [.primary, tone.color], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(.primary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(build.version).font(.callout.weight(.semibold).monospacedDigit())
                    Text(build.uploaded?.formatted(.dateTime.day().month(.abbreviated)) ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if latest { Text("LATEST").font(.system(size: 9, weight: .heavy)).kerning(0.8).foregroundStyle(tone.color) }
            }
            BuildLane(build: build)
            HStack(spacing: 6) {
                let names = build.groupIDs.compactMap { id in groups.first { $0.id == id }?.name }
                Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(.secondary)
                Text(names.isEmpty ? "No groups" : names.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let exp = build.expires, !build.expired {
                    Text("\(max(0, Calendar.current.dateComponents([.day], from: Date(), to: exp).day ?? 0))d left")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 280)
        .card(radius: 18, padding: 16)
        .overlay(alignment: .leading) {
            Capsule().fill(tone.color).frame(width: 3).padding(.vertical, 18).offset(x: 1)
        }
        .scaleEffect(hover ? 1.02 : 1)
        .animation(.spring(duration: 0.25), value: hover)
        .onHover { hover = $0 }
        .contentShape(.rect)
        .opacity(build.expired ? 0.55 : 1)
    }
}

struct GroupCard: View {
    let group: ASCBetaGroup
    let builds: [ASCBuild]
    @State private var copied = false

    var body: some View {
        let latestInGroup = builds.first { $0.groupIDs.contains(group.id) } ?? (group.allBuilds ? builds.first : nil)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(group.isInternal ? Palette.indigo.opacity(0.18) : Palette.mint.opacity(0.18))
                    Image(systemName: group.isInternal ? "building.2" : "globe").foregroundStyle(group.isInternal ? Palette.indigo : Palette.mint)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name).font(.headline)
                    Text(group.isInternal ? (group.allBuilds ? "Internal · every build" : "Internal") : "External · needs beta review")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(group.testerCount.map(String.init) ?? "–").font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                    Text("testers").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let b = latestInGroup {
                HStack {
                    Text("Now testing").foregroundStyle(.secondary)
                    Text("\(b.version) (\(b.number))").fontWeight(.semibold).monospacedDigit()
                    Spacer()
                    StatePill(raw: group.isInternal ? b.internalState : b.externalState, compact: true)
                }
                .font(.callout)
            }
            if let link = group.publicLink, group.publicLinkEnabled {
                HStack {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    Text(link.replacingOccurrences(of: "https://", with: "")).font(.caption.monospaced()).lineLimit(1)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        copyToPasteboard(link)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        }
        .card(radius: 18)
    }
}

struct BuildSheet: View {
    let app: ASCApp
    let build: ASCBuild
    let groups: [ASCBetaGroup]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [ASCBetaLocalization] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppIcon(url: build.iconURL(size: 128), name: app.name, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(app.name) \(build.version) (\(build.number))").font(.title2.bold())
                    Text("Uploaded \(build.uploaded?.short ?? "?") · min iOS \(build.minOS ?? "?")").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            BuildLane(build: build)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow { Text("Processing").foregroundStyle(.secondary); StatePill(raw: build.processingState) }
                GridRow { Text("Internal").foregroundStyle(.secondary); StatePill(raw: build.internalState) }
                GridRow { Text("External").foregroundStyle(.secondary); StatePill(raw: build.externalState) }
                GridRow { Text("Beta review").foregroundStyle(.secondary); StatePill(raw: build.reviewState) }
                GridRow {
                    Text("Groups").foregroundStyle(.secondary)
                    Text(build.groupIDs.compactMap { id in groups.first { $0.id == id }?.name }.joined(separator: ", ").ifEmpty("None"))
                }
                GridRow { Text("Encryption").foregroundStyle(.secondary); Text(build.usesNonExemptEncryption == false ? "Exempt" : (build.usesNonExemptEncryption == true ? "Uses non-exempt" : "From Info.plist")) }
            }
            .font(.callout)
            Divider()
            Text("What to Test").font(.headline)
            if loading { ProgressView().controlSize(.small) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(notes) { n in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(n.locale).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(n.whatsNew.ifEmpty("—")).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: n.locale.hasPrefix("ar") ? .trailing : .leading)
                                .multilineTextAlignment(n.locale.hasPrefix("ar") ? .trailing : .leading)
                        }
                        .card(radius: 12, padding: 12)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 640)
        .task {
            if let c = try? model.client(forApp: app.id) { notes = (try? await c.betaLocalizations(buildID: build.id)) ?? [] }
            loading = false
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

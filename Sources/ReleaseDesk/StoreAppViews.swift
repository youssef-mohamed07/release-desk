import AppKit
import ReleaseKit
import SwiftUI

extension AGCApp {
    var tone: StateTone {
        switch releaseState {
        case 0: .good
        case 3, 4, 5, 12: .active
        case 7: .waiting
        case 1, 8, 9, 13: .bad
        default: .muted
        }
    }
}

/// Partner Center's submission states, in words and colour.
func describeMicrosoft(_ raw: String?) -> (label: String, tone: StateTone) {
    switch raw {
    case nil: ("—", .muted)
    case "Published": ("Published", .good)
    case "PendingCommit": ("Draft", .waiting)
    case "CommitStarted", "PreProcessing": ("Processing", .active)
    case "Certification": ("In certification", .active)
    case "Release", "Publishing", "PendingPublication": ("Publishing", .active)
    case let s? where s.hasSuffix("Failed"): (s.replacingOccurrences(of: "Failed", with: " failed"), .bad)
    case "Canceled": ("Canceled", .muted)
    case let s?: (s, .muted)
    }
}

/// The page of an app on Huawei AppGallery.
struct AGCAppDetailView: View {
    let app: ASCApp
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.apps[app.id] ?? AppState()
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                StoreHero(app: app, mark: AnyView(AppGalleryMark(size: 22)), chips: [], loading: state.loading) {
                    if let a = state.agc {
                        HStack(spacing: 8) {
                            Text(a.version ?? "No version").font(.body.weight(.semibold).monospacedDigit())
                            StatePillText(text: a.stateTitle, tone: a.tone)
                            if let shelf = a.versionOnShelf { Text("· \(shelf) on sale").foregroundStyle(.secondary) }
                        }
                        .font(.callout)
                    }
                } links: {
                    Link(destination: URL(string: "https://developer.huawei.com/consumer/en/service/josp/agc/index.html")!) {
                        Label("AppGallery Connect", systemImage: "arrow.up.right.square")
                    }
                }
                if let e = state.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if let a = state.agc {
                    if let note = a.reviewNote, !note.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Review notes", symbol: "text.bubble")
                            Text(note).textSelection(.enabled).sensitive(5).card()
                        }
                    }
                    if let phased = a.phasedState {
                        Label("Phased release: \(phased.lowercased())", systemImage: "chart.bar.fill").foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "What's new", subtitle: a.newFeatures.isEmpty ? nil : "\(a.newFeatures.count)", symbol: "text.bubble")
                        if a.newFeatures.isEmpty {
                            Text("No What's new on the version being prepared.").foregroundStyle(.secondary)
                        }
                        ForEach(a.newFeatures.keys.sorted(), id: \.self) { lang in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(StoreLanguages.name(lang.replacingOccurrences(of: "_", with: "-")))  ·  \(lang)").font(.caption.weight(.semibold))
                                Text(a.newFeatures[lang] ?? "").textSelection(.enabled).sensitive(5)
                                    .environment(\.layoutDirection, StoreLanguages.isRightToLeft(lang) ? .rightToLeft : .leftToRight)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card()
                        }
                    }
                }
            }
            .padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 40)
        }
        .background(alignment: .top) { AmbientGlow(url: model.iconURL(app.id), intensity: 0.4).frame(height: 420) }
        .task(id: app.id) { await model.refresh(appID: app.id) }
    }
}

/// The page of an app in the Microsoft Store (Partner Center).
struct MSAppDetailView: View {
    let app: ASCApp
    @Environment(AppModel.self) private var model

    private var storeID: String { String(app.id.dropFirst("msstore:".count)) }

    var body: some View {
        let state = model.apps[app.id] ?? AppState()
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                StoreHero(app: app, mark: AnyView(WindowsMark(size: 20)), chips: [(storeID, "number")], loading: state.loading) {
                    if let m = state.ms {
                        HStack(spacing: 8) {
                            if let s = m.lastStatus { Text("Published submission").foregroundStyle(.secondary); StatePillText(text: describeMicrosoft(s).label, tone: describeMicrosoft(s).tone) }
                            if let p = m.pendingStatus { Text("· Draft").foregroundStyle(.secondary); StatePillText(text: describeMicrosoft(p).label, tone: describeMicrosoft(p).tone) }
                        }
                        .font(.callout)
                    }
                } links: {
                    Link(destination: URL(string: "https://partner.microsoft.com/dashboard/products/\(storeID)/overview")!) {
                        Label("Partner Center", systemImage: "arrow.up.right.square")
                    }
                    Link(destination: URL(string: "https://apps.microsoft.com/detail/\(storeID)")!) {
                        Label("Store page", systemImage: "storefront")
                    }
                }
                if let e = state.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if let m = state.ms {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Listing languages", subtitle: "\(m.listingLanguages.count)", symbol: "globe")
                        FlowLayout(spacing: 6) {
                            ForEach(m.listingLanguages, id: \.self) { l in
                                Text(l).font(.caption.monospaced()).padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.quaternary.opacity(0.6), in: .capsule)
                            }
                        }
                        Text("Release Desk writes What's new only in languages the Store listing already has.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !m.releaseNotes.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "What's new", symbol: "text.bubble")
                            ForEach(m.releaseNotes.keys.sorted(), id: \.self) { lang in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(lang).font(.caption.weight(.semibold).monospaced())
                                    Text(m.releaseNotes[lang] ?? "").textSelection(.enabled).sensitive(5)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .card()
                            }
                        }
                    }
                    if let first = m.firstPublished {
                        Text("First published \(first.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 40)
        }
        .background(alignment: .top) { AmbientGlow(url: model.iconURL(app.id), intensity: 0.4).frame(height: 420) }
        .task(id: app.id) { await model.refresh(appID: app.id) }
    }
}

/// Icon, name, chips, a status line, the Ship button and store links.
struct StoreHero<Status: View, Links: View>: View {
    let app: ASCApp
    let mark: AnyView
    let chips: [(String, String)]
    let loading: Bool
    @ViewBuilder var status: () -> Status
    @ViewBuilder var links: () -> Links
    @Environment(AppModel.self) private var model

    var body: some View {
        let team = model.team(ofApp: app.id)
        let link = model.workspace.link(for: app.id)
        let run = model.activeRun(for: app.id)
        HStack(alignment: .center, spacing: 22) {
            AppIcon(url: model.iconURL(app.id, size: 512), name: app.name, size: 104).sensitive(14)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(app.name).font(.system(size: 34, weight: .bold, design: .rounded)).sensitive(12)
                    mark
                }
                HStack(spacing: 10) {
                    Chip(text: app.bundleID, symbol: "shippingbox", mono: true, sensitive: true)
                    ForEach(chips, id: \.0) { Chip(text: $0.0, symbol: $0.1, mono: true, sensitive: true) }
                    if let team { Chip(text: team.name, symbol: "person.2", sensitive: true) }
                    if let link { Chip(text: (link.path as NSString).abbreviatingWithTildeInPath, symbol: "folder", mono: true, sensitive: true) }
                }
                status()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                Button { model.route = .ship(app.id) } label: {
                    Label(run != nil ? "Shipping \(run!.plan.version) (\(run!.plan.build))…" : "Ship an update", systemImage: "paperplane.fill")
                        .font(.headline)
                }
                .buttonStyle(.glassProminent).tint(Palette.indigo).controlSize(.large)
                HStack(spacing: 14) {
                    links()
                    Button { Task { await model.refresh(appID: app.id) } } label: {
                        if loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(.borderless).help("Refresh")
                }
                .font(.callout)
            }
        }
    }
}

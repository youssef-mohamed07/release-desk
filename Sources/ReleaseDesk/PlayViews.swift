import AppKit
import ReleaseKit
import SwiftUI

extension PlayRelease {
    var tone: StateTone {
        switch status {
        case "completed": .good
        case "inProgress": .active
        case "draft": .waiting
        case "halted": .bad
        default: .muted
        }
    }

    var statusLabel: String {
        switch status {
        case "completed": "Live"
        case "inProgress": userFraction.map { "Rolling out · \(Int(($0 * 100).rounded()))%" } ?? "Rolling out"
        case "draft": "Draft"
        case "halted": "Halted"
        default: status.capitalized
        }
    }
}

/// A Play app: its tracks side by side, newest release on top of each.
struct PlayAppDetailView: View {
    let app: ASCApp
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.apps[app.id] ?? AppState()
        let team = model.team(ofApp: app.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 22) {
                    AppIcon(url: model.iconURL(app.id, size: 512), name: app.name, size: 104).sensitive(14)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text(app.name).font(.system(size: 34, weight: .bold, design: .rounded)).sensitive(12)
                            PlayMark(size: 22)
                        }
                        HStack(spacing: 10) {
                            Chip(text: app.bundleID, symbol: "shippingbox", mono: true, sensitive: true)
                            if let team { Chip(text: team.name, symbol: "person.2", sensitive: true) }
                            if let lang = state.play?.defaultLanguage { Chip(text: lang, symbol: "globe") }
                            if let link = model.workspace.link(for: app.id) {
                                Chip(text: (link.path as NSString).abbreviatingWithTildeInPath, symbol: "folder", mono: true, sensitive: true)
                            }
                        }
                        if let top = state.tracks.flatMap(\.releases).max(by: { $0.maxCode < $1.maxCode }) {
                            HStack(spacing: 8) {
                                Text("Highest").foregroundStyle(.secondary)
                                Text(top.name.isEmpty ? top.versionCodes.joined(separator: ", ") : top.name).fontWeight(.semibold).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        Button { model.route = .ship(app.id) } label: {
                            Label(model.activeRun(for: app.id) != nil ? "Shipping…" : "Ship to Google Play", systemImage: "paperplane.fill")
                                .font(.headline).padding(.horizontal, 10).padding(.vertical, 5)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Color(red: 0.0, green: 0.62, blue: 0.45))
                        .controlSize(.extraLarge)
                        Link(destination: URL(string: "https://play.google.com/console/developers")!) {
                            Label("Open Play Console", systemImage: "arrow.up.right.square").font(.callout)
                        }
                    }
                }
                if let e = state.error, let team {
                    AccessCard(message: e, team: team) { Task { await model.refresh(appID: app.id) } }
                }
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Tracks", subtitle: state.tracks.isEmpty ? nil : "\(state.tracks.count)", symbol: "road.lanes")
                    if state.tracks.isEmpty {
                        Text(state.loading ? "Loading…" : (state.error == nil ? "No releases on any track yet." : "Tracks show up once Play lets this account in."))
                            .foregroundStyle(.secondary).card()
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                // Tracks with releases first, each group in lifecycle order.
                                ForEach(state.tracks.sorted { ($0.releases.isEmpty ? 1 : 0, $0.order) < ($1.releases.isEmpty ? 1 : 0, $1.order) }) {
                                    TrackColumn(track: $0)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .scrollClipDisabled()
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 40)
        }
        .background(alignment: .top) { AmbientGlow(url: model.iconURL(app.id), intensity: 0.55).frame(height: 520) }
        .task(id: app.id) { await model.refresh(appID: app.id) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refresh(appID: app.id) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
    }
}

/// Explains a Play permission problem and how to fix it, with the email to
/// copy and a button to check again.
struct AccessCard: View {
    let message: String
    let team: Team
    let retry: () -> Void
    @State private var copied = false

    var body: some View {
        let email: String? = { if case .playServiceAccount(let e) = team.credential { return e } else { return nil } }()
        let isAccess = message.contains("has not given") || message.contains("has no access")
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: isAccess ? "person.badge.key.fill" : "exclamationmark.triangle.fill")
                .font(.title2).foregroundStyle(StateTone.waiting.color)
            VStack(alignment: .leading, spacing: 8) {
                Text(isAccess ? (email == nil ? "No access to this app" : "Play needs to let this account in") : "Play answered with a problem").font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).sensitive(4)
                if isAccess, email != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Play Console → Users and permissions → Invite new users.")
                        Text("2. Paste the service account email, give it this app with Release permissions.")
                        Text("3. Send the invite, then check again here. It can take a few minutes.")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if let email {
                        Button(copied ? "Copied" : "Copy service account email") {
                            copyToPasteboard(email)
                            copied = true
                        }
                        .buttonStyle(.glass).controlSize(.small)
                    }
                    Link("Open Play Console users", destination: URL(string: "https://play.google.com/console/developers/users-and-permissions")!)
                        .font(.caption)
                    Spacer()
                    Button("Check again", action: retry).buttonStyle(.glass).controlSize(.small)
                }
            }
        }
        .card()
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(StateTone.waiting.color.opacity(0.35)))
    }
}

struct TrackColumn: View {
    let track: PlayTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: symbol).foregroundStyle(color)
                Text(track.title).font(.headline)
                Spacer()
                Text(track.track).font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            if track.releases.isEmpty {
                Text("Nothing here yet").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(track.releases) { r in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.name.isEmpty ? "Release" : r.name).font(.system(.title3, design: .rounded).weight(.semibold))
                        Spacer()
                        StatePillText(text: r.statusLabel, tone: r.tone)
                    }
                    Text("Version code \(r.versionCodes.joined(separator: ", "))").font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let f = r.userFraction, r.status == "inProgress" {
                        ProgressView(value: f).tint(Palette.cyan)
                    }
                    if let note = r.notes.values.first, !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(4).sensitive(4)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 12))
            }
        }
        .frame(width: 290, alignment: .topLeading)
        .card(radius: 18)
    }

    private var symbol: String {
        switch track.track {
        case "internal": "building.2"
        case "alpha": "lock.shield"
        case "beta": "person.3"
        case "production": "globe"
        default: "road.lanes"
        }
    }

    private var color: Color {
        switch track.track {
        case "production": Palette.mint
        case "beta": Palette.cyan
        case "alpha": Palette.violet
        default: Palette.indigo
        }
    }
}

struct StatePillText: View {
    let text: String
    let tone: StateTone
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tone.color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 3.5)
        .background(tone.color.opacity(0.13), in: .capsule)
    }
}

/// The small summary a Play app shows on overview cards.
struct TrackStrip: View {
    let tracks: [PlayTrack]
    let error: String?

    var body: some View {
        if let error, tracks.isEmpty {
            Label(error.contains("has not given") ? "Waiting for Play access" : "Play answered with a problem",
                  systemImage: "person.badge.key")
                .font(.caption).foregroundStyle(StateTone.waiting.color)
        } else if tracks.isEmpty {
            Text("No releases yet").font(.callout).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ForEach(tracks.prefix(4)) { t in
                    let r = t.releases.first
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title.replacingOccurrences(of: " testing", with: "")).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                        Text(r.map { $0.name.isEmpty ? $0.versionCodes.first ?? "–" : $0.name } ?? "–")
                            .font(.caption.weight(.semibold).monospacedDigit()).lineLimit(1)
                        Capsule().fill(r?.tone.color ?? Color.secondary.opacity(0.2)).frame(height: 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Ship to Play

struct PlayShipComposer: View {
    let app: ASCApp
    let link: ProjectLink
    let onLaunch: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.privacyMode) private var privacy

    @State private var project: FlutterProject?
    @State private var loadError: String?
    @State private var version = ""
    @State private var build = 1
    @State private var track = "internal"
    @State private var status = "completed"
    @State private var rollout = 0.2
    @State private var notes: [String: String] = [:]
    @State private var writeBuildNumber = true
    @State private var rehearsal = false
    @State private var confirming = false
    @State private var launchError: String?
    @State private var ready = false

    private var state: AppState { model.apps[app.id] ?? AppState() }
    private var highest: Int { state.tracks.flatMap(\.releases).map(\.maxCode).max() ?? 0 }
    private var locales: [String] { ["en-US", "ar"] }
    private var tracks: [(String, String)] {
        var t = [("internal", "Internal"), ("alpha", "Closed"), ("beta", "Open"), ("production", "Production")]
        for x in state.tracks where !t.contains(where: { $0.0 == x.track }) { t.append((x.track, x.title)) }
        return t
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 16) {
                        AppIcon(url: model.iconURL(app.id, size: 256), name: app.name, size: 64).sensitive(10)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Ship").font(.system(size: 28, weight: .bold, design: .rounded))
                                Text(app.name).font(.system(size: 28, weight: .bold, design: .rounded)).sensitive(10)
                                PlayMark(size: 20)
                            }
                            HStack(spacing: 8) {
                                Chip(text: (link.path as NSString).abbreviatingWithTildeInPath, symbol: "folder", mono: true, sensitive: true)
                                if let p = project { Chip(text: "pubspec \(p.version)+\(p.buildNumber)", symbol: "doc.text", mono: true) }
                                Chip(text: "Android · Google Play", symbol: "apps.iphone")
                            }
                        }
                        Spacer()
                    }
                    if let loadError { Label(loadError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).card() }
                    if let e = state.error, let team = model.team(ofApp: app.id) {
                        AccessCard(message: e, team: team) { Task { await model.refresh(appID: app.id) } }
                    }
                    if let p = project, !p.hasUploadKey {
                        Label("This project has no android/key.properties, so release builds are signed with the debug key and Play refuses them. A rehearsal still works.",
                              systemImage: "key.slash").foregroundStyle(StateTone.waiting.color).card()
                    }
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 20) {
                            releaseCard
                            trackCard
                            optionsCard
                        }
                        .frame(width: 420)
                        notesCard
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 26)
                .padding(.bottom, 120)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) { Text(app.name).sensitive(); Text("\(version) (\(build))") }.font(.headline.monospacedDigit())
                    Text(rehearsal ? "Rehearsal · build and check signing" : "Upload → \(tracks.first { $0.0 == track }?.1 ?? track) · \(statusText)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let launchError { Text(launchError).font(.caption).foregroundStyle(Palette.ember).lineLimit(2) }
                Button { confirming = true } label: {
                    Label(rehearsal ? "Rehearse" : "Launch", systemImage: rehearsal ? "play.circle" : "paperplane.fill")
                        .font(.headline).padding(.horizontal, 18).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(rehearsal ? Palette.violet : Color(red: 0.0, green: 0.62, blue: 0.45))
                .controlSize(.extraLarge)
                .disabled(!ready || version.isEmpty || model.activeRun(for: app.id) != nil || (!rehearsal && build <= highest))
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding(.horizontal, 26).padding(.bottom, 18)
        }
        .background(alignment: .top) { AmbientGlow(url: model.iconURL(app.id), intensity: 0.45).frame(height: 460) }
        .task(id: link.path) { await load() }
        .onChange(of: notes) { Drafts.save(notes, for: app.id) }
        .alert(rehearsal ? "Rehearse \(privacy ? "this app" : app.name) \(version) (\(build))?" : "Release \(privacy ? "this app" : app.name) \(version) (\(build)) on Google Play?", isPresented: $confirming) {
            Button(rehearsal ? "Rehearse" : "Release") { launch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(rehearsal ? "Builds the app bundle and checks its signature. Nothing is uploaded."
                 : "Builds the app bundle, uploads it and releases it to the \(tracks.first { $0.0 == track }?.1 ?? track) track as \(statusText.lowercased()).")
        }
    }

    private var statusText: String {
        switch status {
        case "inProgress": "Staged rollout \(Int(rollout * 100))%"
        case "draft": "Draft"
        default: "Full rollout"
        }
    }

    private var releaseCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Release", systemImage: "number").font(.headline)
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Version name").font(.caption).foregroundStyle(.secondary)
                    TextField("1.0.0", text: $version).textFieldStyle(.plain)
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit()).frame(width: 130)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Version code").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(verbatim: "\(build)").font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText(value: Double(build)))
                        Stepper("", value: $build.animation(.snappy), in: 1...2_100_000_000).labelsHidden()
                    }
                }
                Spacer()
            }
            Text(state.error != nil && state.tracks.isEmpty ? "Play has not shown this app's version codes yet."
                 : (highest > 0 ? "Highest on Play: \(highest)." : "No version code on Play yet.")).font(.caption)
                .foregroundStyle(build <= highest ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            Toggle(isOn: $writeBuildNumber) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Write \(version)+\(build) to pubspec.yaml")
                    Text("So the repo says what shipped. Commit it after.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
        .card()
    }

    private var trackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Track", systemImage: "road.lanes").font(.headline)
            Picker("Track", selection: $track) {
                ForEach(tracks, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Picker("Rollout", selection: $status) {
                Text("Full").tag("completed")
                Text("Staged").tag("inProgress")
                Text("Draft").tag("draft")
            }
            .pickerStyle(.segmented)
            if status == "inProgress" {
                HStack {
                    Slider(value: $rollout, in: 0.01...0.99, step: 0.01)
                    Text("\(Int(rollout * 100))%").font(.callout.monospacedDigit()).frame(width: 44)
                }
            }
            if let current = state.tracks.first(where: { $0.track == track })?.releases.first {
                Text("Now on this track: \(current.name.isEmpty ? current.versionCodes.joined(separator: ", ") : current.name) · \(current.statusLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var optionsCard: some View {
        Toggle(isOn: $rehearsal) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Rehearsal")
                Text("Build the app bundle and check its signature. Nothing is uploaded.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .card()
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("What's new", systemImage: "text.bubble.fill").font(.headline)
            ForEach(locales, id: \.self) { locale in
                let rtl = locale.hasPrefix("ar")
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(Locale.current.localizedString(forIdentifier: locale) ?? locale).font(.caption.weight(.semibold))
                        Text(locale).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        Spacer()
                        Text("\((notes[locale] ?? "").count)/500").font(.caption2.monospacedDigit())
                            .foregroundStyle((notes[locale] ?? "").count > 500 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    }
                    TextEditor(text: Binding(get: { notes[locale] ?? "" }, set: { notes[locale] = $0 }))
                        .font(.system(size: 13.5)).scrollContentBackground(.hidden).padding(8).frame(minHeight: 120)
                        .sensitive(5)
                        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
                        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                }
            }
            Text("Play allows 500 characters per language.").font(.caption).foregroundStyle(.tertiary)
        }
        .card()
    }

    private func load() async {
        do { project = try FlutterProject.inspect(link.url, recipe: link.recipe) } catch {
            loadError = error.localizedDescription
            return
        }
        if model.apps[app.id]?.detailed != true { await model.refresh(appID: app.id) }
        guard let project else { return }
        version = project.version
        build = max(highest + 1, project.buildNumber)
        writeBuildNumber = link.recipe.writeBuildNumber
        track = link.recipe.playTrack ?? "internal"
        status = link.recipe.playStatus ?? "completed"
        notes = Drafts.load(for: app.id)
        ready = true
    }

    private func launch() {
        guard let project else { return }
        model.updateRecipe(appID: app.id) { r in
            r.playTrack = track
            r.playStatus = status
            r.writeBuildNumber = writeBuildNumber
        }
        var recipe = model.workspace.link(for: app.id)?.recipe ?? link.recipe
        recipe.writeBuildNumber = writeBuildNumber
        var plan = ReleasePlan(app: app, projectRoot: project.root, version: version, build: build, recipe: recipe,
                               teamID: nil, groups: [], whatsNew: notes.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                               submitForReview: false, rehearsal: rehearsal)
        plan.platform = .android
        plan.play = PlayTarget(track: track, status: status, userFraction: status == "inProgress" ? rollout : nil)
        do {
            _ = try model.launch(plan)
            if !rehearsal { Drafts.clear(for: app.id) }
            onLaunch()
        } catch {
            launchError = error.localizedDescription
        }
    }
}

/// Release notes typed but not shipped yet, kept per app between launches.
enum Drafts {
    static func load(for appID: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: "draft.\(appID)") as? [String: String] ?? [:]
    }

    static func save(_ notes: [String: String], for appID: String) {
        UserDefaults.standard.set(notes.filter { !$0.value.isEmpty }, forKey: "draft.\(appID)")
    }

    static func clear(for appID: String) { UserDefaults.standard.removeObject(forKey: "draft.\(appID)") }
}

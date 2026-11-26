import AppKit
import ReleaseKit
import SwiftUI

/// Ship an update: link the source folder once, compose the release, launch
/// it, and watch it fly.
struct ShipView: View {
    let appID: String
    @Environment(AppModel.self) private var model
    @State private var composing = false

    var body: some View {
        if let app = model.app(appID) {
            if let run = model.latestRun(for: appID), !composing {
                LaunchConsole(run: run, onNew: { composing = true })
            } else if let link = model.workspace.link(for: appID) {
                if app.isPlay {
                    PlayShipComposer(app: app, link: link, onLaunch: { composing = false })
                } else {
                    ShipComposer(app: app, link: link, onLaunch: { composing = false })
                }
            } else {
                LinkProjectPanel(app: app)
            }
        } else {
            ContentUnavailableView("Loading app…", systemImage: "app.dashed")
        }
    }
}

// MARK: - Link a project

struct LinkProjectPanel: View {
    let app: ASCApp
    @Environment(AppModel.self) private var model
    @State private var candidates: [FlutterProject] = []
    @State private var scanning = true
    @State private var choosing = false
    @State private var path = ""
    @State private var error: String?

    var body: some View {
        ZStack {
            AmbientGlow(url: model.iconURL(app.id), intensity: 0.5)
            VStack(spacing: 26) {
                AppIcon(url: model.iconURL(app.id, size: 512), name: app.name, size: 96).sensitive(14)
                VStack(spacing: 8) {
                    Text("Where is this app built from?").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Pick its Flutter project. Release Desk remembers it, and links the same app on the other store too.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 540)
                }
                VStack(spacing: 10) {
                    if scanning {
                        HStack { ProgressView().controlSize(.small); Text("Looking through your project folders…").foregroundStyle(.secondary) }
                    }
                    ForEach(candidates, id: \.root) { p in
                        Button { use(p.root) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill").font(.title2).foregroundStyle(Palette.cyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((p.root.path as NSString).abbreviatingWithTildeInPath).font(.body.monospaced())
                                    Text("\(p.name) · \(p.version)+\(p.buildNumber) · iOS \(p.iosBundleID ?? "–") · Android \(p.androidPackage ?? "–")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .sensitive()
                                Spacer()
                                Text("Use this").font(.callout.weight(.semibold))
                                Image(systemName: "arrow.right")
                            }
                            .padding(14)
                            .frame(width: 600)
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                    if !scanning && candidates.isEmpty {
                        Text("No Flutter project in your project folders builds \(app.bundleID).").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        TextField("Path", text: $path, prompt: Text("Paste or type a folder path"))
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                            .frame(width: 380)
                            .onSubmit { use(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)) }
                        Button("Use") { use(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)) }
                            .disabled(path.isEmpty)
                        Button("Choose…") { choosing = true }
                    }
                    .buttonStyle(.glass)
                    .padding(.top, 6)
                    if let error { Text(error).foregroundStyle(Palette.ember).font(.callout) }
                }
            }
            .padding(40)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { use(url) }
        }
        .task {
            let id = app.bundleID
            let roots = ProjectScanner.roots(model: model)
            candidates = await Task.detached { ProjectScanner.projects(in: roots).filter { $0.iosBundleID == id || $0.androidPackage == id } }.value
            scanning = false
        }
    }

    private func use(_ url: URL) {
        do {
            let p = try FlutterProject.inspect(url)
            let builds = [p.iosBundleID, p.androidPackage].compactMap { $0 }
            if !builds.isEmpty, !builds.contains(app.bundleID) {
                error = "That project builds \(builds.joined(separator: " and ")), not \(app.bundleID)."
            } else {
                model.link(appID: app.id, path: url.path)
            }
        } catch { self.error = error.localizedDescription }
    }
}

/// Where Flutter projects are looked for: ~/Developer, the folders of
/// projects already linked, and any folder added by hand.
enum ProjectScanner {
    @MainActor
    static func roots(model: AppModel) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [home.appendingPathComponent("Developer")]
        for l in model.workspace.links {
            // A linked project at <root>/<app> or <root>/<repo>/mobile adds <root>.
            var u = l.url.deletingLastPathComponent()
            if ["mobile", "app", "flutter"].contains(l.url.lastPathComponent) { u = u.deletingLastPathComponent() }
            if u.path != home.path, !roots.contains(u) { roots.append(u) }
        }
        for extra in UserDefaults.standard.stringArray(forKey: "projectRoots") ?? [] {
            let u = URL(fileURLWithPath: extra)
            if !roots.contains(u) { roots.append(u) }
        }
        return roots
    }

    nonisolated static func projects(in roots: [URL]) -> [FlutterProject] {
        let fm = FileManager.default
        var out: [FlutterProject] = []
        var seen = Set<String>()
        for dir in roots {
            for top in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                for sub in ["", "mobile", "app", "apps/mobile", "flutter"] {
                    let root = sub.isEmpty ? top : top.appendingPathComponent(sub)
                    guard !seen.contains(root.path), fm.fileExists(atPath: root.appendingPathComponent("pubspec.yaml").path),
                          let p = try? FlutterProject.inspect(root), p.iosBundleID != nil || p.androidPackage != nil else { continue }
                    seen.insert(root.path)
                    out.append(p)
                }
            }
        }
        return out.sorted { $0.root.path.count < $1.root.path.count }
    }
}

// MARK: - Compose

struct ShipComposer: View {
    let app: ASCApp
    let link: ProjectLink
    let onLaunch: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.privacyMode) private var privacy

    @State private var project: FlutterProject?
    @State private var loadError: String?
    @State private var version = ""
    @State private var build = 1
    @State private var selectedGroups: Set<String> = []
    @State private var notes: [String: String] = [:]
    @State private var previousNotes: [String: String] = [:]
    @State private var commits: [String] = []
    @State private var submitForReview = true
    @State private var writeBuildNumber = true
    @State private var rehearsal = false
    @State private var confirming = false
    @State private var launchError: String?
    @State private var ready = false
    // Build on GitHub Actions
    @State private var onGitHub = false
    @State private var repo: GitHubRepo?
    @State private var cloudReady = false

    private var state: AppState { model.apps[app.id] ?? AppState() }
    private var latest: ASCBuild? { state.builds.first }
    private var ascMax: Int { state.builds.map(\.numericNumber).max() ?? 0 }
    private var groups: [ASCBetaGroup] { state.groups.filter { selectedGroups.contains($0.id) } }
    private var buildTaken: Bool { state.builds.contains { $0.version == version && $0.numericNumber == build } }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).card()
                    }
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 20) {
                            releaseCard
                            CloudBuildCard(app: app, link: link, target: .ios, onGitHub: $onGitHub, repo: $repo, ready: $cloudReady)
                            testersCard
                            optionsCard
                        }
                        .frame(width: 400)
                        VStack(spacing: 20) {
                            notesCard
                            commitsCard
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 26)
                .padding(.bottom, 120)
            }
            launchBar
        }
        .background(alignment: .top) { AmbientGlow(url: model.iconURL(app.id), intensity: 0.45).frame(height: 460) }
        .task(id: link.path) { await load() }
        .onChange(of: notes) { Drafts.save(notes, for: app.id) }
        .alert(rehearsal ? "Rehearse \(privacy ? "this app" : app.name) \(version) (\(build))?" : "Ship \(privacy ? "this app" : app.name) \(version) (\(build))?", isPresented: $confirming) {
            Button(rehearsal ? "Rehearse" : "Ship to TestFlight") { launch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmText)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            AppIcon(url: model.iconURL(app.id, size: 256), name: app.name, size: 64).sensitive(10)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("Ship")
                    Text(app.name).sensitive(10)
                }
                .font(.system(size: 28, weight: .bold, design: .rounded))
                HStack(spacing: 8) {
                    Chip(text: (link.path as NSString).abbreviatingWithTildeInPath, symbol: "folder", mono: true, sensitive: true)
                    if let p = project { Chip(text: "pubspec \(p.version)+\(p.buildNumber)", symbol: "doc.text", mono: true) }
                    Chip(text: "iOS · TestFlight", symbol: "iphone")
                }
            }
            Spacer()
            Menu {
                Button("Change project folder…") {
                    model.workspace.links.removeAll { $0.appID == app.id }
                    model.save()
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([link.url]) }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            .menuStyle(.button).buttonStyle(.glass).fixedSize()
        }
    }

    private var releaseCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Release", systemImage: "number").font(.headline)
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Version").font(.caption).foregroundStyle(.secondary)
                    TextField("1.0.0", text: $version)
                        .textFieldStyle(.plain)
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .frame(width: 130)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Build").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(verbatim: "\(build)")
                            .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText(value: Double(build)))
                            .frame(minWidth: 44, alignment: .leading)
                        Stepper("", value: $build.animation(.snappy), in: 1...99_999).labelsHidden()
                    }
                }
                Spacer()
            }
            if buildTaken {
                Label("\(version) (\(build)) is already on App Store Connect.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if let latest {
                Text("Last upload: \(latest.version) (\(latest.number)), \(latest.uploaded?.relative ?? "").")
                    .font(.caption).foregroundStyle(.secondary)
            }
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

    private var testersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Testers", systemImage: "person.3.fill").font(.headline)
            if state.groups.isEmpty {
                Text(state.loading ? "Loading groups…" : "This app has no TestFlight groups yet.").foregroundStyle(.secondary)
            }
            ForEach(state.groups) { g in
                let on = selectedGroups.contains(g.id)
                Button {
                    withAnimation(.snappy) { if on { selectedGroups.remove(g.id) } else { selectedGroups.insert(g.id) } }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(on ? Palette.mint : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.name).fontWeight(.medium).sensitive(5)
                            Text(g.isInternal ? (g.allBuilds ? "Internal · gets every build" : "Internal") : "External · beta review")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(g.testerCount ?? 0)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Image(systemName: "person.fill").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .background(on ? Palette.mint.opacity(0.08) : Color.clear, in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Palette.mint.opacity(0.35) : Color.secondary.opacity(0.15)))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $submitForReview) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Submit for beta review")
                    Text("External testers need it. Later builds of an approved version usually pass in minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!groups.contains { !$0.isInternal })
            Divider()
            Toggle(isOn: $rehearsal) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Rehearsal")
                    Text("Archive, sign and export the IPA. Nothing is uploaded.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .card()
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("What to Test", systemImage: "text.bubble.fill").font(.headline)
                Spacer()
                if !previousNotes.isEmpty {
                    Button("Start from build \(latest?.number ?? "")") {
                        for (k, v) in previousNotes where (notes[k] ?? "").isEmpty { notes[k] = v }
                    }
                    .buttonStyle(.glass).controlSize(.small)
                }
            }
            ForEach(link.recipe.locales, id: \.self) { locale in
                let rtl = locale.hasPrefix("ar")
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(Locale.current.localizedString(forIdentifier: locale) ?? locale).font(.caption.weight(.semibold))
                        Text(locale).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        Spacer()
                        Text("\((notes[locale] ?? "").count)/4000").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    TextEditor(text: Binding(get: { notes[locale] ?? "" }, set: { notes[locale] = $0 }))
                        .font(.system(size: 13.5))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 130)
                        .sensitive(5)
                        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
                        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                        .multilineTextAlignment(rtl ? .trailing : .leading)
                }
            }
        }
        .card()
    }

    private var commitsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Changes since build \(latest?.number ?? "–")", systemImage: "arrow.triangle.branch").font(.headline)
                Spacer()
                Text(counted(commits.count, "commit")).font(.caption).foregroundStyle(.secondary)
            }
            if commits.isEmpty {
                Text("No commits since the last upload.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(commits.enumerated()), id: \.offset) { _, c in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(Palette.violet).frame(width: 6, height: 6).padding(.top, 6)
                    Text(c).font(.callout).textSelection(.enabled).sensitive(5)
                    Spacer()
                    Button {
                        let key = link.recipe.locales.first { $0.hasPrefix("en") } ?? link.recipe.locales.last ?? "en-US"
                        let cur = notes[key] ?? ""
                        notes[key] = cur + (cur.isEmpty || cur.hasSuffix("\n") ? "" : "\n") + "- \(c)"
                    } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
                    .help("Add to the English notes")
                }
            }
        }
        .card()
    }

    private var launchBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) { Text(app.name).sensitive(); Text("\(version) (\(build))") }.font(.headline.monospacedDigit())
                Text(destinationText).font(.caption).foregroundStyle(.secondary).lineLimit(1).sensitive(4)
            }
            Spacer()
            if let launchError { Text(launchError).font(.caption).foregroundStyle(Palette.ember).lineLimit(2) }
            Button { confirming = true } label: {
                Label(rehearsal ? "Rehearse" : "Launch", systemImage: rehearsal ? "play.circle" : "paperplane.fill")
                    .font(.headline)
                    .padding(.horizontal, 18).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(rehearsal ? Palette.violet : Palette.indigo)
            .controlSize(.extraLarge)
            .disabled(!ready || buildTaken || version.isEmpty || model.activeRun(for: app.id) != nil || (onGitHub && !cloudReady))
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 26)
        .padding(.bottom, 18)
    }

    private var destinationText: String {
        if rehearsal { return onGitHub ? "Rehearsal on GitHub · archive, sign, export" : "Rehearsal · archive, sign, export" }
        let names = groups.map(\.name)
        var parts = [onGitHub ? "GitHub build" : "Upload"]
        parts.append(names.isEmpty ? "no tester groups" : names.joined(separator: " + "))
        if submitForReview && groups.contains(where: { !$0.isInternal }) { parts.append("beta review") }
        return parts.joined(separator: " → ")
    }

    private var confirmText: String {
        let folder = onGitHub ? "on a GitHub macOS runner (\(privacy ? "the repository" : repo?.fullName ?? ""))"
            : (privacy ? "the linked project" : (link.path as NSString).abbreviatingWithTildeInPath)
        if rehearsal {
            return "Builds \(folder), signs and exports the IPA. Nothing is uploaded."
        }
        var s = "Builds \(folder) and uploads it to App Store Connect."
        if !groups.isEmpty {
            let testers = groups.compactMap(\.testerCount).reduce(0, +)
            s += " Adds it to \(privacy ? counted(groups.count, "tester group") : groups.map(\.name).joined(separator: " and ")) (\(counted(testers, "tester")))."
        }
        if notes.values.contains(where: { !$0.isEmpty }) { s += " Writes What to Test." }
        if submitForReview && groups.contains(where: { !$0.isInternal }) { s += " Submits it for beta app review." }
        return s
    }

    private func load() async {
        do {
            project = try FlutterProject.inspect(link.url, recipe: link.recipe)
        } catch {
            loadError = error.localizedDescription
            return
        }
        if model.apps[app.id]?.detailed != true { await model.refresh(appID: app.id) }
        guard let project else { return }
        version = project.version
        build = max(ascMax + 1, project.buildNumber)
        writeBuildNumber = link.recipe.writeBuildNumber
        submitForReview = link.recipe.submitForReview
        let remembered = Set(link.recipe.groupIDs).intersection(state.groups.map(\.id))
        selectedGroups = remembered.isEmpty ? Set(state.groups.map(\.id)) : remembered
        notes = Drafts.load(for: app.id)
        onGitHub = link.recipe.buildOn == "github"
        ready = true
        if let latest, let c = try? model.client(forApp: app.id) {
            let locs = (try? await c.betaLocalizations(buildID: latest.id)) ?? []
            previousNotes = Dictionary(locs.map { ($0.locale, $0.whatsNew) }, uniquingKeysWith: { a, _ in a })
        }
        commits = await project.commits(since: latest?.uploaded)
    }

    private func launch() {
        guard let project else { return }
        let ordered = state.groups.filter { selectedGroups.contains($0.id) }
        model.updateRecipe(appID: app.id) { r in
            r.groupIDs = ordered.map(\.id)
            r.submitForReview = submitForReview
            r.writeBuildNumber = writeBuildNumber
        }
        var recipe = model.workspace.link(for: app.id)?.recipe ?? link.recipe
        recipe.writeBuildNumber = writeBuildNumber
        var plan = ReleasePlan(app: app, projectRoot: project.root, version: version, build: build, recipe: recipe,
                               teamID: model.team(ofApp: app.id)?.teamID, groups: ordered,
                               whatsNew: notes.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                               submitForReview: submitForReview, rehearsal: rehearsal)
        if onGitHub, let repo { plan.cloud = CloudBuild(repo: repo, target: .ios) }
        do {
            _ = try model.launch(plan)
            if !rehearsal { Drafts.clear(for: app.id) }
            onLaunch()
        } catch {
            launchError = error.localizedDescription
        }
    }
}

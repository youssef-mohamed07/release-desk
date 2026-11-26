import AppKit
import ReleaseKit
import SwiftUI

/// Ship a Flutter Windows app to the Microsoft Store: a GitHub Windows runner
/// builds the MSIX with Microsoft's Store CLI and uploads it to a draft
/// submission; Release Desk writes What's new and commits it for certification.
struct WindowsShipComposer: View {
    let app: ASCApp
    let link: ProjectLink
    let onLaunch: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.privacyMode) private var privacy

    @State private var project: FlutterProject?
    @State private var loadError: String?
    @State private var version = ""
    @State private var build = 1
    @State private var notes: [String: String] = [:]
    @State private var gradual = false
    @State private var rollout = 10.0
    @State private var rehearsal = false
    @State private var confirming = false
    @State private var launchError: String?
    @State private var onGitHub = true
    @State private var repo: GitHubRepo?
    @State private var cloudReady = false
    @State private var msixConfig: Bool?
    @State private var storeIDInPubspec: String?

    private var storeID: String { String(app.id.dropFirst("msstore:".count)) }
    private var state: AppState { model.apps[app.id] ?? AppState() }
    private var recipe: IOSRecipe { model.workspace.link(for: app.id)?.recipe ?? link.recipe }
    /// Languages the Store listing has; What's new can only go into those.
    private var listingLanguages: [String] { state.ms?.listingLanguages ?? [] }
    private var locales: [String] {
        let chosen = recipe.msLocales ?? (listingLanguages.isEmpty ? ["en-us"] : Array(listingLanguages.prefix(2)))
        return chosen
    }
    private var ready: Bool { project != nil && msixConfig == true && cloudReady && model.activeRun(for: app.id) == nil && !version.isEmpty }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if let loadError { Label(loadError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).card() }
                    if let e = state.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).card() }
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 20) {
                            releaseCard
                            storeSetupCard
                            CloudBuildCard(app: app, link: link, target: .windows, onGitHub: $onGitHub, repo: $repo, ready: $cloudReady)
                            rolloutCard
                            rehearsalCard
                        }
                        .frame(width: 420)
                        NotesEditor(title: "What's new", symbol: "text.bubble.fill", limit: 1500,
                                    available: listingLanguages.isEmpty ? StoreLanguages.play.map { $0.lowercased() } : listingLanguages,
                                    locales: Binding(get: { locales }, set: { v in model.updateRecipe(appID: app.id) { $0.msLocales = v } }),
                                    notes: $notes,
                                    footer: "Written into the new submission before it goes to certification, only in languages the Store listing already has.")
                    }
                }
                .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 120)
            }
            launchBar
        }
        .background(alignment: .top) { AmbientGlow(url: model.iconURL(app.id), intensity: 0.45).frame(height: 460) }
        .task(id: link.path) { await load() }
        .onChange(of: notes) { Drafts.save(notes, for: app.id) }
        .alert(rehearsal ? "Rehearse \(privacy ? "this app" : app.name) \(version)?" : "Send \(privacy ? "this app" : app.name) \(version) to the Microsoft Store?", isPresented: $confirming) {
            Button(rehearsal ? "Rehearse" : "Send") { launch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(rehearsal ? "A GitHub Windows runner builds the MSIX. Nothing is uploaded."
                 : "A GitHub Windows runner builds the MSIX (\(version).0) and uploads it to a new submission. Release Desk writes What's new and sends it for certification\(gradual ? ", rolling out to \(Int(rollout))% at first" : "").")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            AppIcon(url: model.iconURL(app.id, size: 256), name: app.name, size: 64).sensitive(10)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Ship").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(app.name).font(.system(size: 28, weight: .bold, design: .rounded)).sensitive(10)
                    WindowsMark(size: 18)
                }
                HStack(spacing: 8) {
                    Chip(text: (link.path as NSString).abbreviatingWithTildeInPath, symbol: "folder", mono: true, sensitive: true)
                    if let p = project { Chip(text: "pubspec \(p.version)+\(p.buildNumber)", symbol: "doc.text", mono: true) }
                    Chip(text: "Windows · Microsoft Store", symbol: "pc")
                }
            }
            Spacer()
        }
    }

    private var releaseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Release", systemImage: "number").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Version").font(.caption).foregroundStyle(.secondary)
                TextField("1.0.0", text: $version).textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
            }
            Text("The package version is \(version.isEmpty ? "x.y.z" : version).0. Each Store release needs a higher one than the last.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    /// msix_config in pubspec.yaml, written once by `msstore init`.
    private var storeSetupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Store setup in the project", systemImage: "shippingbox").font(.headline)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: msixConfig == true ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(msixConfig == true ? Palette.mint : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("msix_config in pubspec.yaml").font(.callout)
                    if msixConfig == false {
                        Text("Run this once in the project, then commit pubspec.yaml and push. It adds the msix package and the Store identity.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("msstore init .").font(.callout.monospaced()).textSelection(.enabled)
                            Button { copyToPasteboard("msstore init .") } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                        }
                        Link("Install the Microsoft Store CLI", destination: URL(string: "https://learn.microsoft.com/windows/apps/publish/msstore-dev-cli/overview")!)
                            .font(.caption)
                    } else if let id = storeIDInPubspec, id != storeID {
                        Text("Its msstore_appId is \(id), not \(storeID).").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button { checkProject() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Check again")
            }
        }
        .card()
    }

    private var rolloutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Rollout", systemImage: "chart.bar").font(.headline)
            Picker("Rollout", selection: $gradual) {
                Text("Everyone").tag(false)
                Text("Gradual").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            if gradual {
                HStack {
                    Slider(value: $rollout, in: 1...99, step: 1)
                    Text("\(Int(rollout))%").font(.callout.monospacedDigit()).frame(width: 44)
                }
                Text("Raise or finish the rollout later in Partner Center.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var rehearsalCard: some View {
        Toggle(isOn: $rehearsal) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Rehearsal")
                Text("Build the MSIX on GitHub without uploading it.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .card()
    }

    private var launchBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) { Text(app.name).sensitive(); Text(version.isEmpty ? "" : "\(version).0") }.font(.headline.monospacedDigit())
                Text(rehearsal ? "Rehearsal · build on GitHub" : "GitHub build → submission → certification\(gradual ? " · \(Int(rollout))%" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let launchError { Text(launchError).font(.caption).foregroundStyle(Palette.ember).lineLimit(2) }
            Button { confirming = true } label: {
                Label(rehearsal ? "Rehearse" : "Launch", systemImage: rehearsal ? "play.circle" : "paperplane.fill")
                    .font(.headline).padding(.horizontal, 18).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(rehearsal ? Palette.violet : Color(red: 0.0, green: 0.47, blue: 0.84))
            .controlSize(.extraLarge)
            .disabled(!ready)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 26).padding(.bottom, 18)
    }

    private func checkProject() {
        let text = (try? String(contentsOf: link.url.appendingPathComponent("pubspec.yaml"), encoding: .utf8)) ?? ""
        msixConfig = text.contains("msix_config:")
        storeIDInPubspec = text.split(separator: "\n").first { $0.contains("msstore_appId:") }
            .map { $0.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) } ?? "" }
    }

    private func load() async {
        do { project = try FlutterProject.inspect(link.url, recipe: link.recipe) } catch {
            loadError = error.localizedDescription
            return
        }
        checkProject()
        if model.apps[app.id]?.detailed != true { await model.refresh(appID: app.id) }
        guard let project else { return }
        version = project.version
        build = project.buildNumber
        notes = Drafts.load(for: app.id)
        if let r = link.recipe.msRollout, r > 0 { gradual = true; rollout = Double(r) }
    }

    private func launch() {
        guard let project, let repo else { return }
        let percent = gradual ? Int(rollout) : 0
        model.updateRecipe(appID: app.id) { $0.msRollout = percent }
        var plan = ReleasePlan(app: app, projectRoot: project.root, version: version, build: build, recipe: recipe,
                               teamID: nil, groups: [], whatsNew: notes.notes(in: locales), submitForReview: false, rehearsal: rehearsal)
        plan.platform = .windows
        plan.cloud = CloudBuild(repo: repo, target: .windows)
        plan.microsoft = MSTarget(appID: storeID, rollout: percent)
        do {
            _ = try model.launch(plan)
            if !rehearsal { Drafts.clear(for: app.id) }
            onLaunch()
        } catch {
            launchError = error.localizedDescription
        }
    }
}

import AppKit
import ReleaseKit
import SwiftUI

/// From nothing to a first build on both stores: the Flutter project, the
/// bundle id, the store records, TestFlight groups and the upload key. The
/// steps Apple and Google keep to their websites open there, with the
/// values to paste, and turn green by themselves once the app shows up.
struct NewAppWizard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.privacyMode) private var privacy

    // Project
    @State private var createNew = false
    @State private var path = ""
    @State private var parent = (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer").path as NSString).abbreviatingWithTildeInPath
    @State private var projectName = ""
    @State private var org = "com.example"
    @State private var creating = false
    @State private var createLine = ""
    @State private var candidates: [FlutterProject] = []
    @State private var project: FlutterProject?
    @State private var appName = ""

    // App Store
    @State private var appleTeam: UUID?
    @State private var bundleRegistered = false
    @State private var ascApp: ASCApp?
    @State private var waitingApple = false
    @State private var groupsMade = false
    @State private var appleBusy = false
    @State private var appleError: String?

    // Google Play
    @State private var playTeam: UUID?
    @State private var playVisible = false
    @State private var waitingPlay = false
    @State private var uploadKey: URL?
    @State private var keyBusy = false
    @State private var playError: String?
    @State private var copied: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.brand)
                    Image(systemName: "sparkles").font(.title2.weight(.semibold)).foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New app").font(.title2.bold())
                    Text("From a Flutter project to its first build on the App Store and Google Play.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(24)
            ScrollView {
                VStack(spacing: 16) {
                    step(1, "Project", done: project != nil) { projectStep }
                    if project != nil {
                        step(2, "App Store", done: ascApp != nil && groupsMade, symbol: "apple.logo") { appleStep }
                        step(3, "Google Play", done: playVisible && (project?.hasUploadKey ?? false) || playVisible && uploadKey != nil, play: true) { playStep }
                        step(4, "First release", done: false, symbol: "paperplane.fill") { releaseStep }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 760, height: 840)
        .task {
            appleTeam = model.appleTeams.first?.team.id
            playTeam = model.playTeams.first?.team.id
            let roots = ProjectScanner.roots(model: model)
            candidates = await Task.detached { ProjectScanner.projects(in: roots) }.value
        }
    }

    // MARK: Steps

    @ViewBuilder
    private func step<Content: View>(_ n: Int, _ title: String, done: Bool, symbol: String? = nil, play: Bool = false,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(done ? Palette.mint : Palette.indigo.opacity(0.18))
                    if done { Image(systemName: "checkmark").font(.caption.weight(.heavy)).foregroundStyle(Palette.ink) }
                    else { Text("\(n)").font(.callout.weight(.bold)).foregroundStyle(Palette.indigo) }
                }
                .frame(width: 28, height: 28)
                if play { PlayMark(size: 16) } else if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                Text(title).font(.headline)
                Spacer()
            }
            content()
        }
        .card(radius: 18)
    }

    private var projectStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $createNew) {
                Text("Use a Flutter project").tag(false)
                Text("Create a new one").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if let project {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(Palette.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((project.root.path as NSString).abbreviatingWithTildeInPath).font(.callout.monospaced()).sensitive()
                        Text("iOS \(project.iosBundleID ?? "–") · Android \(project.androidPackage ?? "–") · \(project.version)+\(project.buildNumber)")
                            .font(.caption).foregroundStyle(.secondary).sensitive(4)
                    }
                    Spacer()
                    Button("Change") { self.project = nil }.buttonStyle(.borderless)
                }
                LabeledContent("Name on the stores") {
                    TextField("Name", text: $appName).labelsHidden().multilineTextAlignment(.trailing).sensitive(5)
                }
            } else if createNew {
                LabeledContent("Folder") { TextField("Folder", text: $parent).labelsHidden().font(.callout.monospaced()).sensitive(4) }
                LabeledContent("Project name") { TextField("my_app", text: $projectName).labelsHidden().font(.callout.monospaced()) }
                LabeledContent("Organization") { TextField("com.yourcompany", text: $org).labelsHidden().font(.callout.monospaced()) }
                Text("Bundle id \(org).\(camel(projectName)) on iOS, package \(org).\(projectName) on Android. Change them later in the project if you like.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if creating { ProgressView().controlSize(.small); Text(createLine).font(.caption).lineLimit(1).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Create project") { Task { await createProject() } }
                        .buttonStyle(.glassProminent).tint(Palette.indigo)
                        .disabled(creating || projectName.isEmpty || !projectName.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" })
                }
            } else {
                if !candidates.isEmpty {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(candidates, id: \.root) { p in
                                Button { use(p.root) } label: {
                                    HStack {
                                        Text((p.root.path as NSString).abbreviatingWithTildeInPath).font(.callout.monospaced()).sensitive(4)
                                        Spacer()
                                        Text(p.iosBundleID ?? p.androidPackage ?? "").font(.caption).foregroundStyle(.secondary).sensitive(4)
                                    }
                                    .padding(8)
                                    .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
                HStack {
                    TextField("Path", text: $path, prompt: Text("Or paste a folder path")).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                        .onSubmit { use(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)) }
                    Button("Use") { use(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)) }.disabled(path.isEmpty)
                }
            }
        }
    }

    private var appleStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.appleTeams.isEmpty {
                Text("Connect an App Store Connect team first.").foregroundStyle(.secondary)
                Button("Connect App Store Connect…") { model.connecting = .apple }.buttonStyle(.glass)
            } else if let bundle = project?.iosBundleID {
                LabeledContent("Team") {
                    Picker("Team", selection: $appleTeam) {
                        ForEach(model.appleTeams, id: \.team.id) { Text($0.team.name).tag(Optional($0.team.id)) }
                    }
                    .labelsHidden().fixedSize().sensitive(5)
                }
                row(bundleRegistered, "Register the bundle id", bundle) {
                    Button("Register") { Task { await registerBundle(bundle) } }.disabled(appleBusy)
                }
                row(ascApp != nil, "Create the app in App Store Connect",
                    ascApp.map { _ in "Found it; linked to the project." } ?? (waitingApple ? "Waiting for it to show up…" : "Apple keeps this step on its website.")) {
                    Button("Open App Store Connect") {
                        NSWorkspace.shared.open(URL(string: "https://appstoreconnect.apple.com/apps")!)
                        Task { await waitForApple(bundle) }
                    }
                }
                if ascApp == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("In App Store Connect: Apps → + → New App, then paste:").font(.caption).foregroundStyle(.secondary)
                        copyField("Platform", "iOS")
                        copyField("Name", appName)
                        copyField("Primary language", Locale.current.localizedString(forIdentifier: "en-US") ?? "English (U.S.)")
                        copyField("Bundle ID", bundle)
                        copyField("SKU", bundle)
                    }
                    .padding(.leading, 34)
                }
                row(groupsMade, "TestFlight groups", "\"Internal testers\" gets every build; \"Public testers\" has a public link.") {
                    Button("Create") { Task { await makeGroups() } }.disabled(ascApp == nil || appleBusy)
                }
                if let appleError { Label(appleError, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            } else {
                Text("The project has no iOS app.").foregroundStyle(.secondary)
            }
        }
    }

    private var playStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.playTeams.isEmpty {
                Text("Sign in to Google Play first.").foregroundStyle(.secondary)
                Button("Connect Google Play…") { model.connecting = .google }.buttonStyle(.glass)
            } else if let package = project?.androidPackage, let project {
                LabeledContent("Account") {
                    Picker("Account", selection: $playTeam) {
                        ForEach(model.playTeams, id: \.team.id) { Text($0.account.name).tag(Optional($0.team.id)) }
                    }
                    .labelsHidden().fixedSize().sensitive(5)
                }
                row(playVisible, "Create the app in Play Console",
                    playVisible ? "Found it; linked to the project." : (waitingPlay ? "Waiting for it to show up…" : "Google keeps this step on its website.")) {
                    Button("Open Play Console") {
                        NSWorkspace.shared.open(URL(string: "https://play.google.com/console/developers")!)
                        Task { await waitForPlay(package) }
                    }
                }
                if !playVisible {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("In Play Console: Create app, then paste the name; the package is set by the first upload:").font(.caption).foregroundStyle(.secondary)
                        copyField("App name", appName)
                        copyField("Package", package)
                    }
                    .padding(.leading, 34)
                }
                row(project.hasUploadKey || uploadKey != nil, "Upload key",
                    project.hasUploadKey ? "android/key.properties is set." : (uploadKey != nil ? "Made it; the password is in your Keychain. Back up the key file." : "Play needs every release signed with the same upload key.")) {
                    if !project.hasUploadKey && uploadKey == nil {
                        Button("Create") { Task { await makeKey(project, package) } }.disabled(keyBusy)
                    } else if let uploadKey {
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([uploadKey]) }
                    }
                }
                if (project.hasUploadKey || uploadKey != nil) && !UploadKey.gradleReadsKeyProperties(project.root) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Release builds don't use key.properties yet. Add this to android/app/build.gradle\(UploadKey.usesKotlinGradle(project.root) ? ".kts" : ""):",
                              systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        let snippet = UploadKey.gradleSnippet(kotlin: UploadKey.usesKotlinGradle(project.root))
                        Text(snippet).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
                        Button("Copy") { copyToPasteboard(snippet) }.buttonStyle(.glass).controlSize(.small)
                    }
                    .padding(.leading, 34)
                }
                if let playError { Label(playError, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            } else {
                Text("The project has no Android app.").foregroundStyle(.secondary)
            }
        }
    }

    private var releaseStep: some View {
        HStack(spacing: 12) {
            Button {
                if let id = ascApp?.id { dismiss(); model.route = .ship(id) }
            } label: { Label("Ship to TestFlight", systemImage: "apple.logo").padding(.horizontal, 6) }
                .buttonStyle(.glassProminent).tint(Palette.indigo).disabled(ascApp == nil)
            Button {
                if let p = project?.androidPackage { dismiss(); model.route = .ship("play:\(p)") }
            } label: { Label("Ship to Google Play", systemImage: "play.fill").padding(.horizontal, 6) }
                .buttonStyle(.glassProminent).tint(Color(red: 0.0, green: 0.62, blue: 0.45)).disabled(!playVisible)
            Spacer()
            Text("A first Play release goes in as a draft.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func row<A: View>(_ ok: Bool, _ title: String, _ detail: String, @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? Palette.mint : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).sensitive(detail.contains(".") && !detail.contains(" ") ? 4 : 0)
            }
            Spacer()
            if !ok { action().buttonStyle(.glass).controlSize(.small) }
        }
    }

    private func copyField(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.callout.monospaced()).textSelection(.enabled).sensitive(label == "Platform" ? 0 : 4)
            Spacer()
            Button(copied == label ? "Copied" : "Copy") {
                copyToPasteboard(value)
                copied = label
            }
            .buttonStyle(.borderless).font(.caption)
        }
    }

    // MARK: Actions

    private func camel(_ s: String) -> String {
        let parts = s.split(separator: "_")
        return (parts.first.map(String.init) ?? "") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    private func use(_ url: URL) {
        guard let p = try? FlutterProject.inspect(url) else { appleError = "No Flutter project at \(url.path)"; return }
        project = p
        appName = p.name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        Task { await refreshStates() }
    }

    private func createProject() async {
        creating = true
        defer { creating = false }
        do {
            let folder = try await NewFlutterApp.create(parent: URL(fileURLWithPath: NSString(string: parent).expandingTildeInPath),
                                                        name: projectName, org: org) { line in
                Task { @MainActor in createLine = line }
            }
            use(folder)
        } catch {
            appleError = error.localizedDescription
        }
    }

    private func refreshStates() async {
        guard let project else { return }
        if let bundle = project.iosBundleID, let team = appleTeamValue, let c = try? model.client(for: team) {
            bundleRegistered = (try? await c.bundleID(bundle)) != nil
            ascApp = try? await c.app(bundleID: bundle)
            if let a = ascApp {
                groupsMade = !((try? await c.betaGroups(appID: a.id, withTesterCounts: false)) ?? []).isEmpty
                model.link(appID: a.id, path: project.root.path)
            }
        }
        if let package = project.androidPackage, let team = playTeamValue, let c = try? model.playClient(for: team) {
            playVisible = (try? await c.overview(package: package)) != nil
        }
    }

    private var appleTeamValue: Team? { model.appleTeams.first { $0.team.id == appleTeam }?.team }
    private var playTeamValue: Team? { model.playTeams.first { $0.team.id == playTeam }?.team }

    private func registerBundle(_ bundle: String) async {
        guard let team = appleTeamValue else { return }
        appleBusy = true
        defer { appleBusy = false }
        do {
            _ = try await model.client(for: team).registerBundleID(bundle, name: appName.isEmpty ? bundle : appName)
            bundleRegistered = true
        } catch { appleError = error.localizedDescription }
    }

    private func waitForApple(_ bundle: String) async {
        guard let team = appleTeamValue, let c = try? model.client(for: team), !waitingApple else { return }
        waitingApple = true
        defer { waitingApple = false }
        for _ in 0..<180 where ascApp == nil {
            if let a = try? await c.app(bundleID: bundle) {
                ascApp = a
                bundleRegistered = true
                await model.refresh(team: team)
                if let root = project?.root { model.link(appID: a.id, path: root.path) }
                return
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func makeGroups() async {
        guard let team = appleTeamValue, let a = ascApp else { return }
        appleBusy = true
        defer { appleBusy = false }
        do {
            let c = try model.client(for: team)
            let existing = try await c.betaGroups(appID: a.id, withTesterCounts: false).map(\.name)
            if !existing.contains("Internal testers") { try await c.createBetaGroup(appID: a.id, name: "Internal testers", isInternal: true) }
            if !existing.contains("Public testers") { try await c.createBetaGroup(appID: a.id, name: "Public testers", isInternal: false) }
            groupsMade = true
            await model.refresh(appID: a.id)
        } catch { appleError = error.localizedDescription }
    }

    private func waitForPlay(_ package: String) async {
        guard let team = playTeamValue, let c = try? model.playClient(for: team), !waitingPlay else { return }
        waitingPlay = true
        defer { waitingPlay = false }
        for _ in 0..<180 where !playVisible {
            if (try? await c.overview(package: package)) != nil {
                playVisible = true
                if !(team.packages ?? []).contains(package) { model.setPackages((team.packages ?? []) + [package], team: team) }
                if let root = project?.root { model.link(appID: "play:\(package)", path: root.path) }
                return
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func makeKey(_ project: FlutterProject, _ package: String) async {
        keyBusy = true
        defer { keyBusy = false }
        do {
            uploadKey = try await UploadKey.create(projectRoot: project.root, package: package, owner: appName.isEmpty ? package : appName)
            if !(await UploadKey.keyPropertiesIgnored(project.root)) {
                playError = "git does not ignore android/key.properties in this project. Add it to android/.gitignore before you commit."
            }
            self.project = try? FlutterProject.inspect(project.root)
        } catch { playError = error.localizedDescription }
    }
}

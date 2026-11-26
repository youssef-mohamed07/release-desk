import AppKit
import ReleaseKit
import SwiftUI

/// "Build on: This Mac / GitHub Actions" for the Ship screens, with the
/// checklist a cloud build needs: GitHub sign-in, the workflow on the default
/// branch, and the repository's secrets.
struct CloudBuildCard: View {
    let app: ASCApp
    let link: ProjectLink
    let target: CloudTarget
    @Binding var onGitHub: Bool
    @Binding var repo: GitHubRepo?
    @Binding var ready: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.privacyMode) private var privacy
    @State private var ghUser: String?
    @State private var ghWorkflow: Bool?
    @State private var ghSecrets: Set<String>?
    @State private var ghError: String?
    @State private var ghBusy = false
    @State private var wroteWorkflow: URL?
    @State private var confirmSecrets = false
    @State private var flutterVersion: String?

    private var secretsOK: Bool { ghSecrets.map { s in target.secretNames.allSatisfy(s.contains) } ?? false }
    private var missingSecrets: [String] { ghSecrets.map { s in target.secretNames.filter { !s.contains($0) } } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Build on", systemImage: "hammer").font(.headline)
                Spacer()
                Picker("Build on", selection: $onGitHub.animation(.snappy)) {
                    Text("This Mac").tag(false)
                    Text("GitHub Actions").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if onGitHub {
                if ghBusy && repo == nil {
                    HStack { ProgressView().controlSize(.small); Text("Looking at the repository…").foregroundStyle(.secondary) }
                } else if let repo {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.secondary)
                        Text(repo.fullName).font(.callout.monospaced()).sensitive()
                        Text("· \(repo.projectDir)").font(.callout.monospaced()).foregroundStyle(.secondary).sensitive()
                        Spacer()
                        Link(destination: repo.actionsURL) { Image(systemName: "arrow.up.right.square") }.help("Open Actions on GitHub")
                    }
                    checkRow(ok: ghUser != nil, title: ghUser.map { "Signed in to GitHub as \($0)" } ?? "Sign in to GitHub",
                             hint: ghUser == nil ? "Run gh auth login in Terminal, then check again." : nil, sensitiveTitle: ghUser != nil) { EmptyView() }
                    checkRow(ok: ghWorkflow == true, title: "Workflow on the default branch",
                             hint: wroteWorkflow != nil && ghWorkflow != true ? "Added to the project. Commit and push it, then check again." : nil) {
                        if ghWorkflow != true {
                            Button(wroteWorkflow == nil ? "Add to project" : "Show file") {
                                if let f = wroteWorkflow { NSWorkspace.shared.activateFileViewerSelecting([f]) } else { writeWorkflow() }
                            }
                            .buttonStyle(.glass).controlSize(.small)
                        }
                    }
                    checkRow(ok: secretsOK, title: "Secrets " + target.secretNames.joined(separator: ", "),
                             hint: missingSecrets.isEmpty ? nil : "Missing: \(missingSecrets.joined(separator: ", "))") {
                        if ghSecrets != nil && !secretsOK {
                            Button(target == .ios ? "Set from this team's key" : "Set from the upload key") { confirmSecrets = true }
                                .buttonStyle(.glass).controlSize(.small)
                        }
                    }
                    HStack {
                        Text(target == .ios
                             ? "A GitHub macOS runner archives, signs and uploads; this Mac does the TestFlight steps. macOS minutes on private repositories cost more than Linux ones."
                             : "A GitHub Linux runner builds and signs the app bundle; Release Desk downloads it and releases it on Play. No Google credential goes to GitHub.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { Task { await check() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Check again").disabled(ghBusy)
                    }
                } else {
                    Text(ghError ?? "This project has no GitHub remote (origin).").font(.callout).foregroundStyle(.secondary)
                }
                if let ghError, repo != nil { Label(ghError, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            } else {
                Text(target == .ios ? "Xcode and Flutter on this Mac archive, sign and upload."
                                    : "Flutter on this Mac builds the app bundle with your upload key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
        .task { if onGitHub && repo == nil { await check() } }
        .onChange(of: onGitHub) {
            model.updateRecipe(appID: app.id) { r in
                if target == .ios { r.buildOn = onGitHub ? "github" : nil } else { r.androidBuildOn = onGitHub ? "github" : nil }
            }
            if onGitHub && repo == nil { Task { await check() } }
        }
        .onChange(of: [ghUser != nil, ghWorkflow == true, secretsOK]) { ready = ghUser != nil && ghWorkflow == true && secretsOK }
        .alert("Set the repository's secrets?", isPresented: $confirmSecrets) {
            Button("Set secrets") { Task { await setSecrets() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            let where_ = privacy ? "the repository" : repo?.fullName ?? "the repository"
            Text(target == .ios
                 ? "Release Desk puts this team's App Store Connect key into \(where_)'s Actions secrets with the GitHub CLI. Anyone who can change its workflows can then use the key."
                 : "Release Desk puts the upload keystore and its passwords from android/key.properties into \(where_)'s Actions secrets with the GitHub CLI. Anyone who can change its workflows can then sign with it.")
        }
    }

    @ViewBuilder
    private func checkRow<Accessory: View>(ok: Bool, title: String, hint: String?, sensitiveTitle: Bool = false,
                                           @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Palette.mint : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).sensitive(sensitiveTitle ? 5 : 0)
                if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            accessory()
        }
    }

    private func check() async {
        ghBusy = true
        ghError = nil
        defer { ghBusy = false }
        if repo == nil { repo = await GitHubRepo.detect(link.url) }
        guard let repo else { return }
        do {
            ghUser = try await model.github.login()
            ghWorkflow = try await model.github.hasWorkflow(repo, file: target.workflowFile)
            ghSecrets = try await model.github.secretsPresent(repo)
        } catch {
            ghError = error.localizedDescription
        }
        if flutterVersion == nil, let out = try? await Shell.capture("flutter", ["--version", "--machine"], cwd: link.url),
           let start = out.firstIndex(of: "{"), let json = try? JSONDecoder().decode(JSONValue.self, from: Data(out[start...].utf8)) {
            flutterVersion = json["frameworkVersion"].string
        }
    }

    private func writeWorkflow() {
        guard let repo else { return }
        var root = link.url
        if repo.projectDir != "." { for _ in repo.projectDir.split(separator: "/") { root.deleteLastPathComponent() } }
        let file = root.appendingPathComponent(".github/workflows/\(target.workflowFile)")
        let yaml = target.yaml(projectDir: repo.projectDir, recipe: link.recipe,
                               teamID: model.team(ofApp: app.id)?.teamID, flutterVersion: flutterVersion)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try yaml.write(to: file, atomically: true, encoding: .utf8)
            wroteWorkflow = file
        } catch {
            ghError = error.localizedDescription
        }
    }

    private func setSecrets() async {
        guard let repo else { return }
        ghBusy = true
        defer { ghBusy = false }
        do {
            try await model.setCloudSecrets(appID: app.id, repo: repo, target: target, projectRoot: link.url)
            ghSecrets = try await model.github.secretsPresent(repo)
        } catch {
            ghError = error.localizedDescription
        }
    }
}

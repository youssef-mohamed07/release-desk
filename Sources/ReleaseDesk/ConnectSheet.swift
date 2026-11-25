import AppKit
import ReleaseKit
import SwiftUI
import UniformTypeIdentifiers

/// Connect a store team: an App Store Connect API key or a Google Play
/// service account. Finds key files on its own, takes a path, a drop or a
/// file picker, and checks with the store before anything is saved.
struct ConnectSheet: View {
    @State var provider: StoreProvider
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var found: [URL] = []
    @State private var keyFile: URL?
    @State private var secret: String?
    @State private var path = ""
    @State private var keyID = ""
    @State private var issuerID = ""
    @State private var accountChoice: UUID?
    @State private var accountName = ""
    @State private var email = ""
    @State private var teamName = ""
    @State private var packages = ""
    @State private var suggestions: [String] = []
    @State private var verifying = false
    @State private var verified: Verified?
    @State private var error: String?
    @State private var importing = false
    @State private var dropping = false
    // Google sign-in
    @State private var oauthClient: OAuthClient? = OAuthClient.saved()
    @State private var clientFiles: [URL] = []
    @State private var importingClient = false
    @State private var googleUser: GoogleUser?
    @State private var signingIn = false
    @State private var foundApps: [PlayApp] = []
    @State private var appsUnavailable = false
    @State private var useServiceAccount = false

    enum Verified {
        case apple(teamID: String?, apps: [ASCApp])
        case google(email: String, project: String, packages: [(String, String?)])
    }

    private var accounts: [Account] { model.workspace.accounts.filter { $0.provider == provider } }
    private var isApple: Bool { provider == .apple }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                if isApple {
                    keySection
                } else {
                    googleSection
                    if useServiceAccount {
                        keySection
                        packagesSection
                    } else if googleUser != nil && appsUnavailable {
                        packagesSection
                    }
                }
                placeSection
                if verifying || verified != nil || (error != nil && (isApple || useServiceAccount)) { checkSection }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            footer
        }
        .frame(width: 660, height: 760)
        .fileImporter(isPresented: $importing, allowedContentTypes: isApple ? [UTType(filenameExtension: "p8") ?? .data, .data] : [.json]) { result in
            if case .success(let url) = result { load(url) }
        }
        .onAppear {
            scan()
            if let url = model.droppedKey { load(url); model.droppedKey = nil }
        }
        .onChange(of: provider) { reset(); scan() }
        .onChange(of: keyID) { verified = nil }
        .onChange(of: issuerID) { verified = nil }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in load(url) } }
            }
            return true
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProviderMark(provider: provider, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect a team").font(.title2.bold())
                    Text(isApple ? "One App Store Connect API key per team: Users and Access → Integrations → App Store Connect API."
                                 : "Sign in with the Google account that has Play Console access. Release Desk sees the apps it sees.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Picker("Store", selection: $provider) {
                Text("App Store Connect").tag(StoreProvider.apple)
                Text("Google Play").tag(StoreProvider.google)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(24)
    }

    private var userMode: Bool { !isApple && !useServiceAccount }

    private var googleSection: some View {
        Section("Your Google account") {
            if let user = googleUser {
                HStack {
                    Label("Signed in as \(user.email)", systemImage: "checkmark.seal.fill").foregroundStyle(Palette.mint).sensitive(5)
                    Spacer()
                    Button("Use another account") { signIn() }.buttonStyle(.glass).controlSize(.small)
                }
                if !foundApps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(foundApps.count) apps on Play").font(.caption).foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(foundApps) { a in
                                Label(a.name, systemImage: "app.fill").font(.caption).sensitive(4)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.quaternary.opacity(0.6), in: .capsule)
                            }
                        }
                    }
                } else if appsUnavailable {
                    Text("Play did not list your apps yet (the Reporting API can take a few minutes after it is turned on). Name them below, or connect now and refresh later.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Button { signIn() } label: {
                        HStack(spacing: 10) {
                            if signingIn { ProgressView().controlSize(.small) } else { GoogleG(size: 18) }
                            Text(signingIn ? "Waiting for your browser…" : "Sign in with Google").font(.headline)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Color(red: 0.26, green: 0.52, blue: 0.96))
                    .controlSize(.large)
                    .disabled(oauthClient == nil || signingIn)
                    Text("Opens your browser. Pick the Google account that has access to Play Console; Release Desk sees the apps that account sees.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error, userMode { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Palette.ember).font(.callout) }
                }
            }
            if let c = oauthClient {
                LabeledContent("Sign-in client") {
                    HStack {
                        Text(c.projectID ?? c.clientID.prefix(12) + "…").font(.caption.monospaced()).foregroundStyle(.secondary).sensitive(4)
                        Button("Change…") { importingClient = true }.buttonStyle(.borderless).font(.caption)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Release Desk needs its Google sign-in client once: the client_secret_….json of a Desktop OAuth client.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        ForEach(clientFiles, id: \.self) { f in
                            Button { importClient(f) } label: {
                                Label(String(f.lastPathComponent.prefix(28)) + "…", systemImage: "doc.badge.gearshape").font(.caption.monospaced()).sensitive(4)
                            }
                            .buttonStyle(.glass).controlSize(.small)
                        }
                        Button("Choose…") { importingClient = true }.controlSize(.small)
                    }
                }
            }
            Toggle("Use a service account key instead", isOn: $useServiceAccount.animation(.snappy))
                .font(.callout)
        }
        .fileImporter(isPresented: $importingClient, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { importClient(url) }
        }
    }

    private func importClient(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let c = try OAuthClient(json: String(contentsOf: url, encoding: .utf8))
            try c.save()
            oauthClient = c
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func signIn() {
        guard let client = oauthClient else { return }
        signingIn = true
        error = nil
        Task {
            defer { signingIn = false }
            do {
                let user = try await GoogleSignIn.signIn(client: client) { url in
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                }
                NSApp.activate()
                googleUser = user
                if teamName.isEmpty { teamName = "Play Console" }
                let apps = try? await PlayClient(auth: .user(user)).searchApps()
                foundApps = apps ?? []
                appsUnavailable = apps == nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var keySection: some View {
        Section(isApple ? "Private key (.p8)" : "Service account key (.json)") {
            if !found.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Found on this Mac").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(found, id: \.self) { url in
                                Button { load(url) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: keyFile == url ? "checkmark.circle.fill" : (isApple ? "key.horizontal" : "doc.badge.gearshape"))
                                        Text(url.lastPathComponent).font(.callout.monospaced()).sensitive(5)
                                    }
                                    .padding(.horizontal, 4)
                                }
                                .buttonStyle(.glass)
                                .tint(keyFile == url ? Palette.indigo : nil)
                            }
                        }
                    }
                }
            }
            HStack {
                Image(systemName: secret == nil ? "square.and.arrow.down.on.square" : "checkmark.seal.fill")
                    .foregroundStyle(secret == nil ? Color.secondary : Palette.mint)
                TextField("Path", text: $path, prompt: Text(isApple ? "Drop, choose or paste the path of AuthKey_….p8" : "Drop, choose or paste the path of the .json key"))
                    .labelsHidden()
                    .font(.callout.monospaced())
                    .sensitive(5)
                    .onSubmit { load(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)) }
                Button("Choose…") { importing = true }
            }
            .padding(.vertical, 4)
            .background(dropping ? Palette.indigo.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
            if isApple {
                LabeledContent("Key ID") {
                    TextField("Key ID", text: $keyID, prompt: Text("e.g. 2X9R4HXF34"))
                        .labelsHidden().multilineTextAlignment(.trailing).font(.body.monospaced()).sensitive(5)
                }
                LabeledContent("Issuer ID") {
                    TextField("Issuer ID", text: $issuerID, prompt: Text("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
                        .labelsHidden().multilineTextAlignment(.trailing).font(.body.monospaced()).sensitive(5)
                }
            } else if let secret, let sa = try? ServiceAccount(json: secret) {
                LabeledContent("Service account") { Text(sa.email).font(.callout.monospaced()).textSelection(.enabled).sensitive(5) }
                LabeledContent("Cloud project") { Text(sa.projectID).font(.callout.monospaced()).sensitive(5) }
            }
        }
    }

    private var packagesSection: some View {
        Section {
            TextField("Package names", text: $packages, prompt: Text("com.example.app, com.example.other"), axis: .vertical)
                .font(.callout.monospaced())
                .sensitive(5)
                .lineLimit(1...4)
                .onChange(of: packages) { verified = nil }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("From your projects").font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(suggestions, id: \.self) { s in
                            let on = packageList.contains(s)
                            Button {
                                var list = packageList
                                if on { list.removeAll { $0 == s } } else { list.append(s) }
                                packages = list.joined(separator: ", ")
                            } label: {
                                Label(s, systemImage: on ? "checkmark" : "plus").font(.caption.monospaced()).sensitive(4)
                            }
                            .buttonStyle(.glass).controlSize(.small)
                        }
                    }
                }
            }
        } header: {
            Text("Apps")
        } footer: {
            Text("Play gives a service account no list of the developer's apps unless the Play Developer Reporting API is on in its Cloud project, so name them here. You can add more later.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var placeSection: some View {
        Section("Where it belongs") {
            if !userMode {
            LabeledContent("Account") {
                Picker("Account", selection: $accountChoice) {
                    ForEach(accounts) { a in Text(a.name).tag(Optional(a.id)) }
                    Text("New account…").tag(UUID?.none)
                }
                .labelsHidden()
                .fixedSize()
                .sensitive(accountChoice == nil ? 0 : 5)
            }
            if accountChoice == nil {
                LabeledContent("Account name") {
                    TextField("Account name", text: $accountName, prompt: Text(isApple ? "e.g. My Apple ID" : "e.g. Work Google account"))
                        .labelsHidden().multilineTextAlignment(.trailing).sensitive(5)
                }
                if isApple {
                    LabeledContent("Apple ID email (optional)") {
                        TextField("Apple ID email", text: $email).labelsHidden().multilineTextAlignment(.trailing).sensitive(5)
                    }
                }
            }
            }
            LabeledContent(isApple ? "Team name" : "Developer account name") {
                TextField("Name", text: $teamName, prompt: Text("e.g. Client team"))
                    .labelsHidden().multilineTextAlignment(.trailing).sensitive(5)
            }
        }
    }

    private var checkSection: some View {
        Section("Check") {
            if verifying {
                HStack { ProgressView().controlSize(.small); Text(isApple ? "Asking App Store Connect…" : "Asking Google Play…") }
            } else if let error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Palette.ember)
            } else if let v = verified {
                switch v {
                case .apple(let teamID, let apps):
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Key works · \(apps.count) apps", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Palette.mint)
                        Text(apps.prefix(8).map(\.name).joined(separator: " · ") + (apps.count > 8 ? " …" : ""))
                            .font(.caption).foregroundStyle(.secondary).sensitive(4)
                    }
                case .google(let mail, _, let results):
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Google accepted \(mail)", systemImage: "checkmark.seal.fill").foregroundStyle(Palette.mint).sensitive(4)
                        ForEach(results, id: \.0) { pkg, problem in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: problem == nil ? "checkmark.circle.fill" : "person.badge.key.fill")
                                    .foregroundStyle(problem == nil ? Palette.mint : StateTone.waiting.color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pkg).font(.callout.monospaced()).sensitive(4)
                                    if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        if results.contains(where: { $0.1 != nil }) {
                            HStack {
                                Button("Copy service account email") { copyToPasteboard(mail) }.buttonStyle(.glass).controlSize(.small)
                                Link("Open Play Console users", destination: URL(string: "https://play.google.com/console/developers/users-and-permissions")!)
                                    .font(.caption)
                            }
                            Text("You can connect now; the apps light up once the invite is in.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Label("Keys go to your Keychain, never to a file Release Desk keeps.", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            if userMode {
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .tint(Palette.indigo)
                    .disabled(googleUser == nil || teamName.isEmpty)
            } else if verified == nil {
                Button("Verify") { Task { await verify() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(secret == nil || verifying || (isApple && (keyID.isEmpty || issuerID.isEmpty)))
            } else {
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .tint(Palette.indigo)
                    .disabled(teamName.isEmpty || (accountChoice == nil && accountName.isEmpty))
            }
        }
        .padding(20)
    }

    // MARK: Logic

    private var packageList: [String] {
        packages.split(whereSeparator: { ", \n".contains($0) }).map(String.init).filter { $0.contains(".") }
    }

    private func reset() {
        keyFile = nil; secret = nil; path = ""; keyID = ""; issuerID = ""; verified = nil; error = nil
        accountChoice = accounts.first?.id
    }

    private func scan() {
        accountChoice = accounts.first?.id
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        if isApple {
            let dirs = [".appstoreconnect/private_keys", "private_keys", ".private_keys", "Downloads"].map { home.appendingPathComponent($0) }
            let connected = Set(model.workspace.accounts.flatMap(\.teams).compactMap { t -> String? in
                if case .appStoreConnectKey(let k, _) = t.credential { return k } else { return nil }
            })
            var seen = Set<String>()
            found = dirs.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
                .filter { $0.lastPathComponent.hasPrefix("AuthKey_") && $0.pathExtension == "p8" }
                .filter { !connected.contains(keyIDFrom($0)) && seen.insert(keyIDFrom($0)).inserted }
        } else {
            clientFiles = ((try? fm.contentsOfDirectory(at: home.appendingPathComponent("Downloads"), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("client_secret_") && $0.pathExtension == "json" }
            let connected = Set(model.workspace.accounts.flatMap(\.teams).compactMap { t -> String? in
                if case .playServiceAccount(let e) = t.credential { return e } else { return nil }
            })
            found = ((try? fm.contentsOfDirectory(at: home.appendingPathComponent("Downloads"), includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .filter { $0.pathExtension == "json" && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 20_000 }
                .filter { url in
                    guard let t = try? String(contentsOf: url, encoding: .utf8), t.contains("\"service_account\""),
                          let sa = try? ServiceAccount(json: t) else { return false }
                    return !connected.contains(sa.email)
                }
            let roots = ProjectScanner.roots(model: model)
            Task {
                let packages = await Task.detached { ProjectScanner.projects(in: roots).compactMap(\.androidPackage) }.value
                suggestions = Array(Set(packages)).sorted()
            }
        }
    }

    private func keyIDFrom(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        guard let r = name.range(of: #"AuthKey_([A-Z0-9]+)"#, options: .regularExpression) else { return name }
        return String(name[r].dropFirst("AuthKey_".count))
    }

    private func load(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            error = "Cannot read \(url.path)."
            return
        }
        // The file decides the store.
        if text.contains("\"client_secret\""), !text.contains("\"service_account\"") {
            if provider != .google { provider = .google; scan() }
            useServiceAccount = false
            importClient(url)
            return
        }
        if text.contains("\"service_account\"") {
            useServiceAccount = true
            if provider != .google { provider = .google; scan() }
        } else if text.contains("PRIVATE KEY") {
            if provider != .apple { provider = .apple; scan() }
        } else {
            error = "\(url.lastPathComponent) is neither an App Store Connect key nor a Google service account."
            return
        }
        error = nil
        verified = nil
        keyFile = url
        secret = text
        path = (url.path as NSString).abbreviatingWithTildeInPath
        if provider == .apple, url.lastPathComponent.hasPrefix("AuthKey_") { keyID = keyIDFrom(url) }
        if provider == .google, let sa = try? ServiceAccount(json: text), teamName.isEmpty {
            teamName = sa.projectID.replacingOccurrences(of: "-", with: " ").capitalized
        }
        // A first account of this store gets a name to start from.
        if accountChoice == nil, accountName.isEmpty { accountName = teamName.isEmpty ? provider.title : teamName }
    }

    private func verify() async {
        guard let secret else { return }
        verifying = true
        error = nil
        defer { verifying = false }
        do {
            if isApple {
                let v = try await model.verifyApple(keyID: keyID, issuerID: issuerID, pem: secret)
                verified = .apple(teamID: v.teamID, apps: v.apps)
            } else {
                let sa = try ServiceAccount(json: secret)
                let play = PlayClient(account: sa)
                if let listed = try await play.searchApps() {
                    let extra = listed.map(\.packageName).filter { !packageList.contains($0) }
                    if !extra.isEmpty { packages = (packageList + extra).joined(separator: ", ") }
                }
                var results: [(String, String?)] = []
                for pkg in packageList {
                    do {
                        _ = try await play.overview(package: pkg)
                        results.append((pkg, nil))
                    } catch let e as ReleaseError where e.isPlayPermission {
                        results.append((pkg, "Not invited for this app yet"))
                    } catch {
                        results.append((pkg, error.localizedDescription))
                    }
                }
                verified = .google(email: sa.email, project: sa.projectID, packages: results)
            }
        } catch {
            let text = error.localizedDescription
            self.error = isApple && text.contains("401")
                ? "Apple did not accept this key. Check the Key ID and Issuer ID, and that the key is an App Store Connect API key (not an APNs key)."
                : text
        }
    }

    private func connect() {
        if userMode, let user = googleUser {
            do {
                let existing = model.workspace.accounts.first { $0.provider == .google && $0.email == user.email }?.id
                try model.connectGoogleUser(user, accountID: existing, teamName: teamName,
                                            packages: Array(Set(foundApps.map(\.packageName) + packageList)).sorted())
                dismiss()
            } catch { self.error = error.localizedDescription }
            return
        }
        guard let secret else { return }
        do {
            if isApple {
                var team: String?
                if case .apple(let t, _) = verified { team = t }
                try model.connectApple(accountID: accountChoice, newAccountName: accountName, email: email.isEmpty ? nil : email,
                                       teamName: teamName, teamID: team, keyID: keyID, issuerID: issuerID, pem: secret)
            } else {
                try model.connectGoogle(accountID: accountChoice, newAccountName: accountName, teamName: teamName, json: secret, packages: packageList)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Lays chips out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

/// Google's "G", drawn from four arcs in its colours.
struct GoogleG: View {
    var size: CGFloat = 18
    var body: some View {
        ZStack {
            Circle().trim(from: 0.0, to: 0.25).stroke(Color(red: 0.26, green: 0.52, blue: 0.96), lineWidth: size * 0.2)
            Circle().trim(from: 0.25, to: 0.5).stroke(Color(red: 0.20, green: 0.66, blue: 0.33), lineWidth: size * 0.2)
            Circle().trim(from: 0.5, to: 0.62).stroke(Color(red: 0.98, green: 0.74, blue: 0.02), lineWidth: size * 0.2)
            Circle().trim(from: 0.62, to: 0.9).stroke(Color(red: 0.92, green: 0.26, blue: 0.21), lineWidth: size * 0.2)
            Rectangle().fill(Color(red: 0.26, green: 0.52, blue: 0.96)).frame(width: size * 0.45, height: size * 0.2).offset(x: size * 0.2)
        }
        .frame(width: size * 0.8, height: size * 0.8)
        .padding(size * 0.1)
        .background(.white, in: .circle)
    }
}

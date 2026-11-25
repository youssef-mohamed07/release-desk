import ReleaseKit
import SwiftUI
import UniformTypeIdentifiers

/// Adds an App Store Connect team: a .p8 key, its ids, and which account it
/// belongs to. Verifies against Apple before anything is saved.
struct ConnectSheet: View {
    let provider: StoreProvider
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var found: [URL] = []
    @State private var keyFile: URL?
    @State private var pem: String?
    @State private var keyID = ""
    @State private var issuerID = ""
    @State private var accountChoice: UUID?
    @State private var accountName = ""
    @State private var email = ""
    @State private var teamName = ""
    @State private var verifying = false
    @State private var verified: (teamID: String?, apps: [ASCApp])?
    @State private var error: String?
    @State private var importing = false
    @State private var dropping = false

    private var appleAccounts: [Account] { model.workspace.accounts.filter { $0.provider == .apple } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "apple.logo").font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect App Store Connect").font(.title2.bold())
                    Text("One API key per team. Users and Access → Integrations → App Store Connect API.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Form {
                Section("Private key") {
                    if !found.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Found on this Mac").font(.caption).foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(found, id: \.self) { url in
                                        Button { load(url) } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: keyFile == url ? "checkmark.circle.fill" : "key.horizontal")
                                                Text(url.lastPathComponent).font(.callout.monospaced())
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
                        Image(systemName: pem == nil ? "square.and.arrow.down.on.square" : "checkmark.seal.fill")
                            .foregroundStyle(pem == nil ? Color.secondary : Palette.mint)
                        Text(keyFile.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Drop an AuthKey_….p8 here")
                            .foregroundStyle(keyFile == nil ? .secondary : .primary)
                            .font(keyFile == nil ? .body : .callout.monospaced())
                        Spacer()
                        Button("Choose…") { importing = true }
                    }
                    .padding(.vertical, 6)
                    .background(dropping ? Palette.indigo.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
                    .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                        _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                            if let url { Task { @MainActor in load(url) } }
                        }
                        return true
                    }
                    LabeledContent("Key ID") {
                        TextField("Key ID", text: $keyID, prompt: Text("e.g. 2X9R4HXF34"))
                            .labelsHidden().multilineTextAlignment(.trailing).font(.body.monospaced())
                    }
                    LabeledContent("Issuer ID") {
                        TextField("Issuer ID", text: $issuerID, prompt: Text("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
                            .labelsHidden().multilineTextAlignment(.trailing).font(.body.monospaced())
                    }
                }

                Section("Where it belongs") {
                    Picker("Account", selection: $accountChoice) {
                        ForEach(appleAccounts) { a in Text(a.name).tag(Optional(a.id)) }
                        Text("New account…").tag(UUID?.none)
                    }
                    if accountChoice == nil {
                        TextField("Account name", text: $accountName, prompt: Text("e.g. My Apple ID"))
                        TextField("Apple ID email (optional)", text: $email)
                    }
                    TextField("Team name", text: $teamName, prompt: Text("e.g. Client team"))
                }

                if verifying || verified != nil || error != nil {
                    Section("Check") {
                        if verifying {
                            HStack { ProgressView().controlSize(.small); Text("Asking App Store Connect…") }
                        } else if let error {
                            Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Palette.ember)
                        } else if let v = verified {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Key works · team \(v.teamID ?? "unknown") · \(v.apps.count) apps", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(Palette.mint)
                                Text(v.apps.prefix(8).map(\.name).joined(separator: " · ") + (v.apps.count > 8 ? " …" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Label("The key goes to your Keychain, never to a file Release Desk keeps.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if verified == nil {
                    Button("Verify") { Task { await verify() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(pem == nil || keyID.isEmpty || issuerID.isEmpty || verifying)
                } else {
                    Button("Connect") { connect() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                        .disabled(teamName.isEmpty || (accountChoice == nil && accountName.isEmpty))
                }
            }
            .padding(20)
        }
        .frame(width: 640, height: 720)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data, .data]) { result in
            if case .success(let url) = result { load(url) }
        }
        .onAppear(perform: scan)
        .onChange(of: keyID) { verified = nil }
        .onChange(of: issuerID) { verified = nil }
    }

    private func scan() {
        accountChoice = appleAccounts.first?.id
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let dirs = [".appstoreconnect/private_keys", "private_keys", ".private_keys", "Downloads"].map { home.appendingPathComponent($0) }
        let connected = Set(model.workspace.accounts.flatMap(\.teams).compactMap { t -> String? in
            if case .appStoreConnectKey(let k, _) = t.credential { return k } else { return nil }
        })
        var seen = Set<String>()
        found = dirs.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.lastPathComponent.hasPrefix("AuthKey_") && $0.pathExtension == "p8" }
            .filter { url in
                let id = keyIDFrom(url)
                return !connected.contains(id) && seen.insert(id).inserted
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
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("PRIVATE KEY") else {
            error = "\(url.lastPathComponent) is not a .p8 private key."
            return
        }
        error = nil
        verified = nil
        keyFile = url
        pem = text
        if url.lastPathComponent.hasPrefix("AuthKey_") { keyID = keyIDFrom(url) }
    }

    private func verify() async {
        guard let pem else { return }
        verifying = true
        error = nil
        defer { verifying = false }
        do {
            let v = try await model.verifyApple(keyID: keyID, issuerID: issuerID, pem: pem)
            verified = v
        } catch {
            let text = error.localizedDescription
            self.error = text.contains("401") ? "Apple did not accept this key. Check the Key ID and Issuer ID, and that the key is an App Store Connect API key (not an APNs key)." : text
        }
    }

    private func connect() {
        guard let pem else { return }
        do {
            try model.connectApple(accountID: accountChoice, newAccountName: accountName, email: email.isEmpty ? nil : email,
                                   teamName: teamName, teamID: verified?.teamID, keyID: keyID, issuerID: issuerID, pem: pem)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

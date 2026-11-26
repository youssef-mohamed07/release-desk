import AppKit
import ReleaseKit
import SwiftUI

/// Connect Huawei AppGallery (an API client) or the Microsoft Store (a
/// Microsoft Entra app in Partner Center). Checks with the store before
/// anything is saved; the secret goes to the Keychain.
struct StoreConnectForm: View {
    let provider: StoreProvider
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var clientID = ""
    @State private var secret = ""
    @State private var tenantID = ""
    @State private var sellerID = ""
    @State private var packages = ""
    @State private var accountChoice: UUID?
    @State private var accountName = ""
    @State private var teamName = ""
    @State private var verifying = false
    @State private var verifiedApps: [String]?
    @State private var error: String?

    private var isHuawei: Bool { provider == .huawei }
    private var accounts: [Account] { model.workspace.accounts.filter { $0.provider == provider } }
    private var packageList: [String] {
        packages.split(whereSeparator: { ", \n".contains($0) }).map(String.init).filter { $0.contains(".") }
    }
    private var filled: Bool {
        !clientID.trimmed.isEmpty && !secret.trimmed.isEmpty && (isHuawei || (!tenantID.trimmed.isEmpty && !sellerID.trimmed.isEmpty))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if isHuawei {
                        Text("In AppGallery Connect go to Users and permissions → API key → Connect API, and create an API client with Project set to N/A and the Administrator or App administrator role. Only the account holder can make one.")
                            .font(.caption).foregroundStyle(.secondary)
                        field("Client ID", $clientID, prompt: "e.g. 1234567890123456789")
                        LabeledContent("Key") { SecureField("Key", text: $secret).labelsHidden().multilineTextAlignment(.trailing) }
                    } else {
                        Text("In Partner Center go to Account settings → User management → Microsoft Entra applications, add an app with the Manager role, and make a new key. The Seller ID is under Account settings → Legal info → Developer. The app's first submission has to be made in Partner Center.")
                            .font(.caption).foregroundStyle(.secondary)
                        field("Tenant ID", $tenantID, prompt: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
                        field("Client ID", $clientID, prompt: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
                        LabeledContent("Client secret") { SecureField("Client secret", text: $secret).labelsHidden().multilineTextAlignment(.trailing) }
                        field("Seller ID", $sellerID, prompt: "e.g. 12345678")
                    }
                } header: {
                    Text(isHuawei ? "AppGallery Connect API client" : "Partner Center")
                }
                if isHuawei {
                    Section("Apps") {
                        Text("Release Desk lists the team's apps when the API client may read projects. If it can't, name their package names here (you can add more later on the team's page).")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Package names", text: $packages, prompt: Text("com.example.app, com.example.other"), axis: .vertical)
                            .lineLimit(2...4).sensitive(5)
                    }
                }
                Section("Where it belongs") {
                    LabeledContent("Account") {
                        Picker("Account", selection: $accountChoice) {
                            ForEach(accounts) { a in Text(a.name).tag(Optional(a.id)) }
                            Text("New account…").tag(UUID?.none)
                        }
                        .labelsHidden().fixedSize().sensitive(accountChoice == nil ? 0 : 5)
                    }
                    if accountChoice == nil { field("Account name", $accountName, prompt: isHuawei ? "e.g. Huawei developer account" : "e.g. Partner Center") }
                    field(isHuawei ? "Team name" : "Account label", $teamName, prompt: "e.g. Client team")
                }
                if verifying || verifiedApps != nil || error != nil {
                    Section("Check") {
                        if verifying {
                            HStack { ProgressView().controlSize(.small); Text(isHuawei ? "Asking AppGallery Connect…" : "Asking Partner Center…") }
                        } else if let error {
                            Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Palette.ember)
                        } else if let apps = verifiedApps {
                            Label(apps.isEmpty ? "It works. No apps found yet." : "It works · \(counted(apps.count, "app"))", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(Palette.mint)
                            if !apps.isEmpty {
                                FlowLayout(spacing: 6) {
                                    ForEach(apps, id: \.self) { a in
                                        Label(a, systemImage: "app.fill").font(.caption).sensitive(4)
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                            .background(.quaternary.opacity(0.6), in: .capsule)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Label("The secret goes to your Keychain, never to a file Release Desk keeps.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if verifiedApps == nil {
                    Button("Verify") { Task { await verify() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!filled || verifying)
                } else {
                    Button("Connect") { connect() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent).tint(Palette.indigo)
                        .disabled(teamName.trimmed.isEmpty || (accountChoice == nil && accountName.trimmed.isEmpty))
                }
            }
            .padding(20)
        }
        .onAppear { accountChoice = accounts.first?.id }
        .onChange(of: [clientID, secret, tenantID, sellerID, packages]) { verifiedApps = nil; error = nil }
    }

    private func field(_ title: String, _ value: Binding<String>, prompt: String) -> some View {
        LabeledContent(title) {
            TextField(title, text: value, prompt: Text(prompt)).labelsHidden().multilineTextAlignment(.trailing).sensitive(5)
        }
    }

    private func verify() async {
        verifying = true
        error = nil
        defer { verifying = false }
        do {
            if isHuawei {
                verifiedApps = try await model.verifyAppGallery(clientID: clientID.trimmed, secret: secret.trimmed, packages: packageList)
                    .map { "\($0.name) · \($0.package)" }
            } else {
                verifiedApps = try await model.verifyMicrosoft(tenantID: tenantID.trimmed, clientID: clientID.trimmed, secret: secret.trimmed)
                    .map(\.name)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func connect() {
        do {
            if isHuawei {
                try model.connectAppGallery(accountID: accountChoice, newAccountName: accountName.trimmed, teamName: teamName.trimmed,
                                            clientID: clientID.trimmed, secret: secret.trimmed, packages: packageList)
            } else {
                try model.connectMicrosoft(accountID: accountChoice, newAccountName: accountName.trimmed, teamName: teamName.trimmed,
                                           tenantID: tenantID.trimmed, clientID: clientID.trimmed, sellerID: sellerID.trimmed, secret: secret.trimmed)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

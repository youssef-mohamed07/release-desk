import AppKit
import ReleaseKit
import SwiftUI

/// Sends an App Store version to App Review: pick or create the version,
/// attach a processed build, write What's New, choose how it releases, see
/// what is still missing, then submit.
struct SubmitReviewSheet: View {
    let app: ASCApp
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.privacyMode) private var privacy

    @State private var versions: [ASCVersion] = []
    @State private var versionID: String?
    @State private var newVersion = ""
    @State private var buildID: String?
    @State private var readiness: ReviewReadiness?
    @State private var whatsNew: [String: String] = [:]
    @State private var afterApproval = true
    @State private var loading = true
    @State private var checking = false
    @State private var submitting = false
    @State private var progress: [String] = []
    @State private var error: String?
    @State private var done: ReviewSubmission?
    @State private var confirm = false

    private var state: AppState { model.apps[app.id] ?? AppState() }
    private var editable: [ASCVersion] { versions.filter { editableVersionStates.contains($0.state) } }
    private var chosenVersion: ASCVersion? { versions.first { $0.id == versionID } }
    private var versionString: String { chosenVersion?.version ?? newVersion }
    private var builds: [ASCBuild] {
        state.builds.filter { $0.processingState == "VALID" && !$0.expired }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AppIcon(url: model.iconURL(app.id, size: 128), name: app.name, size: 44).sensitive(8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Submit for App Store review").font(.title2.bold())
                    Text("App Review checks the version, its texts and screenshots, and the build you attach.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            if let done {
                submitted(done)
            } else {
                form
                footer
            }
        }
        .frame(width: 680, height: 760)
        .task { await load() }
        .alert("Submit \(privacy ? "this app" : app.name) \(versionString) for App Store review?", isPresented: $confirm) {
            Button("Submit") { Task { await submit() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apple reviews it, usually within a day. \(afterApproval ? "It goes on sale as soon as it is approved." : "After approval it waits for you to release it.") You can cancel the submission until review starts.")
        }
    }

    private var form: some View {
        Form {
            Section("Version") {
                Picker("Version", selection: $versionID) {
                    ForEach(editable) { v in Text("\(v.version) · \(describeState(v.state).label)").tag(Optional(v.id)) }
                    Text("New version…").tag(String?.none)
                }
                if versionID == nil {
                    TextField("New version", text: $newVersion, prompt: Text("e.g. 1.0.1"))
                }
                Picker("Build", selection: $buildID) {
                    Text("Choose a build").tag(String?.none)
                    ForEach(builds) { b in
                        Text("\(b.version) (\(b.number))\(normalized(b.version) == normalized(versionString) ? "" : "  · different version")").tag(Optional(b.id))
                    }
                }
                if let b = builds.first(where: { $0.id == buildID }), normalized(b.version) != normalized(versionString), !versionString.isEmpty {
                    Label("This build is version \(b.version); Apple wants the build's version to match \(versionString).", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker("Release", selection: $afterApproval) {
                    Text("As soon as it is approved").tag(true)
                    Text("Manually, when I say").tag(false)
                }
            }
            if let r = readiness, r.hasShipped, !r.localizations.isEmpty {
                Section("What's New") {
                    ForEach(r.localizations) { l in
                        let rtl = l.locale.hasPrefix("ar")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Locale.current.localizedString(forIdentifier: l.locale) ?? l.locale).font(.caption.weight(.semibold))
                            TextEditor(text: Binding(get: { whatsNew[l.id] ?? l.whatsNew }, set: { whatsNew[l.id] = $0 }))
                                .frame(minHeight: 70)
                                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                                .sensitive(5)
                        }
                    }
                }
            }
            Section {
                if checking || loading {
                    HStack { ProgressView().controlSize(.small); Text("Reading the version from App Store Connect…").foregroundStyle(.secondary) }
                } else if let r = readiness {
                    ForEach(r.items) { i in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: i.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(i.ok ? Palette.mint : StateTone.waiting.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(i.title)
                                if let d = i.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Text("App Privacy answers, age rating, pricing and the review contact are checked by Apple when you submit; anything missing comes back here.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Fill in texts and screenshots in App Store Connect", destination: URL(string: "https://appstoreconnect.apple.com/apps/\(app.id)/distribution")!)
                        .font(.callout)
                } else if versionID == nil {
                    Text("The new version is created when you submit.").foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Ready for review?")
                    Spacer()
                    Button { Task { await check() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                        .disabled(versionID == nil || checking)
                }
            }
            if submitting || !progress.isEmpty || error != nil {
                Section("Sending") {
                    ForEach(progress, id: \.self) { Label($0, systemImage: "checkmark").font(.callout) }
                    if submitting { HStack { ProgressView().controlSize(.small); Text("Working…") } }
                    if let error { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Palette.ember).textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onChange(of: versionID) { Task { await check() } }
        .onChange(of: buildID) { Task { await check() } }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Submit for review") { confirm = true }
                .buttonStyle(.glassProminent)
                .tint(Palette.indigo)
                .keyboardShortcut(.defaultAction)
                .disabled(submitting || buildID == nil || versionString.isEmpty)
        }
        .padding(20)
    }

    private func submitted(_ s: ReviewSubmission) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(Palette.mint).symbolEffect(.bounce, value: s.id)
            Text("Sent to App Review").font(.title.bold())
            Text("\(versionString) is \(describeState(s.state).label.lowercased()). Apple emails when the review ends; the app page shows the state too.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            Button("Done") { dismiss() }.buttonStyle(.glassProminent).tint(Palette.indigo).keyboardShortcut(.defaultAction)
            Spacer()
        }
        .padding(30)
    }

    private func normalized(_ v: String) -> String {
        var parts = v.split(separator: ".").map(String.init)
        while parts.count > 1, parts.last == "0" { parts.removeLast() }
        return parts.joined(separator: ".")
    }

    private func load() async {
        defer { loading = false }
        guard let c = try? model.client(forApp: app.id) else { return }
        if model.apps[app.id]?.detailed != true { await model.refresh(appID: app.id) }
        versions = (try? await c.versions(appID: app.id)) ?? []
        versionID = editable.first?.id
        if editable.isEmpty, let last = versions.first {
            // Suggest the next patch version.
            var parts = last.version.split(separator: ".").compactMap { Int($0) }
            if parts.isEmpty { parts = [1, 0] }
            parts[parts.count - 1] += 1
            newVersion = parts.map(String.init).joined(separator: ".")
        }
        buildID = builds.first { normalized($0.version) == normalized(versionString) }?.id
        await check()
    }

    private func check() async {
        guard let versionID, let c = try? model.client(forApp: app.id) else { readiness = nil; return }
        checking = true
        defer { checking = false }
        do {
            readiness = try await c.readiness(appID: app.id, versionID: versionID, buildID: buildID)
            if buildID == nil, let attached = readiness?.attachedBuildID { buildID = attached }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func submit() async {
        guard let buildID, let c = try? model.client(forApp: app.id) else { return }
        submitting = true
        error = nil
        progress = []
        defer { submitting = false }
        do {
            var vid = versionID
            if vid == nil {
                let v = try await c.createVersion(appID: app.id, version: newVersion)
                vid = v.id
                progress.append("Created version \(v.version)")
            }
            guard let vid else { return }
            try await c.attachBuild(versionID: vid, buildID: buildID)
            progress.append("Attached the build")
            for (locID, text) in whatsNew where !text.isEmpty {
                try await c.setWhatsNew(localizationID: locID, text: text)
            }
            if !whatsNew.isEmpty { progress.append("Wrote What's New") }
            try await c.setReleaseType(versionID: vid, afterApproval ? "AFTER_APPROVAL" : "MANUAL")
            progress.append(afterApproval ? "Releases after approval" : "Waits for you after approval")
            done = try await c.submitForReview(appID: app.id, versionID: vid)
            await model.refresh(appID: app.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

import Foundation
import Observation

public enum StepID: String, CaseIterable, Sendable, Codable {
    case prepare, archive, sign, export, upload, processing, notes, groups, review, live
    case bundle, checkSigning, playRelease

    public static func steps(for platform: Platform) -> [StepID] {
        switch platform {
        case .ios: [.prepare, .archive, .sign, .export, .upload, .processing, .notes, .groups, .review, .live]
        case .android: [.prepare, .bundle, .checkSigning, .playRelease]
        }
    }

    public var title: String {
        switch self {
        case .prepare: "Prepare"
        case .archive: "Archive"
        case .sign: "Pre-sign"
        case .export: "Export & sign"
        case .upload: "Upload"
        case .processing: "Apple processing"
        case .notes: "What to Test"
        case .groups: "TestFlight groups"
        case .review: "Beta review"
        case .live: "Live for testers"
        case .bundle: "Build app bundle"
        case .checkSigning: "Check signing"
        case .playRelease: "Upload & release"
        }
    }

    public var symbol: String {
        switch self {
        case .prepare: "checklist"
        case .archive: "shippingbox"
        case .sign: "signature"
        case .export: "seal"
        case .upload: "icloud.and.arrow.up"
        case .processing: "gearshape.2"
        case .notes: "text.bubble"
        case .groups: "person.3"
        case .review: "checkmark.shield"
        case .live: "airplane.departure"
        case .bundle: "shippingbox"
        case .checkSigning: "signature"
        case .playRelease: "arrow.up.forward.app"
        }
    }
}

public enum StepState: Sendable, Equatable {
    case pending, running, done
    case warning(String), skipped(String), failed(String)

    public var isFinished: Bool {
        switch self { case .pending, .running: false; default: true }
    }
}

public struct RunStep: Identifiable, Sendable {
    public let id: StepID
    public var state: StepState = .pending
    public var started: Date?
    public var finished: Date?
    public var detail: String?
}

public struct LogLine: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable { case output, info, success, warning, error }
    public let id: Int
    public let step: StepID
    public let time: Date
    public let kind: Kind
    public let text: String
}

public enum Platform: String, Codable, Sendable { case ios, android }

/// Where an Android release goes on Play.
public struct PlayTarget: Sendable, Hashable {
    public var track: String
    /// completed, inProgress (staged rollout), draft or halted.
    public var status: String
    public var userFraction: Double?

    public init(track: String, status: String, userFraction: Double?) {
        self.track = track
        self.status = status
        self.userFraction = userFraction
    }
}

/// Everything one release run needs, decided before it starts.
public struct ReleasePlan: Sendable {
    public var platform: Platform = .ios
    public var play: PlayTarget?
    /// Resume: skip the steps before this one (iOS: only `.processing`).
    public var startAt: StepID?
    public var app: ASCApp
    public var projectRoot: URL
    public var version: String
    public var build: Int
    public var recipe: IOSRecipe
    public var teamID: String?
    public var groups: [ASCBetaGroup]
    public var whatsNew: [String: String]
    public var submitForReview: Bool
    /// Stops after export: everything local, nothing sent to Apple.
    public var rehearsal: Bool

    public init(app: ASCApp, projectRoot: URL, version: String, build: Int, recipe: IOSRecipe, teamID: String?,
                groups: [ASCBetaGroup], whatsNew: [String: String], submitForReview: Bool, rehearsal: Bool) {
        self.app = app
        self.projectRoot = projectRoot
        self.version = version
        self.build = build
        self.recipe = recipe
        self.teamID = teamID
        self.groups = groups
        self.whatsNew = whatsNew
        self.submitForReview = submitForReview
        self.rehearsal = rehearsal
    }
}

/// One iOS release: archive → sign → export → upload → TestFlight. The UI
/// watches it; the steps run in order and stop at the first failure.
@MainActor @Observable
public final class ReleaseRun: Identifiable {
    public enum Phase: Sendable, Equatable { case ready, running, succeeded, failed, cancelled }

    public let id = UUID()
    public let plan: ReleasePlan
    public private(set) var steps: [RunStep]
    public private(set) var lines: [LogLine] = []
    public private(set) var phase: Phase = .ready
    public private(set) var started: Date?
    public private(set) var finished: Date?
    public private(set) var failure: String?
    public private(set) var buildID: String?
    /// The .ipa or .aab this run built.
    public private(set) var ipa: URL?
    public private(set) var playVersionCode: String?
    public private(set) var current: StepID?
    public let logFile: URL

    @ObservationIgnored public var onFinish: ((ReleaseRun) -> Void)?
    @ObservationIgnored private let apple: ASCClient?
    @ObservationIgnored private let play: PlayClient?
    private var client: ASCClient { apple! }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let sink: LogSink
    @ObservationIgnored private var nextLineID = 0

    public init(plan: ReleasePlan, apple: ASCClient? = nil, play: PlayClient? = nil) {
        self.plan = plan
        self.apple = apple
        self.play = play
        steps = StepID.steps(for: plan.platform).map { RunStep(id: $0) }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safe = plan.app.name.replacingOccurrences(of: "/", with: "-")
        logFile = WorkspaceStore.logs.appendingPathComponent("\(safe) \(plan.version) (\(plan.build)) \(stamp).log")
        sink = LogSink(file: logFile)
        sink.deliver = { [weak self] batch in
            MainActor.assumeIsolated { self?.receive(batch) }
        }
    }

    public var elapsed: TimeInterval {
        guard let started else { return 0 }
        return (finished ?? Date()).timeIntervalSince(started)
    }

    public var progress: Double {
        let done = steps.filter { $0.state.isFinished }.count
        return Double(done) / Double(steps.count)
    }

    public func step(_ id: StepID) -> RunStep { steps.first { $0.id == id }! }

    public func start() {
        guard phase == .ready else { return }
        phase = .running
        started = Date()
        task = Task { await self.execute() }
    }

    public func cancel() {
        guard phase == .running else { return }
        task?.cancel()
    }

    // MARK: - Log

    private func receive(_ batch: [(StepID, LogLine.Kind, String, Date)]) {
        for (step, kind, text, time) in batch {
            lines.append(LogLine(id: nextLineID, step: step, time: time, kind: kind, text: text))
            nextLineID += 1
        }
        if lines.count > 25_000 { lines.removeFirst(lines.count - 20_000) }
    }

    private func log(_ text: String, _ kind: LogLine.Kind = .info) {
        sink.add(current ?? .prepare, kind, text)
    }

    private func outputHandler(_ step: StepID) -> @Sendable (String) -> Void {
        let sink = sink
        return { line in
            let lower = line.lowercased()
            let kind: LogLine.Kind = lower.contains("error:") || lower.hasPrefix("error") ? .error
                : (lower.contains("warning:") ? .warning : .output)
            sink.add(step, kind, line)
        }
    }

    private func set(_ id: StepID, _ state: StepState, detail: String? = nil) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        if state == .running {
            steps[i].started = Date()
            current = id
        }
        if state.isFinished { steps[i].finished = Date() }
        steps[i].state = state
        if let detail { steps[i].detail = detail }
    }

    private func detail(_ id: StepID, _ text: String) {
        if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].detail = text }
    }

    // MARK: - Steps

    private func execute() async {
        let fm = FileManager.default
        let keyDir = fm.temporaryDirectory.appendingPathComponent("ReleaseDesk-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: keyDir) }
        var ctx = Context(keyDir: keyDir)
        log("Release \(plan.app.name) \(plan.version) (\(plan.build)) from \(plan.projectRoot.path)")
        if plan.rehearsal { log("Rehearsal: stops after export, nothing is uploaded.", .warning) }

        let order: [(StepID, (inout Context) async throws -> StepState)] = plan.platform == .ios ? [
            (.prepare, prepare), (.archive, archive), (.sign, preSign), (.export, export),
            (.upload, upload), (.processing, waitForProcessing), (.notes, writeNotes),
            (.groups, addToGroups), (.review, submitReview), (.live, waitUntilLive),
        ] : [
            (.prepare, prepareAndroid), (.bundle, buildBundle), (.checkSigning, checkSigning), (.playRelease, releaseToPlay),
        ]
        let remote: Set<StepID> = [.upload, .processing, .notes, .groups, .review, .live, .playRelease]
        var resuming = plan.startAt != nil
        for (id, body) in order {
            if Task.isCancelled { break }
            if resuming, id != plan.startAt {
                set(id, .skipped("Done in the earlier run"))
                continue
            }
            resuming = false
            if plan.rehearsal, remote.contains(id) {
                set(id, .skipped("Rehearsal"))
                continue
            }
            set(id, .running)
            log("▸ \(id.title)")
            do {
                let result = try await body(&ctx)
                set(id, result)
                if case .warning(let w) = result { log(w, .warning) }
                if case .skipped(let s) = result { log("Skipped: \(s)") }
            } catch {
                let cancelled = Task.isCancelled || (error as? ReleaseError).map { if case .cancelled = $0 { true } else { false } } ?? false
                let message = cancelled ? "Cancelled" : error.localizedDescription
                set(id, .failed(message))
                log(message, .error)
                failure = cancelled ? nil : "\(id.title): \(message)"
                finish(cancelled ? .cancelled : .failed)
                return
            }
        }
        if Task.isCancelled {
            if let c = current, !step(c).state.isFinished { set(c, .failed("Cancelled")) }
            finish(.cancelled)
        } else {
            log(plan.rehearsal ? "Rehearsal finished. The \(plan.platform == .ios ? "IPA" : "bundle") is ready at \(ipa?.path ?? "?")." : "Shipped \(plan.app.name) \(plan.version) (\(plan.build)).", .success)
            finish(.succeeded)
        }
    }

    private func finish(_ p: Phase) {
        phase = p
        finished = Date()
        current = nil
        sink.flushNow()
        onFinish?(self)
    }

    struct Context {
        let keyDir: URL
        var keyFile: URL?
        var exportOptions: URL?
        var archive: URL?
        var workDir: URL?
    }

    private var root: URL { plan.projectRoot }

    private func prepare(_ ctx: inout Context) async throws -> StepState {
        let project = try FlutterProject.inspect(root, recipe: plan.recipe)
        log("Flutter project \(project.name), pubspec \(project.version)+\(project.buildNumber), bundle \(project.iosBundleID ?? "?")")
        if let bundle = project.iosBundleID, bundle != plan.app.bundleID {
            throw ReleaseError.precondition("The project builds \(bundle), but the store app is \(plan.app.bundleID).")
        }
        let flutter = try await Shell.capture("flutter", ["--version", "--machine"], cwd: root)
        if let start = flutter.firstIndex(of: "{"),
           let json = try? JSONDecoder().decode(JSONValue.self, from: Data(flutter[start...].utf8)) {
            log("Flutter \(json["frameworkVersion"].string ?? "?"), Dart \(json["dartSdkVersion"].string ?? "?")")
        }
        let xcode = try await Shell.capture("/usr/bin/xcrun", ["xcodebuild", "-version"])
        log(xcode.replacingOccurrences(of: "\n", with: ", "))

        detail(.prepare, "Checking App Store Connect")
        let existing = try await client.builds(appID: plan.app.id, limit: 5, number: "\(plan.build)", version: plan.version)
        if !existing.isEmpty {
            throw ReleaseError.precondition("Build \(plan.version) (\(plan.build)) is already on App Store Connect. Pick a higher build number.")
        }

        if plan.rehearsal {
            log("Rehearsal leaves pubspec.yaml as it is; the build number goes to flutter as --build-number.")
        } else if plan.recipe.writeBuildNumber, project.version != plan.version || project.buildNumber != plan.build {
            try project.writeVersion(plan.version, build: plan.build)
            log("pubspec.yaml → version: \(plan.version)+\(plan.build)", .success)
        }

        let work = root.appendingPathComponent("build/ios/release-desk/\(plan.version)-\(plan.build)", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        ctx.workDir = work

        let key = client.key
        ctx.keyFile = try key.materialize(in: ctx.keyDir)

        let options = root.appendingPathComponent(plan.recipe.exportOptions)
        if FileManager.default.fileExists(atPath: options.path) {
            ctx.exportOptions = options
            log("Export options: \(plan.recipe.exportOptions)")
        } else {
            var dict: [String: Any] = ["method": "app-store-connect", "destination": "export", "signingStyle": "automatic",
                                       "uploadSymbols": true, "manageAppVersionAndBuildNumber": false]
            if let team = plan.teamID { dict["teamID"] = team }
            let generated = work.appendingPathComponent("ExportOptions.plist")
            try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: generated)
            ctx.exportOptions = generated
            log("No \(plan.recipe.exportOptions) in the project; using a generated one (app-store-connect, automatic signing).")
        }
        return .done
    }

    private func archive(_ ctx: inout Context) async throws -> StepState {
        detail(.archive, "flutter build ipa")
        let args = ["build", "ipa", "--release", "--no-codesign", "--build-name", plan.version, "--build-number", "\(plan.build)"]
        log("$ flutter \(args.joined(separator: " "))")
        let code = try await Shell.run("flutter", args, cwd: root, onLine: outputHandler(.archive))
        try checkCancelled()
        guard code == 0 else { throw ReleaseError.command("flutter build ipa", code: code, tail: "") }
        let archive = root.appendingPathComponent("build/ios/archive/Runner.xcarchive")
        let info = archive.appendingPathComponent("Products/Applications/Runner.app/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ReleaseError.precondition("No archive at \(archive.path)")
        }
        let v = plist["CFBundleShortVersionString"] as? String ?? "?"
        let b = plist["CFBundleVersion"] as? String ?? "?"
        guard v == plan.version, b == "\(plan.build)" else {
            throw ReleaseError.precondition("The archive is \(v) (\(b)), expected \(plan.version) (\(plan.build)).")
        }
        ctx.archive = archive
        log("Archive \(v) (\(b)) ready", .success)
        return .done
    }

    private func preSign(_ ctx: inout Context) async throws -> StepState {
        guard plan.recipe.cloudSigning else { return .skipped("Signed during archive") }
        let app = ctx.archive!.appendingPathComponent("Products/Applications/Runner.app")
        let fm = FileManager.default
        var nested: [URL] = []
        for (dir, exts) in [("Frameworks", ["framework", "dylib"]), ("PlugIns", ["appex"])] {
            let folder = app.appendingPathComponent(dir)
            for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where exts.contains(item.pathExtension) {
                nested.append(item)
            }
        }
        for (i, item) in nested.enumerated() {
            detail(.sign, "\(i + 1)/\(nested.count + 1) \(item.lastPathComponent)")
            _ = try await Shell.capture("/usr/bin/codesign", ["-f", "-s", "-", item.path])
            try checkCancelled()
        }
        var args = ["-f", "-s", "-"]
        let ent = root.appendingPathComponent(plan.recipe.entitlements)
        if fm.fileExists(atPath: ent.path) { args += ["--entitlements", ent.path] }
        _ = try await Shell.capture("/usr/bin/codesign", args + [app.path])
        log("Ad-hoc signed \(nested.count) frameworks and Runner.app\(args.count > 3 ? " with \(plan.recipe.entitlements)" : "")")
        return .done
    }

    private func export(_ ctx: inout Context) async throws -> StepState {
        let key = client.key
        let out = ctx.workDir!.appendingPathComponent("export")
        let args = ["xcodebuild", "-exportArchive", "-archivePath", ctx.archive!.path, "-exportPath", out.path,
                    "-exportOptionsPlist", ctx.exportOptions!.path, "-allowProvisioningUpdates",
                    "-authenticationKeyPath", ctx.keyFile!.path, "-authenticationKeyID", key.keyID,
                    "-authenticationKeyIssuerID", key.issuerID]
        detail(.export, "Cloud signing with \(key.keyID)")
        log("$ xcodebuild -exportArchive … (cloud signing, key \(key.keyID))")
        let code = try await Shell.run("/usr/bin/xcrun", args, cwd: root, onLine: outputHandler(.export))
        try checkCancelled()
        guard code == 0 else { throw ReleaseError.command("xcodebuild -exportArchive", code: code, tail: "") }
        guard let ipa = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "ipa" }) else {
            throw ReleaseError.precondition("Export finished but no .ipa in \(out.path)")
        }
        self.ipa = ipa
        let size = (try? FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? Int).flatMap { $0 } ?? 0
        log("\(ipa.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))", .success)
        await logEntitlements(of: ipa, in: ctx.workDir!)
        return .done
    }

    private func logEntitlements(of ipa: URL, in work: URL) async {
        let unz = work.appendingPathComponent("unzipped")
        guard (try? await Shell.capture("/usr/bin/unzip", ["-o", "-q", ipa.path, "-d", unz.path])) != nil,
              let app = (try? FileManager.default.contentsOfDirectory(at: unz.appendingPathComponent("Payload"), includingPropertiesForKeys: nil))?.first,
              let xml = try? await Shell.capture("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path]),
              let start = xml.range(of: "<?xml"),
              let plist = try? PropertyListSerialization.propertyList(from: Data(xml[start.lowerBound...].utf8), format: nil) as? [String: Any]
        else { return }
        let keys = plist.keys.sorted().map { k -> String in
            let short = k.replacingOccurrences(of: "com.apple.developer.", with: "")
            if let a = plist[k] as? [Any] { return "\(short) (\(a.count))" }
            if let s = plist[k] as? String, k == "aps-environment" { return "\(short)=\(s)" }
            if let b = plist[k] as? Bool { return "\(short)=\(b)" }
            return short
        }
        log("Signed entitlements: " + keys.joined(separator: ", "))
        try? FileManager.default.removeItem(at: unz)
    }

    private func upload(_ ctx: inout Context) async throws -> StepState {
        let key = client.key
        detail(.upload, ipa!.lastPathComponent)
        let args = ["altool", "--upload-app", "-f", ipa!.path, "-t", "ios", "--apiKey", key.keyID, "--apiIssuer", key.issuerID,
                    "--p8-file-path", ctx.keyFile!.path]
        log("$ xcrun altool --upload-app -f \(ipa!.lastPathComponent) -t ios --apiKey \(key.keyID)")
        let code = try await Shell.run("/usr/bin/xcrun", args, onLine: outputHandler(.upload))
        try checkCancelled()
        guard code == 0 else { throw ReleaseError.command("altool --upload-app", code: code, tail: "") }
        log("Uploaded to App Store Connect", .success)
        return .done
    }

    private func waitForProcessing(_ ctx: inout Context) async throws -> StepState {
        let began = Date()
        var lastState = ""
        while Date().timeIntervalSince(began) < 60 * 60 {
            let build = try await client.builds(appID: plan.app.id, limit: 2, number: "\(plan.build)", version: plan.version).first
            let state = build?.processingState ?? "NOT_LISTED"
            if state != lastState {
                log(build == nil ? "Not listed yet" : "State \(state)")
                lastState = state
            }
            let minutes = Int(Date().timeIntervalSince(began) / 60)
            detail(.processing, "\(build == nil ? "Waiting for Apple to list it" : describeState(state).label) · \(minutes) min")
            if let build {
                switch state {
                case "VALID":
                    buildID = build.id
                    log("Build \(build.id) is processed", .success)
                    return .done
                case "FAILED", "INVALID":
                    throw ReleaseError.precondition("Apple marked the build \(state). Check the email from App Store Connect.")
                default: break
                }
            }
            try await Task.sleep(for: .seconds(30))
        }
        throw ReleaseError.precondition("Still processing after an hour.")
    }

    private func writeNotes(_ ctx: inout Context) async throws -> StepState {
        let notes = plan.whatsNew.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !notes.isEmpty else { return .skipped("No text") }
        for (locale, text) in notes.sorted(by: { $0.key < $1.key }) {
            detail(.notes, locale)
            try await client.setWhatsNew(buildID: buildID!, locale: locale, text: text)
            log("What to Test (\(locale)) written")
        }
        return .done
    }

    private func addToGroups(_ ctx: inout Context) async throws -> StepState {
        let automatic = plan.groups.filter { $0.isInternal && $0.allBuilds }
        let targets = plan.groups.filter { !($0.isInternal && $0.allBuilds) }
        for g in automatic { log("\(g.name) gets every build automatically") }
        guard !targets.isEmpty else { return plan.groups.isEmpty ? .skipped("No groups chosen") : .done }
        let names = targets.map(\.name).joined(separator: ", ")
        for attempt in 1...25 {
            do {
                detail(.groups, names)
                try await client.addBuild(buildID!, toGroups: targets.map(\.id))
                log("Added to \(names)", .success)
                return .done
            } catch let e as ReleaseError where e.httpStatus == 404 && attempt < 25 {
                // Apple answers 404 for a few minutes after processing ends.
                detail(.groups, "Apple is not ready for it yet · try \(attempt + 1) in 60 s")
                log("Group not ready for the build yet (404), trying again in 60 s")
                try await Task.sleep(for: .seconds(60))
            }
        }
        throw ReleaseError.precondition("Could not add the build to \(names)")
    }

    private func submitReview(_ ctx: inout Context) async throws -> StepState {
        guard plan.submitForReview else { return .skipped("Turned off") }
        guard plan.groups.contains(where: { !$0.isInternal }) else { return .skipped("Only internal groups") }
        do {
            try await client.submitForBetaReview(buildID: buildID!)
            log("Submitted for beta app review", .success)
            return .done
        } catch let e as ReleaseError {
            let text = e.localizedDescription
            if text.contains("ANOTHER_BUILD_IN_REVIEW") {
                return .warning("Another build of this version is in review. Submit this one when that review ends.")
            }
            if e.httpStatus == 409, text.lowercased().contains("already") {
                return .warning("Already submitted.")
            }
            throw e
        }
    }

    private func waitUntilLive(_ ctx: inout Context) async throws -> StepState {
        let external = plan.groups.contains { !$0.isInternal }
        let began = Date()
        var last = ""
        while Date().timeIntervalSince(began) < 10 * 60 {
            let s = try await client.betaState(buildID: buildID!)
            let state = (external ? s.externalState : s.internalState) ?? "?"
            if state != last { log("\(external ? "External" : "Internal") testing: \(state)"); last = state }
            detail(.live, describeState(state).label)
            if state == "IN_BETA_TESTING" {
                log("Testers can install \(plan.version) (\(plan.build)) now", .success)
                return .done
            }
            if state == "BETA_REJECTED" { throw ReleaseError.precondition("Beta review rejected the build.") }
            try await Task.sleep(for: .seconds(20))
        }
        return .warning("Still \(describeState(last).label.lowercased()). Apple emails when it is ready.")
    }

    // MARK: - Android

    private func prepareAndroid(_ ctx: inout Context) async throws -> StepState {
        let project = try FlutterProject.inspect(root, recipe: plan.recipe)
        log("Flutter project \(project.name), pubspec \(project.version)+\(project.buildNumber), package \(project.androidPackage ?? "?")")
        if let pkg = project.androidPackage, pkg != plan.app.bundleID {
            throw ReleaseError.precondition("The project builds \(pkg), but the Play app is \(plan.app.bundleID).")
        }
        let flutter = try await Shell.capture("flutter", ["--version", "--machine"], cwd: root)
        if let start = flutter.firstIndex(of: "{"), let json = try? JSONDecoder().decode(JSONValue.self, from: Data(flutter[start...].utf8)) {
            log("Flutter \(json["frameworkVersion"].string ?? "?"), Dart \(json["dartSdkVersion"].string ?? "?")")
        }
        var warning: String?
        if !project.hasUploadKey {
            let text = "No android/key.properties: the bundle would be signed with the debug key, which Play refuses."
            if plan.rehearsal { warning = text } else { throw ReleaseError.precondition(text) }
        }
        if let play {
            detail(.prepare, "Checking Play")
            let tracks = try await play.overview(package: plan.app.bundleID).tracks
            let highest = tracks.flatMap(\.releases).map(\.maxCode).max() ?? 0
            log("Highest version code on Play: \(highest)")
            if plan.build <= highest, !plan.rehearsal {
                throw ReleaseError.precondition("Version code \(plan.build) is not above Play's highest (\(highest)).")
            }
        }
        if plan.rehearsal {
            log("Rehearsal leaves pubspec.yaml as it is.")
        } else if plan.recipe.writeBuildNumber, project.version != plan.version || project.buildNumber != plan.build {
            try project.writeVersion(plan.version, build: plan.build)
            log("pubspec.yaml → version: \(plan.version)+\(plan.build)", .success)
        }
        return warning.map { .warning($0) } ?? .done
    }

    private func buildBundle(_ ctx: inout Context) async throws -> StepState {
        detail(.bundle, "flutter build appbundle")
        let args = ["build", "appbundle", "--release", "--build-name", plan.version, "--build-number", "\(plan.build)"]
        log("$ flutter \(args.joined(separator: " "))")
        let code = try await Shell.run("flutter", args, cwd: root, onLine: outputHandler(.bundle))
        try checkCancelled()
        guard code == 0 else { throw ReleaseError.command("flutter build appbundle", code: code, tail: "") }
        let aab = root.appendingPathComponent("build/app/outputs/bundle/release/app-release.aab")
        guard FileManager.default.fileExists(atPath: aab.path) else { throw ReleaseError.precondition("No bundle at \(aab.path)") }
        ipa = aab
        let size = (try? FileManager.default.attributesOfItem(atPath: aab.path)[.size] as? Int).flatMap { $0 } ?? 0
        log("app-release.aab · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))", .success)
        return .done
    }

    private func checkSigning(_ ctx: inout Context) async throws -> StepState {
        let candidates = ["/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool", "keytool"]
        for tool in candidates where !tool.hasPrefix("/") || FileManager.default.fileExists(atPath: tool) {
            guard let out = try? await Shell.capture(tool, ["-printcert", "-jarfile", ipa!.path]) else { continue }
            let owner = out.split(separator: "\n").first { $0.contains("Owner:") }.map { String($0).replacingOccurrences(of: "Owner: ", with: "") } ?? "?"
            let sha = out.split(separator: "\n").first { $0.contains("SHA256:") }.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            log("Signed by \(owner)")
            if !sha.isEmpty { log(sha) }
            if owner.contains("Android Debug") {
                if plan.rehearsal { return .warning("Signed with the debug key; Play would refuse it.") }
                throw ReleaseError.precondition("The bundle is signed with the debug key. Set android/key.properties to the upload key.")
            }
            return .done
        }
        return .warning("keytool not found, signature not checked")
    }

    private func releaseToPlay(_ ctx: inout Context) async throws -> StepState {
        guard let play, let target = plan.play else { throw ReleaseError.precondition("No Play account for this app") }
        detail(.playRelease, "\(target.track) · \(target.status)")
        let sink = sink
        let result = try await play.release(package: plan.app.bundleID, bundle: ipa!, track: target.track,
                                            name: "\(plan.version) (\(plan.build))", status: target.status,
                                            userFraction: target.userFraction, notes: plan.whatsNew,
                                            log: { sink.add(.playRelease, .info, $0) })
        playVersionCode = result.versionCode
        log("Released \(plan.version) (\(result.versionCode)) to \(target.track)", .success)
        return result.status == target.status ? .done : .warning("Saved as a \(result.status) release: this app is not published on Play yet.")
    }

    private func checkCancelled() throws {
        if Task.isCancelled { throw ReleaseError.cancelled }
    }
}

/// Collects log lines from any thread, hands them to the main thread in
/// batches and appends them to the run's log file.
final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(StepID, LogLine.Kind, String, Date)] = []
    private var scheduled = false
    private let handle: FileHandle?
    var deliver: (@Sendable ([(StepID, LogLine.Kind, String, Date)]) -> Void)?

    init(file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        handle = try? FileHandle(forWritingTo: file)
    }

    deinit { try? handle?.close() }

    func add(_ step: StepID, _ kind: LogLine.Kind, _ text: String) {
        lock.lock()
        pending.append((step, kind, text, Date()))
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.flushNow() }
        }
    }

    func flushNow() {
        lock.lock()
        let batch = pending
        pending.removeAll()
        scheduled = false
        lock.unlock()
        guard !batch.isEmpty else { return }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let text = batch.map { "\(f.string(from: $0.3)) [\($0.0.rawValue)] \($0.2)" }.joined(separator: "\n") + "\n"
        handle?.write(Data(text.utf8))
        if Thread.isMainThread { deliver?(batch) } else { DispatchQueue.main.async { self.deliver?(batch) } }
    }
}

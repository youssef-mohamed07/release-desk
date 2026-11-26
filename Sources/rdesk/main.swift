import Foundation
import ReleaseKit

// rdesk: read your App Store Connect data from the terminal.
//   rdesk apps    --key-id ID --issuer ISSUER [--key-file PATH]
//   rdesk builds  --app APP_ID …
//   rdesk groups  --app APP_ID …
//   rdesk versions --app APP_ID …
// Without --key-file the key is read from ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8.

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let command = args.first else {
    fail("""
    usage: rdesk apps|team --key-id ID --issuer ISSUER [--key-file PATH]
           rdesk builds|groups|versions|readiness --key-id ID --issuer ISSUER --app APP_ID [--key-file PATH]
           rdesk bundle --key-id ID --issuer ISSUER --bundle BUNDLE_ID [--key-file PATH]
           rdesk play-apps --json SERVICE_ACCOUNT.json
           rdesk play-tracks --json SERVICE_ACCOUNT.json --package PACKAGE
           rdesk workflow [--android] [--dir mobile] [--team TEAMID] [--flutter 3.x]
    """)
}
// The GitHub Actions workflow for cloud builds: rdesk workflow [--dir mobile] [--team TEAMID] [--flutter 3.x]
if command == "workflow" {
    let target: CloudTarget = args.contains("--android") ? .android : .ios
    print(target.yaml(projectDir: option("--dir") ?? ".", recipe: IOSRecipe(), teamID: option("--team"), flutterVersion: option("--flutter")))
    exit(0)
}

// Google Play: rdesk play-apps|play-tracks --json SERVICE_ACCOUNT.json [--package PKG]
if command.hasPrefix("play-") {
    guard let path = option("--json"), let json = try? String(contentsOfFile: path, encoding: .utf8) else { fail("--json SERVICE_ACCOUNT.json is required") }
    do {
        let play = PlayClient(account: try ServiceAccount(json: json))
        switch command {
        case "play-apps":
            guard let apps = try await play.searchApps() else { fail("The Play Developer Reporting API is not enabled for this service account's project.") }
            for a in apps { print("\(a.packageName)\t\(a.name)") }
        case "play-tracks":
            guard let pkg = option("--package") else { fail("--package is required") }
            let o = try await play.overview(package: pkg)
            print("title: \(o.details.title ?? "?") · language \(o.details.defaultLanguage ?? "?")")
            for t in o.tracks {
                print("\(t.track):")
                for r in t.releases { print("  \(r.name)\t\(r.versionCodes.joined(separator: ","))\t\(r.status)\(r.userFraction.map { " \(Int($0 * 100))%" } ?? "")") }
            }
        default: fail("unknown command \(command)")
        }
    } catch { fail(error.localizedDescription) }
    exit(0)
}

guard let keyID = option("--key-id"), let issuer = option("--issuer") else { fail("--key-id and --issuer are required") }
let keyPath = option("--key-file") ?? NSString(string: "~/.appstoreconnect/private_keys/AuthKey_\(keyID).p8").expandingTildeInPath
guard let pem = try? String(contentsOfFile: keyPath, encoding: .utf8) else { fail("cannot read \(keyPath)") }

let df = DateFormatter()
df.dateFormat = "yyyy-MM-dd HH:mm"

do {
    let client = ASCClient(key: try ASCKey(keyID: keyID, issuerID: issuer, pem: pem))
    switch command {
    case "team":
        print(try await client.teamID() ?? "unknown")
    case "apps":
        for a in try await client.apps() { print("\(a.id)\t\(a.bundleID)\t\(a.name)") }
    case "builds":
        guard let app = option("--app") else { fail("--app is required") }
        for b in try await client.builds(appID: app, limit: 15) {
            print("\(b.version) (\(b.number))\t\(b.processingState)\tint=\(b.internalState ?? "-")\text=\(b.externalState ?? "-")\treview=\(b.reviewState ?? "-")\tgroups=\(b.groupIDs.count)\t\(b.uploaded.map(df.string(from:)) ?? "")")
        }
    case "groups":
        guard let app = option("--app") else { fail("--app is required") }
        for g in try await client.betaGroups(appID: app) {
            print("\(g.id)\t\(g.isInternal ? "internal" : "external")\t\(g.testerCount.map(String.init) ?? "?") testers\t\(g.name)\t\(g.publicLink ?? "")")
        }
    case "bundle":
        guard let bundle = option("--bundle") else { fail("--bundle is required") }
        let registered = try await client.bundleID(bundle)
        let app = try await client.app(bundleID: bundle)
        print("bundle id registered: \(registered != nil) · app record: \(app.map { "\($0.name) (\($0.id))" } ?? "none")")
    case "readiness":
        guard let app = option("--app") else { fail("--app is required") }
        let versions = try await client.versions(appID: app)
        guard let v = versions.first(where: { editableVersionStates.contains($0.state) }) else { fail("No editable App Store version") }
        let r = try await client.readiness(appID: app, versionID: v.id, buildID: nil)
        print("Version \(v.version) (\(v.state)) · shipped before: \(r.hasShipped)")
        for i in r.items { print("\(i.ok ? "✓" : "✗") \(i.title)\(i.detail.map { " — \($0)" } ?? "")") }
    case "versions":
        guard let app = option("--app") else { fail("--app is required") }
        for v in try await client.versions(appID: app) { print("\(v.version)\t\(v.platform)\t\(v.state)") }
    default:
        fail("unknown command \(command)")
    }
} catch {
    fail(error.localizedDescription)
}

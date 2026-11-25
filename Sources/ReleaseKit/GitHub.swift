import Foundation

/// Where a project lives on GitHub, read from its git remote.
public struct GitHubRepo: Sendable, Hashable, Codable {
    public let owner: String
    public let name: String
    /// The Flutter project folder relative to the repository root ("." when it is the root).
    public let projectDir: String

    public var fullName: String { "\(owner)/\(name)" }
    public var actionsURL: URL { URL(string: "https://github.com/\(fullName)/actions")! }

    /// Reads `origin` of the repository that holds `projectRoot`.
    public static func detect(_ projectRoot: URL) async -> GitHubRepo? {
        guard let remote = try? await Shell.capture("/usr/bin/git", ["-C", projectRoot.path, "remote", "get-url", "origin"]),
              let top = try? await Shell.capture("/usr/bin/git", ["-C", projectRoot.path, "rev-parse", "--show-toplevel"]) else { return nil }
        let r = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = r.range(of: #"github\.com[:/]([^/]+)/([^/]+?)(\.git)?$"#, options: .regularExpression) else { return nil }
        let parts = r[m].replacingOccurrences(of: "github.com", with: "").dropFirst().split(separator: "/")
        guard parts.count == 2 else { return nil }
        let rootPath = URL(fileURLWithPath: top.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
        let projPath = projectRoot.resolvingSymlinksInPath().path
        var rel = projPath.hasPrefix(rootPath) ? String(projPath.dropFirst(rootPath.count)) : ""
        if rel.hasPrefix("/") { rel.removeFirst() }
        return GitHubRepo(owner: String(parts[0]), name: String(parts[1]).replacingOccurrences(of: ".git", with: ""),
                          projectDir: rel.isEmpty ? "." : rel)
    }
}

public struct WorkflowRun: Sendable, Hashable {
    public let id: Int
    public let status: String
    public let conclusion: String?
    public let htmlURL: String
    public let title: String
}

public struct WorkflowStep: Sendable, Hashable {
    public let name: String
    public let status: String
    public let conclusion: String?
    public let started: Date?
    public let completed: Date?
}

/// GitHub REST calls Release Desk needs for cloud builds. Signs in with the
/// GitHub CLI's token (`gh auth token`) or a token saved in the Keychain.
public actor GitHubClient {
    public static let workflowFile = "release-desk-ios.yml"
    public static let secretNames = ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY"]
    private var token: String?
    private let session = URLSession(configuration: .ephemeral)

    public init() {}

    public static let keychainAccount = "github-token"

    /// The token, from the Keychain or the GitHub CLI.
    func authToken() async throws -> String {
        if let token { return token }
        if let saved = try? Keychain.read(account: Self.keychainAccount), !saved.isEmpty {
            token = saved
            return saved
        }
        if let t = try? await Shell.capture("gh", ["auth", "token"]), !t.isEmpty {
            token = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return token!
        }
        throw ReleaseError.precondition("Release Desk needs GitHub: sign in with the GitHub CLI (gh auth login) or save a token in Settings.")
    }

    /// The signed-in GitHub user, to show who Release Desk acts as.
    public func login() async throws -> String {
        try await send("GET", "/user")["login"].string ?? "?"
    }

    @discardableResult
    func send(_ method: String, _ path: String, body: JSONValue? = nil, accept: String = "application/vnd.github+json") async throws -> JSONValue {
        var req = URLRequest(url: URL(string: path.hasPrefix("https://") ? path : "https://api.github.com\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(try await authToken())", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = data.isEmpty ? JSONValue.null : ((try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .string(String(decoding: data, as: UTF8.self)))
        guard (200..<300).contains(status) else {
            throw ReleaseError.api(status: status, path: "github.com\(path)", messages: [json["message"].string ?? "GitHub said no"])
        }
        return json
    }

    public func defaultBranch(_ repo: GitHubRepo) async throws -> String {
        try await send("GET", "/repos/\(repo.fullName)")["default_branch"].string ?? "main"
    }

    /// Whether the workflow is on the default branch (needed to run it).
    public func hasWorkflow(_ repo: GitHubRepo) async throws -> Bool {
        do {
            _ = try await send("GET", "/repos/\(repo.fullName)/actions/workflows/\(Self.workflowFile)")
            return true
        } catch let e as ReleaseError where e.httpStatus == 404 {
            return false
        }
    }

    /// Names of the Actions secrets the workflow needs that the repository has.
    public func secretsPresent(_ repo: GitHubRepo) async throws -> Set<String> {
        let r = try await send("GET", "/repos/\(repo.fullName)/actions/secrets?per_page=100")
        return Set(r["secrets"].array.compactMap { $0["name"].string })
    }

    /// Sets an Actions secret with the GitHub CLI, which encrypts it for the repository.
    public func setSecret(_ name: String, value: String, repo: GitHubRepo) async throws {
        let out = LineCollector()
        let code = try await Shell.run("gh", ["secret", "set", name, "--repo", repo.fullName], stdin: Data(value.utf8)) { out.append($0) }
        guard code == 0 else { throw ReleaseError.command("gh secret set \(name)", code: code, tail: out.tail(3)) }
    }

    /// Starts the workflow; returns once GitHub lists the run.
    public func dispatch(_ repo: GitHubRepo, ref: String, inputs: [String: String], marker: String) async throws -> WorkflowRun {
        let started = Date()
        try await send("POST", "/repos/\(repo.fullName)/actions/workflows/\(Self.workflowFile)/dispatches",
                       body: ["ref": .string(ref), "inputs": .object(inputs.mapValues { .string($0) })])
        for _ in 0..<40 {
            try await Task.sleep(for: .seconds(3))
            let r = try await send("GET", "/repos/\(repo.fullName)/actions/workflows/\(Self.workflowFile)/runs?event=workflow_dispatch&per_page=10")
            if let run = r["workflow_runs"].array.first(where: { ($0["display_title"].string ?? "").contains(marker) }) {
                return Self.run(run)
            }
            if Date().timeIntervalSince(started) > 120 { break }
        }
        throw ReleaseError.precondition("GitHub accepted the run but did not list it. Check the Actions tab.")
    }

    public func run(_ repo: GitHubRepo, id: Int) async throws -> WorkflowRun {
        Self.run(try await send("GET", "/repos/\(repo.fullName)/actions/runs/\(id)"))
    }

    public func steps(_ repo: GitHubRepo, runID: Int) async throws -> (jobID: Int?, steps: [WorkflowStep]) {
        let r = try await send("GET", "/repos/\(repo.fullName)/actions/runs/\(runID)/jobs")
        guard let job = r["jobs"][0].isNull ? nil : r["jobs"][0] else { return (nil, []) }
        return (job["id"].int, job["steps"].array.map {
            WorkflowStep(name: $0["name"].string ?? "?", status: $0["status"].string ?? "?", conclusion: $0["conclusion"].string,
                         started: $0["started_at"].date, completed: $0["completed_at"].date)
        })
    }

    /// The last lines of a job's log, for when a step fails.
    public func logTail(_ repo: GitHubRepo, jobID: Int, lines: Int = 40) async -> [String] {
        guard let text = (try? await send("GET", "/repos/\(repo.fullName)/actions/jobs/\(jobID)/logs", accept: "application/vnd.github+json"))?.string
        else { return [] }
        return Array(text.split(separator: "\n").suffix(lines).map { line in
            // Drop the timestamp GitHub puts in front of every line.
            let s = String(line)
            if let r = s.range(of: #"^\d{4}-\d\d-\d\dT[\d:.]+Z "#, options: .regularExpression) { return String(s[r.upperBound...]) }
            return s
        })
    }

    public func cancel(_ repo: GitHubRepo, runID: Int) async {
        _ = try? await send("POST", "/repos/\(repo.fullName)/actions/runs/\(runID)/cancel")
    }

    static func run(_ j: JSONValue) -> WorkflowRun {
        WorkflowRun(id: j["id"].int ?? 0, status: j["status"].string ?? "?", conclusion: j["conclusion"].string,
                    htmlURL: j["html_url"].string ?? "", title: j["display_title"].string ?? "")
    }
}

/// The workflow Release Desk adds to a project: it builds the iOS app on a
/// GitHub macOS runner the same way the local pipeline does, and uploads it.
/// Release Desk then does the TestFlight steps through the API.
public enum CloudWorkflow {
    public static func yaml(projectDir: String, recipe: IOSRecipe, teamID: String?, flutterVersion: String?) -> String {
        let flutter = flutterVersion.map { "          flutter-version: \($0)" } ?? "          channel: stable"
        return """
        # Written by Release Desk. Builds the iOS app on a GitHub macOS runner,
        # signs it with Apple's cloud signing and uploads it to App Store Connect.
        # Release Desk starts it and then does the TestFlight steps itself.
        # Needs the repository secrets ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY.
        name: Release Desk iOS
        run-name: Release Desk iOS ${{ inputs.version }} (${{ inputs.build }}) ${{ inputs.release_desk_id }}

        on:
          workflow_dispatch:
            inputs:
              version:
                description: Version (CFBundleShortVersionString)
                required: true
              build:
                description: Build number (CFBundleVersion)
                required: true
              upload:
                description: Upload to App Store Connect (false builds and signs only)
                type: boolean
                default: true
              release_desk_id:
                description: Set by Release Desk to find this run
                required: false
                default: ""

        jobs:
          ios:
            runs-on: macos-latest
            timeout-minutes: 75
            defaults:
              run:
                working-directory: \(projectDir)
            env:
              ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
              ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
            steps:
              - name: Check out
                uses: actions/checkout@v4

              - name: Pick the newest Xcode
                run: |
                  XC=$(ls -d /Applications/Xcode_*.app | sort -V | tail -1)
                  sudo xcode-select -s "$XC"
                  xcodebuild -version

              - name: Set up Flutter
                uses: subosito/flutter-action@v2
                with:
        \(flutter)
                  cache: true

              - name: API key
                env:
                  ASC_PRIVATE_KEY: ${{ secrets.ASC_PRIVATE_KEY }}
                run: |
                  mkdir -p "$RUNNER_TEMP/keys"
                  printf '%s' "$ASC_PRIVATE_KEY" > "$RUNNER_TEMP/keys/AuthKey_$ASC_KEY_ID.p8"

              - name: Archive
                run: flutter build ipa --release --no-codesign --build-name "${{ inputs.version }}" --build-number "${{ inputs.build }}"

              - name: Pre-sign
                run: |
                  APP=build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app
                  for f in "$APP"/Frameworks/*.framework "$APP"/Frameworks/*.dylib "$APP"/PlugIns/*.appex; do
                    [ -e "$f" ] && codesign -f -s - "$f"
                  done
                  if [ -f "\(recipe.entitlements)" ]; then
                    codesign -f -s - --entitlements "\(recipe.entitlements)" "$APP"
                  else
                    codesign -f -s - "$APP"
                  fi

              - name: Export and sign
                run: |
                  OPTS="\(recipe.exportOptions)"
                  if [ ! -f "$OPTS" ]; then
                    OPTS="$RUNNER_TEMP/ExportOptions.plist"
                    /usr/libexec/PlistBuddy -c "Add :method string app-store-connect" -c "Add :destination string export" \\
                      -c "Add :signingStyle string automatic" -c "Add :teamID string \(teamID ?? "")" "$OPTS"
                  fi
                  xcodebuild -exportArchive -archivePath build/ios/archive/Runner.xcarchive -exportPath build/ios/release-desk \\
                    -exportOptionsPlist "$OPTS" -allowProvisioningUpdates \\
                    -authenticationKeyPath "$RUNNER_TEMP/keys/AuthKey_$ASC_KEY_ID.p8" \\
                    -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
                  ls -la build/ios/release-desk

              - name: Upload
                if: ${{ inputs.upload }}
                run: |
                  xcrun altool --upload-app -f build/ios/release-desk/*.ipa -t ios \\
                    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \\
                    --p8-file-path "$RUNNER_TEMP/keys/AuthKey_$ASC_KEY_ID.p8"

              - name: Remove the key
                if: always()
                run: rm -rf "$RUNNER_TEMP/keys"

        """
    }
}

import Foundation

/// What Release Desk reads from a Flutter project folder.
public struct FlutterProject: Sendable, Hashable {
    public let root: URL
    public let name: String
    public let version: String
    public let buildNumber: Int
    public let iosBundleID: String?
    public let androidPackage: String?
    public let hasExportOptions: Bool
    public let hasEntitlements: Bool

    public var pubspec: URL { root.appendingPathComponent("pubspec.yaml") }

    public static func inspect(_ root: URL, recipe: IOSRecipe = IOSRecipe()) throws -> FlutterProject {
        let pubspecURL = root.appendingPathComponent("pubspec.yaml")
        guard let pubspec = try? String(contentsOf: pubspecURL, encoding: .utf8) else {
            throw ReleaseError.precondition("No pubspec.yaml in \(root.path). Pick the Flutter app folder.")
        }
        let name = firstMatch(#"(?m)^name:\s*(\S+)"#, in: pubspec) ?? root.lastPathComponent
        let full = firstMatch(#"(?m)^version:\s*([^\s#]+)"#, in: pubspec) ?? "1.0.0+1"
        let parts = full.split(separator: "+", maxSplits: 1)
        let version = String(parts.first ?? "1.0.0")
        let number = parts.count > 1 ? Int(parts[1]) ?? 1 : 1

        let pbx = try? String(contentsOf: root.appendingPathComponent("ios/Runner.xcodeproj/project.pbxproj"), encoding: .utf8)
        let ids = pbx.map { allMatches(#"PRODUCT_BUNDLE_IDENTIFIER = "?([^";]+)"?;"#, in: $0) } ?? []
        let bundle = ids.filter { !$0.contains("Tests") && !$0.contains("$(") }.min(by: { $0.count < $1.count })

        var package: String?
        for f in ["android/app/build.gradle.kts", "android/app/build.gradle"] {
            if let g = try? String(contentsOf: root.appendingPathComponent(f), encoding: .utf8),
               let p = firstMatch(#"applicationId\s*=?\s*"([^"]+)""#, in: g) {
                package = p
                break
            }
        }
        let fm = FileManager.default
        return FlutterProject(root: root, name: name, version: version, buildNumber: number, iosBundleID: bundle,
                              androidPackage: package,
                              hasExportOptions: fm.fileExists(atPath: root.appendingPathComponent(recipe.exportOptions).path),
                              hasEntitlements: fm.fileExists(atPath: root.appendingPathComponent(recipe.entitlements).path))
    }

    /// Rewrites `version:` in pubspec.yaml, keeping the rest of the file.
    public func writeVersion(_ version: String, build: Int) throws {
        let text = try String(contentsOf: pubspec, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"(?m)^version:\s*[^\s#]+"#)
        let range = NSRange(text.startIndex..., in: text)
        guard regex.firstMatch(in: text, range: range) != nil else {
            throw ReleaseError.precondition("pubspec.yaml has no version: line")
        }
        let updated = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "version: \(version)+\(build)")
        try updated.write(to: pubspec, atomically: true, encoding: .utf8)
    }

    /// Commit subjects since a date, newest first, for drafting What to Test.
    public func commits(since: Date?, limit: Int = 30) async -> [String] {
        var args = ["-C", root.path, "log", "--no-merges", "-n", "\(limit)", "--format=%s"]
        if let since { args.append("--since=\(ISO8601DateFormatter().string(from: since))") }
        guard let out = try? await Shell.capture("/usr/bin/git", args) else { return [] }
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

func firstMatch(_ pattern: String, in text: String) -> String? {
    allMatches(pattern, in: text).first
}

func allMatches(_ pattern: String, in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
        $0.numberOfRanges > 1 ? Range($0.range(at: 1), in: text).map { String(text[$0]) } : nil
    }
}

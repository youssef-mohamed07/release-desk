import Foundation

extension ASCClient {
    /// The registered bundle id, if there is one.
    public func bundleID(_ identifier: String) async throws -> String? {
        let r = try await send("GET", "/v1/bundleIds", query: ["filter[identifier]": identifier, "fields[bundleIds]": "identifier", "limit": "5"])
        return r["data"].array.first { $0["attributes"]["identifier"].string == identifier }?["id"].string
    }

    /// Registers an explicit iOS bundle id on the team.
    public func registerBundleID(_ identifier: String, name: String) async throws -> String {
        if let existing = try await bundleID(identifier) { return existing }
        let r = try await send("POST", "/v1/bundleIds", body: [
            "data": ["type": "bundleIds", "attributes": [
                "identifier": .string(identifier), "name": .string(name), "platform": "IOS",
            ]],
        ])
        return r["data"]["id"].string ?? ""
    }

    /// The App Store Connect app for a bundle id, once it exists.
    public func app(bundleID: String) async throws -> ASCApp? {
        let r = try await send("GET", "/v1/apps", query: ["filter[bundleId]": bundleID, "fields[apps]": "name,bundleId,sku,primaryLocale"])
        guard let d = r["data"].array.first else { return nil }
        let a = d["attributes"]
        return ASCApp(id: d["id"].string ?? "", name: a["name"].string ?? "?", bundleID: a["bundleId"].string ?? bundleID,
                      sku: a["sku"].string ?? "", primaryLocale: a["primaryLocale"].string ?? "")
    }

    /// An internal group that gets every build, or an external one with a public link.
    public func createBetaGroup(appID: String, name: String, isInternal: Bool) async throws {
        var attrs: [String: JSONValue] = ["name": .string(name)]
        if isInternal {
            attrs["isInternalGroup"] = true
            attrs["hasAccessToAllBuilds"] = true
        } else {
            attrs["publicLinkEnabled"] = true
            attrs["publicLinkLimitEnabled"] = false
        }
        try await send("POST", "/v1/betaGroups", body: [
            "data": ["type": "betaGroups", "attributes": .object(attrs),
                     "relationships": ["app": ["data": ["type": "apps", "id": .string(appID)]]]],
        ])
    }
}

/// An Android upload key for a project: a keystore Release Desk makes, its
/// password in the Keychain, and android/key.properties pointing at it.
public enum UploadKey {
    public static var folder: URL { WorkspaceStore.folder.appendingPathComponent("Upload Keys", isDirectory: true) }

    /// Whether android/app/build.gradle(.kts) already signs release builds from key.properties.
    public static func gradleReadsKeyProperties(_ projectRoot: URL) -> Bool {
        for f in ["android/app/build.gradle.kts", "android/app/build.gradle"] {
            if let t = try? String(contentsOf: projectRoot.appendingPathComponent(f), encoding: .utf8) {
                return t.contains("key.properties")
            }
        }
        return false
    }

    public static func usesKotlinGradle(_ projectRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("android/app/build.gradle.kts").path)
    }

    /// Whether git ignores android/key.properties (Flutter's template does).
    public static func keyPropertiesIgnored(_ projectRoot: URL) async -> Bool {
        (try? await Shell.capture("/usr/bin/git", ["-C", projectRoot.path, "check-ignore", "-q", "android/key.properties"])) != nil
    }

    /// Makes the keystore and writes key.properties. Returns the keystore path.
    public static func create(projectRoot: URL, package: String, owner: String) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keystore = folder.appendingPathComponent("\(package)-upload.jks")
        guard !FileManager.default.fileExists(atPath: keystore.path) else {
            throw ReleaseError.precondition("An upload key for \(package) already exists at \(keystore.path).")
        }
        let password = randomPassword()
        try Keychain.save(password, account: "upload-key:\(package)")
        let tool = FileManager.default.fileExists(atPath: "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool")
            ? "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool" : "keytool"
        let dname = "CN=\(owner.replacingOccurrences(of: ",", with: " ")), O=\(owner.replacingOccurrences(of: ",", with: " "))"
        _ = try await Shell.capture(tool, ["-genkeypair", "-keystore", keystore.path, "-storetype", "JKS", "-keyalg", "RSA",
                                           "-keysize", "2048", "-validity", "10000", "-alias", "upload",
                                           "-storepass", password, "-keypass", password, "-dname", dname])
        let props = """
        storePassword=\(password)
        keyPassword=\(password)
        keyAlias=upload
        storeFile=\(keystore.path)

        """
        let file = projectRoot.appendingPathComponent("android/key.properties")
        try props.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return keystore
    }

    /// What to add to android/app/build.gradle(.kts) so release builds use the key.
    public static func gradleSnippet(kotlin: Bool) -> String {
        kotlin ? """
        // Top of android/app/build.gradle.kts
        val keystoreProperties = java.util.Properties().apply {
            val f = rootProject.file("key.properties")
            if (f.exists()) load(java.io.FileInputStream(f))
        }

        // Inside android { … }
        signingConfigs {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
                storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String?
            }
        }
        buildTypes {
            release { signingConfig = signingConfigs.getByName("release") }
        }
        """ : """
        // Top of android/app/build.gradle
        def keystoreProperties = new Properties()
        def keystorePropertiesFile = rootProject.file('key.properties')
        if (keystorePropertiesFile.exists()) {
            keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
        }

        // Inside android { … }
        signingConfigs {
            release {
                keyAlias keystoreProperties['keyAlias']
                keyPassword keystoreProperties['keyPassword']
                storeFile keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null
                storePassword keystoreProperties['storePassword']
            }
        }
        buildTypes {
            release { signingConfig signingConfigs.release }
        }
        """
    }

    static func randomPassword() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var g = SystemRandomNumberGenerator()
        return String((0..<28).map { _ in chars[Int(g.next() % UInt64(chars.count))] })
    }
}

/// Creates a new Flutter app with iOS and Android.
public enum NewFlutterApp {
    public static func create(parent: URL, name: String, org: String, onLine: @escaping @Sendable (String) -> Void) async throws -> URL {
        let folder = parent.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw ReleaseError.precondition("\(folder.path) already exists.")
        }
        let code = try await Shell.run("flutter", ["create", "--org", org, "--project-name", name, "--platforms", "ios,android", folder.path],
                                       cwd: parent, onLine: onLine)
        guard code == 0 else { throw ReleaseError.command("flutter create", code: code, tail: "") }
        return folder
    }
}

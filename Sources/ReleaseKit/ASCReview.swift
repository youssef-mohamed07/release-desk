import Foundation

/// One language of an App Store version: the texts App Review reads.
public struct VersionLocalization: Sendable, Hashable, Identifiable {
    public let id: String
    public let locale: String
    public let description: String
    public let keywords: String
    public let whatsNew: String
    public let supportURL: String
    public var screenshots: Int
}

/// What is ready for App Review, and what is missing, read before submitting.
public struct ReviewReadiness: Sendable {
    public struct Item: Sendable, Hashable, Identifiable {
        public var id: String { title }
        public let title: String
        public let ok: Bool
        public let detail: String?
    }
    public var items: [Item]
    public var localizations: [VersionLocalization]
    public var attachedBuildID: String?
    /// The app has been on the App Store before, so What's New applies.
    public var hasShipped: Bool
    public var allOK: Bool { items.allSatisfy(\.ok) }
}

public struct ReviewSubmission: Sendable, Hashable, Identifiable {
    public let id: String
    public let state: String
    public let submitted: Date?
}

/// Versions Apple still lets you edit and submit.
public let editableVersionStates: Set<String> = [
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY",
]

extension ASCClient {
    public func createVersion(appID: String, version: String) async throws -> ASCVersion {
        let r = try await send("POST", "/v1/appStoreVersions", body: [
            "data": [
                "type": "appStoreVersions",
                "attributes": ["platform": "IOS", "versionString": .string(version)],
                "relationships": ["app": ["data": ["type": "apps", "id": .string(appID)]]],
            ],
        ])
        let d = r["data"], a = d["attributes"]
        return ASCVersion(id: d["id"].string ?? "", version: a["versionString"].string ?? version, platform: "IOS",
                          state: a["appVersionState"].string ?? a["appStoreState"].string ?? "PREPARE_FOR_SUBMISSION",
                          created: a["createdDate"].date, releaseType: a["releaseType"].string)
    }

    /// Reads everything App Review needs that the API can see.
    public func readiness(appID: String, versionID: String, buildID: String?) async throws -> ReviewReadiness {
        var items: [ReviewReadiness.Item] = []
        let locs = try await send("GET", "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations", query: [
            "fields[appStoreVersionLocalizations]": "locale,description,keywords,whatsNew,supportUrl", "limit": "50",
        ])
        var localizations: [VersionLocalization] = locs["data"].array.map { d in
            let a = d["attributes"]
            return VersionLocalization(id: d["id"].string ?? "", locale: a["locale"].string ?? "?", description: a["description"].string ?? "",
                                       keywords: a["keywords"].string ?? "", whatsNew: a["whatsNew"].string ?? "",
                                       supportURL: a["supportUrl"].string ?? "", screenshots: 0)
        }
        for i in localizations.indices {
            let sets = try? await send("GET", "/v1/appStoreVersionLocalizations/\(localizations[i].id)/appScreenshotSets", query: [
                "include": "appScreenshots", "limit": "50", "fields[appScreenshots]": "fileName",
            ])
            localizations[i].screenshots = sets?["included"].array.count ?? 0
        }
        for l in localizations {
            var missing: [String] = []
            if l.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("description") }
            if l.keywords.isEmpty { missing.append("keywords") }
            if l.supportURL.isEmpty { missing.append("support URL") }
            if l.screenshots == 0 { missing.append("screenshots") }
            items.append(.init(title: "\(l.locale): description, keywords, support URL, screenshots", ok: missing.isEmpty,
                               detail: missing.isEmpty ? "\(l.screenshots) screenshots" : "Missing " + missing.joined(separator: ", ")))
        }
        if localizations.isEmpty { items.append(.init(title: "Version texts", ok: false, detail: "No languages yet")) }

        // App information: privacy policy URL per language.
        if let info = try? await send("GET", "/v1/apps/\(appID)/appInfos", query: ["limit": "5"]),
           let infoID = info["data"].array.first(where: { editableVersionStates.contains($0["attributes"]["appStoreState"].string ?? $0["attributes"]["state"].string ?? "PREPARE_FOR_SUBMISSION") })?["id"].string
            ?? info["data"][0]["id"].string,
           let infoLocs = try? await send("GET", "/v1/appInfos/\(infoID)/appInfoLocalizations", query: ["limit": "50"]) {
            let without = infoLocs["data"].array.filter { ($0["attributes"]["privacyPolicyUrl"].string ?? "").isEmpty }
                .compactMap { $0["attributes"]["locale"].string }
            items.append(.init(title: "Privacy policy URL", ok: without.isEmpty, detail: without.isEmpty ? nil : "Missing for " + without.joined(separator: ", ")))
        }

        // The build: attached or chosen, processed, export compliance answered.
        let attached = try? await send("GET", "/v1/appStoreVersions/\(versionID)/build")
        let attachedID = attached?["data"]["id"].string
        if let id = buildID ?? attachedID {
            let b = try await send("GET", "/v1/builds/\(id)", query: ["fields[builds]": "version,processingState,expired,usesNonExemptEncryption"])
            let a = b["data"]["attributes"]
            let valid = a["processingState"].string == "VALID" && a["expired"].bool != true
            items.append(.init(title: "Build \(a["version"].string ?? "?")", ok: valid, detail: valid ? nil : "Not processed or expired"))
            items.append(.init(title: "Export compliance", ok: true,
                               detail: a["usesNonExemptEncryption"].isNull ? "Answered by Info.plist (ITSAppUsesNonExemptEncryption)" : nil))
        } else {
            items.append(.init(title: "Build", ok: false, detail: "Choose a processed build of this version"))
        }

        let shipped = (try? await hasShipped(appID: appID)) ?? false
        return ReviewReadiness(items: items, localizations: localizations, attachedBuildID: attachedID, hasShipped: shipped)
    }

    public func attachBuild(versionID: String, buildID: String) async throws {
        try await send("PATCH", "/v1/appStoreVersions/\(versionID)/relationships/build", body: ["data": ["type": "builds", "id": .string(buildID)]])
    }

    public func setWhatsNew(localizationID: String, text: String) async throws {
        try await send("PATCH", "/v1/appStoreVersionLocalizations/\(localizationID)", body: [
            "data": ["type": "appStoreVersionLocalizations", "id": .string(localizationID), "attributes": ["whatsNew": .string(text)]],
        ])
    }

    /// Adds a language to an App Store version. What's New is left out for an
    /// app's first version, where Apple doesn't allow it.
    @discardableResult
    public func addLocalization(versionID: String, locale: String, whatsNew: String? = nil) async throws -> String {
        var attributes: [String: JSONValue] = ["locale": .string(locale)]
        if let whatsNew, !whatsNew.isEmpty { attributes["whatsNew"] = .string(whatsNew) }
        let r = try await send("POST", "/v1/appStoreVersionLocalizations", body: [
            "data": [
                "type": "appStoreVersionLocalizations",
                "attributes": .object(attributes),
                "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": .string(versionID)]]],
            ],
        ])
        return r["data"]["id"].string ?? ""
    }

    /// The App Store version to write What's New into: the editable one with
    /// this version string, created when there is none.
    public func editableVersion(appID: String, version: String) async throws -> (version: ASCVersion, created: Bool) {
        if let v = try await versions(appID: appID).first(where: { $0.version == version && $0.platform == "IOS" && editableVersionStates.contains($0.state) }) {
            return (v, false)
        }
        return (try await createVersion(appID: appID, version: version), true)
    }

    /// Whether the app has been on the App Store before (What's New only applies then).
    public func hasShipped(appID: String) async throws -> Bool {
        try await send("GET", "/v1/apps/\(appID)/appStoreVersions", query: [
            "filter[appStoreState]": "READY_FOR_SALE,REPLACED_WITH_NEW_VERSION,REMOVED_FROM_SALE,DEVELOPER_REMOVED_FROM_SALE", "limit": "1",
        ])["data"].array.isEmpty == false
    }

    /// Writes What's New for each language of an App Store version, adding the
    /// languages it doesn't have yet. Returns one line per language for the log.
    public func writeWhatsNew(versionID: String, notes: [String: String]) async throws -> [String] {
        let locs = try await send("GET", "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations", query: [
            "fields[appStoreVersionLocalizations]": "locale", "limit": "50",
        ])
        let existing = Dictionary(locs["data"].array.compactMap { d in d["attributes"]["locale"].string.map { ($0, d["id"].string ?? "") } },
                                  uniquingKeysWith: { a, _ in a })
        var lines: [String] = []
        for (locale, text) in notes.sorted(by: { $0.key < $1.key }) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let id = existing[locale] {
                try await setWhatsNew(localizationID: id, text: text)
                lines.append("\(locale): updated")
            } else {
                try await addLocalization(versionID: versionID, locale: locale, whatsNew: text)
                lines.append("\(locale): added the language")
            }
        }
        return lines
    }

    /// MANUAL or AFTER_APPROVAL.
    public func setReleaseType(versionID: String, _ type: String) async throws {
        try await send("PATCH", "/v1/appStoreVersions/\(versionID)", body: [
            "data": ["type": "appStoreVersions", "id": .string(versionID), "attributes": ["releaseType": .string(type)]],
        ])
    }

    public func reviewSubmissions(appID: String) async throws -> [ReviewSubmission] {
        let r = try await send("GET", "/v1/reviewSubmissions", query: ["filter[app]": appID, "limit": "10",
                                                                       "fields[reviewSubmissions]": "state,submittedDate"])
        return r["data"].array.map { ReviewSubmission(id: $0["id"].string ?? "", state: $0["attributes"]["state"].string ?? "?",
                                                      submitted: $0["attributes"]["submittedDate"].date) }
    }

    /// Puts the version in a review submission (reusing an open one) and submits it.
    public func submitForReview(appID: String, versionID: String) async throws -> ReviewSubmission {
        let open = try await reviewSubmissions(appID: appID).first { $0.state == "READY_FOR_REVIEW" }
        let submissionID: String
        if let open {
            submissionID = open.id
        } else {
            let r = try await send("POST", "/v1/reviewSubmissions", body: [
                "data": ["type": "reviewSubmissions", "attributes": ["platform": "IOS"],
                         "relationships": ["app": ["data": ["type": "apps", "id": .string(appID)]]]],
            ])
            submissionID = r["data"]["id"].string ?? ""
        }
        do {
            try await send("POST", "/v1/reviewSubmissionItems", body: [
                "data": ["type": "reviewSubmissionItems", "relationships": [
                    "reviewSubmission": ["data": ["type": "reviewSubmissions", "id": .string(submissionID)]],
                    "appStoreVersion": ["data": ["type": "appStoreVersions", "id": .string(versionID)]],
                ]],
            ])
        } catch let e as ReleaseError where e.httpStatus == 409 && e.localizedDescription.lowercased().contains("already") {
            // The version is already in this submission.
        }
        let r = try await send("PATCH", "/v1/reviewSubmissions/\(submissionID)", body: [
            "data": ["type": "reviewSubmissions", "id": .string(submissionID), "attributes": ["submitted": true]],
        ])
        return ReviewSubmission(id: submissionID, state: r["data"]["attributes"]["state"].string ?? "WAITING_FOR_REVIEW",
                                submitted: r["data"]["attributes"]["submittedDate"].date)
    }

    public func cancelReview(submissionID: String) async throws {
        try await send("PATCH", "/v1/reviewSubmissions/\(submissionID)", body: [
            "data": ["type": "reviewSubmissions", "id": .string(submissionID), "attributes": ["canceled": true]],
        ])
    }

    /// Releases a version that is approved and waiting for you.
    public func releaseVersion(versionID: String) async throws {
        try await send("POST", "/v1/appStoreVersionReleaseRequests", body: [
            "data": ["type": "appStoreVersionReleaseRequests",
                     "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": .string(versionID)]]]],
        ])
    }
}

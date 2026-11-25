import Foundation

public struct ASCApp: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let bundleID: String
    public let sku: String
    public let primaryLocale: String
}

public struct ASCBuild: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    /// The build number (CFBundleVersion).
    public let number: String
    /// The version it belongs to (CFBundleShortVersionString).
    public let version: String
    public let platform: String
    public let uploaded: Date?
    public let expires: Date?
    public let processingState: String
    public let expired: Bool
    public let minOS: String?
    public let iconTemplate: String?
    public let internalState: String?
    public let externalState: String?
    public let reviewState: String?
    public let groupIDs: [String]
    public let usesNonExemptEncryption: Bool?

    public func iconURL(size: Int = 256) -> URL? {
        guard let t = iconTemplate else { return nil }
        return URL(string: t.replacingOccurrences(of: "{w}", with: "\(size)")
            .replacingOccurrences(of: "{h}", with: "\(size)")
            .replacingOccurrences(of: "{f}", with: "png"))
    }

    public var numericNumber: Int { Int(number.split(separator: ".").last ?? "") ?? 0 }
}

public struct ASCBetaGroup: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let isInternal: Bool
    public let allBuilds: Bool
    public let publicLinkEnabled: Bool
    public let publicLink: String?
    public let created: Date?
    public var testerCount: Int?
}

public struct ASCVersion: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let version: String
    public let platform: String
    public let state: String
    public let created: Date?
    public let releaseType: String?
}

public struct ASCBetaLocalization: Identifiable, Hashable, Sendable {
    public let id: String
    public let locale: String
    public let whatsNew: String
}

public struct BuildBetaState: Sendable, Hashable {
    public let internalState: String?
    public let externalState: String?
}

// MARK: - Endpoints

extension ASCClient {
    public func apps() async throws -> [ASCApp] {
        let r = try await all("/v1/apps", query: [
            "fields[apps]": "name,bundleId,sku,primaryLocale",
            "limit": "200",
        ])
        return r.data.map { d in
            let a = d["attributes"]
            return ASCApp(id: d["id"].string ?? "", name: a["name"].string ?? "?", bundleID: a["bundleId"].string ?? "",
                          sku: a["sku"].string ?? "", primaryLocale: a["primaryLocale"].string ?? "")
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The team (App ID prefix) this key belongs to, read from any bundle id.
    public func teamID() async throws -> String? {
        let r = try await send("GET", "/v1/bundleIds", query: ["fields[bundleIds]": "seedId,identifier", "limit": "1"])
        return r["data"][0]["attributes"]["seedId"].string
    }

    public func builds(appID: String, limit: Int = 40, number: String? = nil, version: String? = nil) async throws -> [ASCBuild] {
        var q: [String: String] = [
            "filter[app]": appID,
            "sort": "-uploadedDate",
            "limit": "\(limit)",
            "include": "preReleaseVersion,buildBetaDetail,betaAppReviewSubmission,betaGroups",
            "fields[builds]": "version,uploadedDate,expirationDate,processingState,expired,minOsVersion,iconAssetToken,usesNonExemptEncryption,preReleaseVersion,buildBetaDetail,betaAppReviewSubmission,betaGroups",
            "fields[preReleaseVersions]": "version,platform",
            "fields[buildBetaDetails]": "internalBuildState,externalBuildState",
            "fields[betaAppReviewSubmissions]": "betaReviewState",
            "fields[betaGroups]": "name",
            "limit[betaGroups]": "20",
        ]
        if let number { q["filter[version]"] = number }
        if let version { q["filter[preReleaseVersion.version]"] = version }
        let r = try await send("GET", "/v1/builds", query: q)
        let inc = Included(r["included"].array)
        return r["data"].array.map { d in
            let a = d["attributes"], rel = d["relationships"]
            let pre = inc.resource(for: rel["preReleaseVersion"])?["attributes"] ?? .null
            let beta = inc.resource(for: rel["buildBetaDetail"])?["attributes"] ?? .null
            let review = inc.resource(for: rel["betaAppReviewSubmission"])?["attributes"] ?? .null
            return ASCBuild(
                id: d["id"].string ?? "", number: a["version"].string ?? "?", version: pre["version"].string ?? "?",
                platform: pre["platform"].string ?? "IOS", uploaded: a["uploadedDate"].date, expires: a["expirationDate"].date,
                processingState: a["processingState"].string ?? "?", expired: a["expired"].bool ?? false,
                minOS: a["minOsVersion"].string, iconTemplate: a["iconAssetToken"]["templateUrl"].string,
                internalState: beta["internalBuildState"].string, externalState: beta["externalBuildState"].string,
                reviewState: review["betaReviewState"].string,
                groupIDs: rel["betaGroups"]["data"].array.compactMap { $0["id"].string },
                usesNonExemptEncryption: a["usesNonExemptEncryption"].bool)
        }
    }

    public func betaGroups(appID: String, withTesterCounts: Bool = true) async throws -> [ASCBetaGroup] {
        let r = try await all("/v1/betaGroups", query: [
            "filter[app]": appID,
            "fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds,publicLinkEnabled,publicLink,createdDate",
            "limit": "200",
        ])
        var groups = r.data.map { d in
            let a = d["attributes"]
            return ASCBetaGroup(id: d["id"].string ?? "", name: a["name"].string ?? "?", isInternal: a["isInternalGroup"].bool ?? false,
                                allBuilds: a["hasAccessToAllBuilds"].bool ?? false, publicLinkEnabled: a["publicLinkEnabled"].bool ?? false,
                                publicLink: a["publicLink"].string, created: a["createdDate"].date, testerCount: nil)
        }
        if withTesterCounts {
            try await withThrowingTaskGroup(of: (Int, Int?).self) { tg in
                for (i, g) in groups.enumerated() {
                    tg.addTask {
                        let page = try? await self.send("GET", "/v1/betaGroups/\(g.id)/relationships/betaTesters", query: ["limit": "1"])
                        return (i, page?["meta"]["paging"]["total"].int)
                    }
                }
                for try await (i, n) in tg { groups[i].testerCount = n }
            }
        }
        return groups.sorted { ($0.isInternal ? 0 : 1, $0.name) < ($1.isInternal ? 0 : 1, $1.name) }
    }

    public func versions(appID: String) async throws -> [ASCVersion] {
        let r = try await send("GET", "/v1/apps/\(appID)/appStoreVersions", query: [
            "fields[appStoreVersions]": "versionString,platform,appStoreState,appVersionState,createdDate,releaseType",
            "limit": "10",
        ])
        return r["data"].array.map { d in
            let a = d["attributes"]
            return ASCVersion(id: d["id"].string ?? "", version: a["versionString"].string ?? "?", platform: a["platform"].string ?? "IOS",
                              state: a["appVersionState"].string ?? a["appStoreState"].string ?? "?", created: a["createdDate"].date,
                              releaseType: a["releaseType"].string)
        }
    }

    public func betaLocalizations(buildID: String) async throws -> [ASCBetaLocalization] {
        let r = try await send("GET", "/v1/builds/\(buildID)/betaBuildLocalizations", query: ["limit": "50"])
        return r["data"].array.map { d in
            ASCBetaLocalization(id: d["id"].string ?? "", locale: d["attributes"]["locale"].string ?? "",
                                whatsNew: d["attributes"]["whatsNew"].string ?? "")
        }
    }

    /// Writes What to Test for one locale: updates the copied localization if
    /// the build has one, creates it otherwise.
    public func setWhatsNew(buildID: String, locale: String, text: String) async throws {
        let existing = try await betaLocalizations(buildID: buildID)
        let lang = locale.split(separator: "-").first.map(String.init) ?? locale
        if let loc = existing.first(where: { $0.locale == locale }) ?? existing.first(where: { $0.locale.hasPrefix(lang) }) {
            try await send("PATCH", "/v1/betaBuildLocalizations/\(loc.id)", body: [
                "data": ["type": "betaBuildLocalizations", "id": .string(loc.id), "attributes": ["whatsNew": .string(text)]],
            ])
        } else {
            try await send("POST", "/v1/betaBuildLocalizations", body: [
                "data": [
                    "type": "betaBuildLocalizations",
                    "attributes": ["locale": .string(locale), "whatsNew": .string(text)],
                    "relationships": ["build": ["data": ["type": "builds", "id": .string(buildID)]]],
                ],
            ])
        }
    }

    /// The build-side endpoint; the group-side one answers 404 for new builds.
    public func addBuild(_ buildID: String, toGroups groupIDs: [String]) async throws {
        try await send("POST", "/v1/builds/\(buildID)/relationships/betaGroups", body: [
            "data": .array(groupIDs.map { ["type": "betaGroups", "id": .string($0)] }),
        ])
    }

    public func submitForBetaReview(buildID: String) async throws {
        try await send("POST", "/v1/betaAppReviewSubmissions", body: [
            "data": ["type": "betaAppReviewSubmissions", "relationships": ["build": ["data": ["type": "builds", "id": .string(buildID)]]]],
        ])
    }

    public func betaState(buildID: String) async throws -> BuildBetaState {
        let r = try await send("GET", "/v1/builds/\(buildID)/buildBetaDetail")
        let a = r["data"]["attributes"]
        return BuildBetaState(internalState: a["internalBuildState"].string, externalState: a["externalBuildState"].string)
    }
}

// MARK: - Human words for Apple's states

public enum StateTone: Sendable { case good, active, waiting, bad, muted }

public func describeState(_ raw: String?) -> (label: String, tone: StateTone) {
    switch raw {
    case nil: return ("—", .muted)
    case "VALID": return ("Processed", .good)
    case "PROCESSING": return ("Processing", .active)
    case "FAILED", "INVALID": return ("Failed", .bad)
    case "IN_BETA_TESTING": return ("Testing", .good)
    case "READY_FOR_BETA_TESTING": return ("Ready to test", .good)
    case "READY_FOR_BETA_SUBMISSION": return ("Ready to submit", .waiting)
    case "WAITING_FOR_BETA_REVIEW": return ("Waiting for review", .active)
    case "IN_BETA_REVIEW": return ("In review", .active)
    case "BETA_REJECTED", "REJECTED": return ("Rejected", .bad)
    case "BETA_APPROVED", "APPROVED": return ("Approved", .good)
    case "WAITING_FOR_REVIEW": return ("Waiting for review", .active)
    case "IN_REVIEW": return ("In review", .active)
    case "MISSING_EXPORT_COMPLIANCE": return ("Needs export compliance", .waiting)
    case "EXPIRED": return ("Expired", .muted)
    case "IN_EXPORT_COMPLIANCE_REVIEW": return ("Compliance review", .active)
    case "PROCESSING_EXCEPTION": return ("Processing error", .bad)
    case "PREPARE_FOR_SUBMISSION": return ("Preparing", .waiting)
    case "READY_FOR_SALE", "READY_FOR_DISTRIBUTION": return ("On the App Store", .good)
    case "PENDING_DEVELOPER_RELEASE": return ("Pending your release", .waiting)
    case "DEVELOPER_REJECTED": return ("Pulled back", .muted)
    case "METADATA_REJECTED": return ("Metadata rejected", .bad)
    case "ACCEPTED": return ("Accepted", .good)
    case "WAITING": return ("Waiting", .waiting)
    default:
        let s = raw!.replacingOccurrences(of: "_", with: " ").lowercased()
        return (s.prefix(1).uppercased() + s.dropFirst(), .muted)
    }
}

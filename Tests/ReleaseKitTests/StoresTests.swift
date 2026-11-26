import Foundation
import Testing
@testable import ReleaseKit

@Test func appIDsTellTheirStore() {
    #expect(StoreProvider.of(appID: "1234567890") == .apple)
    #expect(StoreProvider.of(appID: "play:com.example.app") == .google)
    #expect(StoreProvider.of(appID: "agc:com.example.app") == .huawei)
    #expect(StoreProvider.of(appID: "msstore:9NBLGGH4R315") == .microsoft)
}

@Test func newCredentialsRoundTripAndKeepTheirSecretsApart() throws {
    let agc = Credential.agcClient(clientID: "123")
    let ms = Credential.partnerCenter(tenantID: "t", clientID: "c", sellerID: "s")
    for c in [agc, ms] {
        let back = try JSONDecoder().decode(Credential.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }
    #expect(agc.secretAccount == "agc:123" && agc.store == .huawei && agc.takesPackages && !agc.isGoogle)
    #expect(ms.secretAccount == "ms:c" && ms.store == .microsoft && !ms.takesPackages)
    #expect(Credential.googleUser(email: "a@b.c").isGoogle)
}

@Test func androidRunsOnlyHaveTheStoresTheyGoTo() {
    #expect(StepID.steps(for: .android) == [.prepare, .bundle, .checkSigning, .playRelease, .agcRelease])
    #expect(StepID.steps(for: .android, cloud: true) == [.prepare, .cloudBuild, .playRelease, .agcRelease])
    #expect(StepID.steps(for: .windows, cloud: true) == [.prepare, .cloudBuild, .msSubmit])
}

@Test func windowsWorkflowBuildsAndUploadsWithTheStoreCLI() {
    let y = CloudTarget.windows.yaml(projectDir: "mobile", recipe: IOSRecipe(), teamID: nil, flutterVersion: "3.27.0")
    #expect(CloudTarget.windows.workflowFile == "release-desk-windows.yml")
    #expect(y.contains("runs-on: windows-latest"))
    #expect(y.contains("microsoft/microsoft-store-apppublisher@v1.4"))
    #expect(y.contains("msstore package . --version \"${{ inputs.version }}.0\""))
    #expect(y.contains("--noCommit"))
    #expect(y.contains("if: inputs.upload != 'false'"))
    #expect(y.contains("working-directory: mobile"))
    #expect(y.contains("flutter-version: 3.27.0"))
    for name in CloudTarget.windows.secretNames { #expect(y.contains("secrets.\(name)")) }
    #expect(!y.contains("\t"))
}

@Test func appGalleryLanguageCodes() {
    #expect(AppGalleryClient.language("en-US") == "en-US")
    #expect(AppGalleryClient.language("ar") == "ar")
    #expect(AppGalleryClient.language("iw-IL") == "he_IL")
}

@Test func jsonValueSettingMakesThePath() {
    let v: JSONValue = ["listings": ["en-us": ["baseListing": ["title": "A"]]]]
    let w = v.setting(["listings", "en-us", "baseListing", "releaseNotes"], to: "Fixed it")
    #expect(w["listings"]["en-us"]["baseListing"]["releaseNotes"].string == "Fixed it")
    #expect(w["listings"]["en-us"]["baseListing"]["title"].string == "A")
    let x = JSONValue.null.setting(["a", "b"], to: 1)
    #expect(x["a"]["b"].int == 1)
}

@Test func agcStatesHaveWords() {
    let app = AGCApp(appID: "1", package: "p", name: "n", version: "1.0", versionOnShelf: nil, releaseState: 4, reviewNote: nil,
                     newFeatures: [:], phasedState: nil)
    #expect(app.stateTitle == "In review")
}

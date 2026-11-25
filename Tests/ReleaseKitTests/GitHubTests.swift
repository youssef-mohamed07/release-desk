import Foundation
import Testing
@testable import ReleaseKit

@Test func workflowBuildsFromTheProjectFolder() {
    let y = CloudWorkflow.yaml(projectDir: "mobile", recipe: IOSRecipe(), teamID: "ABCDE12345", flutterVersion: "3.50.0")
    #expect(y.contains("working-directory: mobile"))
    #expect(y.contains("flutter-version: 3.50.0"))
    #expect(y.contains("secrets.ASC_PRIVATE_KEY"))
    #expect(y.contains(#"--build-number "${{ inputs.build }}""#))
    #expect(y.contains("if: ${{ inputs.upload }}"))
    #expect(y.contains("ios/Runner/Runner.entitlements"))
    #expect(!y.contains("\t"))
}

@Test func repoIsReadFromTheRemote() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let app = dir.appendingPathComponent("mobile")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    _ = try await Shell.capture("/usr/bin/git", ["-C", dir.path, "init", "-q"])
    _ = try await Shell.capture("/usr/bin/git", ["-C", dir.path, "remote", "add", "origin", "git@github.com:Some-Org/some-app.git"])
    let repo = await GitHubRepo.detect(app)
    #expect(repo?.fullName == "Some-Org/some-app")
    #expect(repo?.projectDir == "mobile")
}

import Foundation
import Testing
@testable import ReleaseKit

@Test func captureKeepsShortOutput() async throws {
    for _ in 0..<20 {
        let out = try await Shell.capture("/bin/echo", ["hello"], path: "/usr/bin:/bin")
        #expect(out == "hello")
    }
}

@Test func runStreamsEveryLine() async throws {
    let lines = LineCollector()
    let code = try await Shell.run("/bin/sh", ["-c", "for i in 1 2 3 4 5; do echo line$i; done; echo err >&2; exit 3"], path: "/usr/bin:/bin") { lines.append($0) }
    #expect(code == 3)
    #expect(lines.text == "line1\nline2\nline3\nline4\nline5\nerr")
}

@Test func pubspecVersionRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "name: demo\nversion: 1.2.3+41 # keep\ndependencies:\n".write(to: dir.appendingPathComponent("pubspec.yaml"), atomically: true, encoding: .utf8)
    let p = try FlutterProject.inspect(dir)
    #expect(p.version == "1.2.3" && p.buildNumber == 41)
    try p.writeVersion("1.2.4", build: 42)
    let q = try FlutterProject.inspect(dir)
    #expect(q.version == "1.2.4" && q.buildNumber == 42)
    #expect(try String(contentsOf: dir.appendingPathComponent("pubspec.yaml"), encoding: .utf8).contains("# keep"))
}

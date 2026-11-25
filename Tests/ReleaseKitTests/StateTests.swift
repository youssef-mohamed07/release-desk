import Foundation
import Testing
@testable import ReleaseKit

@Test func includedResourcesResolveByTypeAndID() throws {
    let json = """
    {"data":[{"type":"builds","id":"b1","attributes":{"version":"8","processingState":"VALID"},
      "relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"p1"}},
                       "buildBetaDetail":{"data":{"type":"buildBetaDetails","id":"d1"}}}}],
     "included":[{"type":"preReleaseVersions","id":"p1","attributes":{"version":"1.0.0","platform":"IOS"}},
                 {"type":"buildBetaDetails","id":"d1","attributes":{"externalBuildState":"IN_BETA_TESTING"}}]}
    """
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    let inc = Included(doc["included"].array)
    let build = doc["data"][0]
    #expect(inc.resource(for: build["relationships"]["preReleaseVersion"])?["attributes"]["version"].string == "1.0.0")
    #expect(inc.resource(for: build["relationships"]["buildBetaDetail"])?["attributes"]["externalBuildState"].string == "IN_BETA_TESTING")
    #expect(build["attributes"]["version"].string == "8")
}

@Test func statesReadAsWords() {
    #expect(describeState("IN_BETA_TESTING").label == "Testing")
    #expect(describeState("WAITING_FOR_BETA_REVIEW").tone == .active)
    #expect(describeState("SOMETHING_NEW").label == "Something new")
}

@Test func iconTemplateFillsSize() {
    let b = ASCBuild(id: "1", number: "8", version: "1.0.0", platform: "IOS", uploaded: nil, expires: nil, processingState: "VALID",
                     expired: false, minOS: nil, iconTemplate: "https://x.test/a.png/{w}x{h}bb.{f}", internalState: nil,
                     externalState: nil, reviewState: nil, groupIDs: [], usesNonExemptEncryption: nil)
    #expect(b.iconURL(size: 64)?.absoluteString == "https://x.test/a.png/64x64bb.png")
    #expect(b.numericNumber == 8)
}

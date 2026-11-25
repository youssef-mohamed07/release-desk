import CryptoKit
import Foundation
import Testing
@testable import ReleaseKit

@Test func tokenHasThreeParts() throws {
    let pem = P256.Signing.PrivateKey().pemRepresentation
    let key = try ASCKey(keyID: "ABC123", issuerID: "issuer", pem: pem)
    let parts = try key.token().split(separator: ".")
    #expect(parts.count == 3)
}

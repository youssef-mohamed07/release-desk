import Foundation
import Testing
@testable import ReleaseKit

@Test func storeLanguagesHaveNamesAndDirection() {
    #expect(StoreLanguages.name("ar-SA").hasPrefix("Arabic"))
    #expect(StoreLanguages.name("iw-IL").hasPrefix("Hebrew"))
    #expect(StoreLanguages.isRightToLeft("ar"))
    #expect(StoreLanguages.isRightToLeft("he"))
    #expect(StoreLanguages.isRightToLeft("fa"))
    #expect(!StoreLanguages.isRightToLeft("fr-FR"))
    #expect(!StoreLanguages.isRightToLeft("ar".uppercased() + "x"))
    #expect(Set(StoreLanguages.appStore).count == StoreLanguages.appStore.count)
    #expect(Set(StoreLanguages.play).count == StoreLanguages.play.count)
}

@Test func iosStepsWriteAppStoreNotesAfterWhatToTest() {
    for cloud in [false, true] {
        let steps = StepID.steps(for: .ios, cloud: cloud)
        let notes = steps.firstIndex(of: .notes)!, store = steps.firstIndex(of: .storeNotes)!
        #expect(store == notes + 1)
        #expect(steps.firstIndex(of: .groups)! == store + 1)
    }
    #expect(!StepID.steps(for: .android).contains(.storeNotes))
}

@Test func oldRecipesStillDecode() throws {
    // A workspace written before the language fields existed.
    let json = #"{"exportOptions":"ios/ExportOptions.plist","entitlements":"ios/Runner/Runner.entitlements","cloudSigning":true,"writeBuildNumber":true,"groupIDs":[],"submitForReview":true,"locales":["ar-SA","en-US"]}"#
    let r = try JSONDecoder().decode(IOSRecipe.self, from: Data(json.utf8))
    #expect(r.appStoreLocales == nil)
    #expect(r.playLocales == nil)
    #expect(r.locales == ["ar-SA", "en-US"])
}

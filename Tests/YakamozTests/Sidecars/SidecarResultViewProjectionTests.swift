import Foundation
import PKShared
import Testing
@testable import YakamozCore

@Suite("SidecarResultView projection")
struct SidecarResultViewProjectionTests {
    @Test("value outcome projects name + value text")
    func valueOutcomeProjectsNameAndValueText() {
        let dto = ResponseDTO(
            reconstructedText: "",
            thinking: "",
            sidecarResults: [
                SidecarResult(name: "title", outcome: .value(AnyCodable("Fixing the auth bug")))
            ]
        )
        let views = dto.sidecarResultViews
        #expect(views.count == 1)
        #expect(views.first?.name == "title")
        #expect(views.first?.valueText == "Fixing the auth bug")
        #expect(views.first?.isDeclined == false)
        #expect(views.first?.failureReason == nil)
    }

    @Test("declined outcome projects name + isDeclined, no value text")
    func declinedOutcomeProjectsIsDeclined() {
        let dto = ResponseDTO(
            reconstructedText: "",
            thinking: "",
            sidecarResults: [
                SidecarResult(name: "title", outcome: .declined)
            ]
        )
        let views = dto.sidecarResultViews
        #expect(views.first?.isDeclined == true)
        #expect(views.first?.valueText == nil)
        #expect(views.first?.failureReason == nil)
    }

    @Test("failed outcome projects name + failure reason")
    func failedOutcomeProjectsFailureReason() {
        let dto = ResponseDTO(
            reconstructedText: "",
            thinking: "",
            sidecarResults: [
                SidecarResult(name: "title", outcome: .failed(reason: "schema mismatch"))
            ]
        )
        let views = dto.sidecarResultViews
        #expect(views.first?.failureReason == "schema mismatch")
        #expect(views.first?.valueText == nil)
        #expect(views.first?.isDeclined == false)
    }

    @Test("non-string value falls back to String(describing:)")
    func nonStringValueFallsBackToDescription() {
        let dto = ResponseDTO(
            reconstructedText: "",
            thinking: "",
            sidecarResults: [
                SidecarResult(name: "score", outcome: .value(AnyCodable(42)))
            ]
        )
        let views = dto.sidecarResultViews
        // AnyCodable(Int) becomes .number(42.0), so `asString` is nil and the projection
        // falls back to `String(describing: value.value)` (the `Any` projection of
        // `AnyCodable`, which for a number is `NSNumber`/`Double`-ish).
        #expect(views.first?.valueText != nil)
        #expect(views.first?.valueText != "")
    }

    @Test("empty sidecarResults yields empty views")
    func emptyResultsYieldEmptyViews() {
        let dto = ResponseDTO(reconstructedText: "", thinking: "")
        #expect(dto.sidecarResultViews.isEmpty)
    }

    @Test("views are Identifiable by result.name")
    func viewsIdentifiableByName() {
        let dto = ResponseDTO(
            reconstructedText: "",
            thinking: "",
            sidecarResults: [
                SidecarResult(name: "title", outcome: .declined),
                SidecarResult(name: "section_title", outcome: .declined)
            ]
        )
        let ids = dto.sidecarResultViews.map(\.id)
        #expect(ids == ["title", "section_title"])
    }
}

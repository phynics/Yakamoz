import Foundation
import PKShared
import Testing
@testable import YakamozCore

@Suite("SidecarResultView projection")
struct SidecarResultViewProjectionTests {
    @Test("value outcome projects name + value text")
    func valueOutcomeProjectsNameAndValueText() {
        // SID-3: the runtime emits the per-directive payload sub-object
        // (`TitleDirectivePayload`'s encoded form `{"title": "..."}`, an
        // `AnyCodable.dictionary`), not a bare string. The previous
        // bare-`AnyCodable("...")` fixture never matched the runtime shape and so was
        // false-green (it exercised `asString` directly, not the dict-decode path).
        let dto = ResponseDTO(
            reconstructedText: "",
            thinking: "",
            sidecarResults: [
                SidecarResult(
                    name: "title",
                    outcome: .value(AnyCodable.dictionary(["title": .string("Fixing the auth bug")]))
                )
            ]
        )
        let views = dto.sidecarResultViews
        #expect(views.count == 1)
        #expect(views.first?.name == "title")
        #expect(views.first?.valueText == "Fixing the auth bug")
        #expect(views.first?.isDeclined == false)
        #expect(views.first?.failureReason == nil)
    }

    @Test("value outcome recovers an off-schema single-string dict")
    func valueOutcomeRecoversOffSchema() {
        // SID-3: a provider freelanding the key (e.g. `text` instead of `title`) must
        // still render the bare title string in the inspector, not `["text": "..."]`.
        let dto = ResponseDTO(
            reconstructedText: "",
            thinking: "",
            sidecarResults: [
                SidecarResult(
                    name: "title",
                    outcome: .value(AnyCodable.dictionary(["text": .string("Riemann Conjecture Overview")]))
                )
            ]
        )
        let views = dto.sidecarResultViews
        #expect(views.first?.valueText == "Riemann Conjecture Overview")
        #expect(views.first?.isDeclined == false)
    }

    @Test("value outcome for section_title uses the camelCase payload key, not the directive name")
    func valueOutcomeUsesSectionTitlePayloadKey() {
        // SID-3: `SectionTitleDirective.name == "section_title"` but the payload key is
        // `sectionTitle` (camelCase, `@Schemable` default). The projection must key by
        // `sectionTitle`, not by the directive name — otherwise the section title is
        // silently dropped (the dict has no `section_title` entry, and the single-string
        // recover would not fire because the dict has exactly one string under a
        // *different* key).
        let dto = ResponseDTO(
            reconstructedText: "",
            thinking: "",
            sidecarResults: [
                SidecarResult(
                    name: "section_title",
                    outcome: .value(AnyCodable.dictionary(["sectionTitle": .string("Diagnosis")]))
                )
            ]
        )
        let views = dto.sidecarResultViews
        #expect(views.first?.valueText == "Diagnosis")
    }

    @Test("value outcome with an unextractable payload falls back to String(describing:)")
    func valueOutcomeUnextractableFallsBackToDescription() {
        // SID-3: empty dict — no expected key, no single-string recover candidate.
        // The projection falls through to `String(describing: value.value)` so the
        // inspector row still shows something (here the empty-dict description).
        let dto = ResponseDTO(
            reconstructedText: "",
            thinking: "",
            sidecarResults: [
                SidecarResult(
                    name: "title",
                    outcome: .value(AnyCodable.dictionary([:]))
                )
            ]
        )
        let views = dto.sidecarResultViews
        #expect(views.first?.valueText != nil)
        #expect(views.first?.valueText != "")
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

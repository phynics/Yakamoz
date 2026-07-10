import Foundation
import PKShared

/// Shared decode path for sidecar-directive `.value` payloads (SID-3).
///
/// `PositronicKit.SidecarStreamExtractor.finish` wraps the per-directive payload
/// sub-object (the `@Schemable` payload struct's encoded form, e.g.
/// `TitleDirectivePayload` → `{"title": "..."}`) in `AnyCodable(value)`, so a `.value`
/// outcome for `title`/`section_title` is an `AnyCodable.dictionary` — never a bare
/// `.string`. Calling `asString` on a dictionary returns `nil`, so the SID-1/SID-2
/// handlers silently no-op'd: the conversation title was never written and the
/// Response inspector fell back to `String(describing:)` of the dict
/// (`["text": "Riemann Conjecture Overview"]`).
///
/// `sidecarPayloadString(forKey:)` decodes the directive's payload via its expected
/// Codable key, with a single-string fallback for the off-schema shape providers
/// occasionally emit (e.g. `{"text": "..."}` instead of `{"title": "..."}`). The
/// recover rule: take the dict's only non-empty string value when the expected key is
/// absent — the model freelanced the key but its intent is unambiguous. Returns `nil`
/// for dicts with no extractable non-empty string so the caller can route to a
/// recover-but-empty / cadence-advance path.
extension AnyCodable {
    public func sidecarPayloadString(forKey key: String) -> String? {
        if let dict = asDictionary {
            if let value = dict[key]?.asString, !value.isEmpty {
                return value
            }
            // Providers sometimes freelance the key (e.g. `text` instead of `title`).
            // When the dict carries exactly one non-empty string, trust the model's
            // intent rather than dropping the value.
            let strings = dict.values.compactMap { $0.asString }.filter { !$0.isEmpty }
            if strings.count == 1 { return strings.first }
            return nil
        }
        // Bare-string tolerance: not the runtime shape (the extractor emits dicts), but
        // retained so a directly-constructed `SidecarResult` (older test fixtures, or a
        // future directive whose runtime emits a bare string) still decodes.
        return asString.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Maps a sidecar directive's `name` to its payload struct's expected Codable key.
///
/// `TitleDirectivePayload.title` and `SectionTitleDirectivePayload.sectionTitle` are
/// `@Schemable`-synthesized; `@Schemable` emits the Swift property name as the JSON
/// Schema key by default (no encoding-strategy override on either type — see
/// `TitleDirectiveTests.swift:17` / `SectionTitleDirectiveTests.swift:32`). The directive
/// `name` (used as the storage/lookup key in `SidecarStreamExtractor`'s
/// `sidecar_payload[name]` lookup) and the payload key therefore coincide for `title`
/// but **differ** for `section_title` (`name == "section_title"`, payload key
/// `sectionTitle`). Centralizing here keeps the coordinator and the `ResponseDTO`
/// projection on one decode path keyed by `result.name`.
public enum SidecarPayloadKey {
    public static func forDirective(_ name: String) -> String {
        switch name {
        case TitleDirective.name: return TitleDirective.payloadKey
        case SectionTitleDirective.name: return SectionTitleDirective.payloadKey
        default: return name
        }
    }
}

extension TitleDirective {
    /// The JSON key the `title` directive's payload (`TitleDirectivePayload.title`) is
    /// encoded/decoded under. Matches `name` here, exposed separately so the consumer
    /// never silently relies on the coincidence.
    public static let payloadKey = "title"
}

extension SectionTitleDirective {
    /// The JSON key the `section_title` directive's payload
    /// (`SectionTitleDirectivePayload.sectionTitle`) is encoded/decoded under. **Differs**
    /// from `name` (`section_title`): `@Schemable`'s default key encoding preserves the
    /// Swift property's camelCase, while the directive name is snake_case for
    /// `sidecar_payload[name]` lookup.
    public static let payloadKey = "sectionTitle"
}
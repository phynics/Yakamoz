import Foundation

/// TEX-2: shared extraction/filtering logic for the model-authored `explanation` argument
/// (TEX-1 adds it to every resolved tool's schema — `ToolExplanationParameter`). Both the
/// chat transcript (`ToolTranscriptPresentation`) and the inspector (`ToolTraceDTO`) consume
/// a raw, accumulated JSON *arguments string* — not a decoded dictionary — so this operates
/// directly on that string and is safe to call while it is still a partial, unparseable
/// streaming fragment (returns the conservative "nothing to show yet" result rather than
/// crashing or surfacing garbage).
public enum ToolCallExplanation {
    /// Parses `arguments` (a JSON object string) and returns its `explanation` value as
    /// trimmed text, or `nil` when: `arguments` is `nil`/blank, the JSON can't be parsed yet
    /// (e.g. a partial streaming chunk), the key is absent, the value isn't a string, or the
    /// trimmed string is empty. Never returns an empty string or a stringified non-string.
    public static func explanationText(fromArguments arguments: String?) -> String? {
        guard let dictionary = parsedObject(from: arguments) else { return nil }
        guard let raw = dictionary[ToolExplanationParameter.key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `arguments` with the `explanation` key removed, re-serialized deterministically
    /// (sorted keys). Returns `arguments` unchanged when it is `nil`, has no `explanation`
    /// key, or can't currently be parsed (e.g. a partial streaming chunk) — callers fall
    /// back to rendering the raw string as-is in that case, same as today.
    public static func displayArguments(fromArguments arguments: String?) -> String? {
        guard let arguments else { return nil }
        guard let dictionary = parsedObject(from: arguments) else { return arguments }
        guard dictionary[ToolExplanationParameter.key] != nil else { return arguments }

        var filtered = dictionary
        filtered.removeValue(forKey: ToolExplanationParameter.key)

        guard JSONSerialization.isValidJSONObject(filtered),
              let data = try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return arguments
        }
        return string
    }

    /// TEX-2 scope item 4: one short line steering the model to actually fill in
    /// `explanation` (TEX-1 adds the parameter to every resolved tool's schema, but the
    /// model needs prompting to use it well — per-parameter `description` does most of the
    /// steering; this is just the "why" nudge). Yakamoz is the instructional showcase, so
    /// this copy lives here, not in PositronicKit (lean-PK convention).
    public static let promptGuidance =
        "When calling a tool, fill its `explanation` argument with one short, user-facing sentence stating why you're calling it now."

    /// Composes `base` system instructions with `promptGuidance`, appended only when
    /// `hasTools` is true (tools are actually offered this turn). Returns `base` unchanged
    /// (including `nil`) when no tools are offered.
    public static func composeSystemInstructions(base: String?, hasTools: Bool) -> String? {
        guard hasTools else { return base }
        guard let base, !base.isEmpty else { return promptGuidance }
        return "\(base)\n\n\(promptGuidance)"
    }

    private static func parsedObject(from arguments: String?) -> [String: Any]? {
        guard let arguments,
              !arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return nil
        }
        return dictionary
    }
}

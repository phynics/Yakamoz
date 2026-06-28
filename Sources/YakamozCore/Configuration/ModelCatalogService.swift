import Foundation

public struct ModelCatalogService: Sendable {
    public init() {}

    public func normalize(models: [String], currentModel: String) -> [String] {
        normalize(models: models, currentModel: currentModel, currentModelPosition: .appendIfMissing)
    }

    public func normalize(
        models: [String],
        currentModel: String,
        currentModelPosition: CurrentModelPosition
    ) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for model in models.map(Self.clean).filter({ !$0.isEmpty }) {
            if seen.insert(model).inserted {
                normalized.append(model)
            }
        }

        let current = Self.clean(currentModel)
        if !current.isEmpty, seen.insert(current).inserted {
            switch currentModelPosition {
            case .prependIfMissing:
                normalized.insert(current, at: 0)
            case .appendIfMissing:
                normalized.append(current)
            }
        }

        return normalized
    }

    public enum CurrentModelPosition: Sendable {
        case prependIfMissing
        case appendIfMissing
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

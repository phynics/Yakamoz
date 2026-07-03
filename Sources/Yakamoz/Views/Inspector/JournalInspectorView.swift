import SwiftUI
import YakamozCore

/// Journal tab: shows the prompt-journal diff for this turn — stable-prefix count,
/// changed/added/removed semi-stable IDs, the volatile (non-stable) sections, and a
/// compaction marker — with prev/next navigation to adjacent turns.
struct JournalInspectorView: View {
    let inspection: InspectionPresentation
    let canSelectTurn: (Int) -> Bool
    let onSelectTurn: (Int) -> Void

    private var journal: JournalDTO {
        inspection.journal
    }

    /// Precomputed volatile-section filtering, extracted to `YakamozCore` so the YAK-16
    /// regression surface ("everything marked volatile") is unit-testable.
    private var projection: JournalInspectorProjection {
        JournalInspectorProjection(inspection: inspection)
    }

    private var navigation: TurnNavigationBounds {
        TurnNavigationBounds(currentTurnIndex: inspection.turnIndex)
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if journal.didCompact {
                        Label("Compaction occurred this turn", systemImage: "arrow.down.to.line.compress.vertical")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }

                    stat("Stable prefix", "\(journal.stablePrefixCount) sections")

                    idList("Changed", journal.changedSemiStableIDs, color: .yellow)
                    idList("Added", journal.addedSemiStableIDs, color: .green)
                    idList("Removed", journal.removedSemiStableIDs, color: .red)

                    volatileSections
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var navigationBar: some View {
        HStack {
            Button {
                onSelectTurn(navigation.previousTurnIndex)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!navigation.canSelectPrevious(canSelectTurn))
            .accessibilityLabel("Previous turn")

            Text("Turn \(inspection.turnIndex)")
                .font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity)

            Button {
                onSelectTurn(navigation.nextTurnIndex)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!navigation.canSelectNext(canSelectTurn))
            .accessibilityLabel("Next turn")
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }

    private func idList(_ title: String, _ ids: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(ids.count))")
                .font(.caption.weight(.semibold))
            if ids.isEmpty {
                Text("none").font(.caption2).foregroundStyle(.tertiary)
            } else {
                FlowTags(ids: ids, color: color)
            }
        }
    }

    /// Sections whose semi-stable IDs changed or were added this turn — i.e. the
    /// "volatile" portion of the prompt that re-rendered, as opposed to the stable prefix.
    private var volatileSections: some View {
        let matches = projection.volatileSections
        return VStack(alignment: .leading, spacing: 4) {
            Text("Volatile sections (\(matches.count))")
                .font(.caption.weight(.semibold))
            if matches.isEmpty {
                Text("none").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(matches) { section in
                    HStack(spacing: 6) {
                        Text(section.role).font(.caption2.weight(.semibold))
                        Text(section.path.joined(separator: " / "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

/// Simple wrapping tag row for semi-stable ID lists.
private struct FlowTags: View {
    let ids: [String]
    let color: Color

    var body: some View {
        // A LazyVGrid with adaptive columns gives a wrapping, pill-style layout.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 4, alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(ids, id: \.self) { id in
                Text(id)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.2), in: Capsule())
                    .lineLimit(1)
            }
        }
    }
}

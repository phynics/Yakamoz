import SwiftUI
import YakamozCore

/// Prompt tab: a `DisclosureGroup` tree of the rendered prompt sections, headed by the
/// turn's total token estimate and compression summary.
struct PromptInspectorView: View {
    let inspection: InspectionPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(inspection.sectionTree) { node in
                        SectionDisclosure(node: node, depth: 0)
                    }
                }
                .padding(8)
            }
        }
    }

    private var header: some View {
        HStack {
            Label("\(inspection.totalTokens) tokens", systemImage: "number")
            Spacer()
            Label(inspection.compression.label, systemImage: "arrow.down.right.and.arrow.up.left")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// One expandable section node. Recurses into children via nested `DisclosureGroup`s.
private struct SectionDisclosure: View {
    let node: InspectionSectionNode
    let depth: Int

    @State private var isExpanded = false

    private var section: InspectionSectionDTO {
        node.section
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) {
                    isExpanded.toggle()
                }
            } label: {
                label
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") prompt section \(section.id)")

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    metadata
                    if !section.content.isEmpty {
                        Text(section.content)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                    ForEach(node.children) { child in
                        SectionDisclosure(node: child, depth: depth + 1)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.leading, CGFloat(depth) * 8)
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(.secondary)
            Text(section.role)
                .font(.caption.weight(.semibold))
            Text(section.path.joined(separator: " / "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("\(section.estimatedTokens)t")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadata: some View {
        HStack(spacing: 10) {
            tag("priority", "\(section.priority)")
            tag("compression", section.compression)
            tag("cache", section.cachePolicy)
            if let outcome = section.compressionOutcome {
                tag("outcome", outcome)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func tag(_ key: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Text(key).foregroundStyle(.tertiary)
            Text(value)
        }
    }
}

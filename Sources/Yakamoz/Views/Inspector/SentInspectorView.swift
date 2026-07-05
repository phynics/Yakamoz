import SwiftUI
import YakamozCore

/// Sent tab: a segmented control toggling between a rendered list of the messages
/// actually sent to the provider and the raw, pretty-printed sorted-key JSON of the
/// persisted `sentMessages` DTO array.
struct SentInspectorView: View {
    let inspection: InspectionPresentation

    private enum Mode: String, CaseIterable, Identifiable {
        case rendered, raw
        var id: String {
            rawValue
        }

        var title: String {
            self == .rendered ? "Rendered" : "Raw JSON"
        }
    }

    @State private var mode: Mode = .rendered
    @State private var expandedMessageOffsets: Set<Int> = []
    @State private var isRawExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch mode {
            case .rendered: rendered
            case .raw: raw
            }
        }
    }

    private var rendered: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(inspection.sentMessages.enumerated()), id: \.offset) { offset, message in
                    let presentation = TruncatedTextPresentation(fullText: message.content)
                    let isExpanded = expandedMessageOffsets.contains(offset)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(message.role)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.15), in: Capsule())
                            if let toolCallID = message.toolCallID {
                                Text("tool-call \(toolCallID)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(presentation.displayedText(isExpanded: isExpanded))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if presentation.isTruncatable {
                            Button {
                                if isExpanded {
                                    expandedMessageOffsets.remove(offset)
                                } else {
                                    expandedMessageOffsets.insert(offset)
                                }
                            } label: {
                                Text(isExpanded ? "Show less" : presentation.expanderLabel)
                                    .font(.caption)
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(8)
        }
    }

    private var raw: some View {
        // Raw JSON renders once (not per-row inside a LazyVStack), so it doesn't hit the
        // same per-row-materialization stall as the rendered mode. It's still capped for
        // consistency and to protect against pathological cases (e.g. a system prompt in
        // the tens of thousands of characters making even a single large text-layout pass
        // noticeably slow), reusing the same projection/affordance.
        let presentation = TruncatedTextPresentation(fullText: inspection.sentMessagesJSON)

        return ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.displayedText(isExpanded: isRawExpanded))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if presentation.isTruncatable {
                    Button {
                        isRawExpanded.toggle()
                    } label: {
                        Text(isRawExpanded ? "Show less" : presentation.expanderLabel)
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(8)
        }
    }
}

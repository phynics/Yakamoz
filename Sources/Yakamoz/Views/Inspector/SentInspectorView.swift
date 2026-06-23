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
                ForEach(Array(inspection.sentMessages.enumerated()), id: \.offset) { _, message in
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
                        Text(message.content)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(8)
        }
    }

    private var raw: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(inspection.sentMessagesJSON)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}

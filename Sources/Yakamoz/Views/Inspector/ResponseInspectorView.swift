import SwiftUI
import YakamozCore

/// Response tab: the reconstructed assistant generation plus thinking, model, finish
/// reason, and token usage for the turn. Structured-output rendering (Task 10) will slot
/// in below the generation section; this view intentionally leaves that space empty.
struct ResponseInspectorView: View {
    let inspection: InspectionPresentation

    private var response: ResponseDTO? {
        inspection.response
    }

    var body: some View {
        if let response {
            content(response)
        } else {
            ContentUnavailableView(
                "No Response Yet",
                systemImage: "hourglass",
                description: Text("Response metadata is captured once this turn finishes streaming.")
            )
        }
    }

    private func content(_ response: ResponseDTO) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                metadata(response)

                if !response.thinking.isEmpty {
                    labeledBlock("Thinking", text: response.thinking, mono: false, secondary: true)
                }

                labeledBlock(
                    "Generation",
                    text: response.reconstructedText.isEmpty ? "(empty)" : response.reconstructedText,
                    mono: false,
                    secondary: false
                )

                structuredOutput(response)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Typed-reply (structured-output) section: schema requested, parsed/validated JSON, or
    /// the validation error. Renders nothing for conversations that didn't enable typed replies
    /// (all three fields `nil`).
    @ViewBuilder
    private func structuredOutput(_ response: ResponseDTO) -> some View {
        if response.structuredSchemaJSON != nil
            || response.structuredParsedJSON != nil
            || response.structuredError != nil
        {
            Divider()
            Text("Structured Reply")
                .font(.caption.weight(.bold))

            if let schema = response.structuredSchemaJSON {
                labeledBlock("Requested Schema", text: schema, mono: true, secondary: true)
            }
            if let parsed = response.structuredParsedJSON {
                labeledBlock("Parsed JSON", text: parsed, mono: true, secondary: false)
            }
            if let error = response.structuredError {
                labeledBlock("Validation Error", text: error, mono: false, secondary: false)
                    .foregroundStyle(.red)
            }
        }
    }

    private func metadata(_ response: ResponseDTO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Model", response.model ?? inspection.model)
            if let finish = response.finishReason {
                row("Finish reason", finish)
            }
            if let input = response.inputTokens {
                row("Input tokens", "\(input)")
            }
            if let output = response.outputTokens {
                row("Output tokens", "\(output)")
            }
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }

    private func labeledBlock(_ title: String, text: String, mono: Bool, secondary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            Text(text)
                .font(mono ? .system(.caption, design: .monospaced) : .callout)
                .foregroundStyle(secondary ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

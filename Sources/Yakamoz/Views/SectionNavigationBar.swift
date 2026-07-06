import SwiftUI
import YakamozCore

/// SID-2: a horizontal bar of section-title chips; tapping one selects that turn in
/// the transcript (reusing `ChatViewModel.selectTurn`, the same seam the existing
/// turn-selection UI uses). Renders nothing when the conversation has produced no
/// accepted section-title annotations yet — absence is the normal state for short
/// conversations that haven't shifted phases.
struct SectionNavigationBar: View {
    let annotations: [SectionAnnotationView]
    let onSelect: (Int) -> Void

    var body: some View {
        if !annotations.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(annotations) { annotation in
                        Button(annotation.text) {
                            onSelect(annotation.turnIndex)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            }
            .frame(height: 32)
        }
    }
}

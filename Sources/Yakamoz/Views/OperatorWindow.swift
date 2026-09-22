import SwiftData
import SwiftUI
import YakamozCore

/// A per-operator window with **Profile** and **Vault** tabs, opened with
/// `openWindow(id: OperatorWindow.id, value: agentId)`.
///
/// A window rather than a sheet so the vault's `NOTES.md` can stay open next to the
/// conversation it's used in (docs/design/interaction-paradigm.md §3.5).
struct OperatorWindow: View {
    static let id = "operator"

    let agentId: UUID?

    @Environment(\.dismissWindow) private var dismissWindow
    @Query(sort: \AgentModel.createdAt) private var agents: [AgentModel]

    private var agent: AgentModel? {
        agentId.flatMap { id in agents.first { $0.id == id } }
    }

    var body: some View {
        Group {
            if let agent {
                TabView {
                    Tab("Profile", systemImage: "person.crop.circle") {
                        OperatorProfileView(agent: agent, onDeleted: { dismissWindow() })
                    }
                    Tab("Vault", systemImage: "archivebox") {
                        AgentVaultView(agent: agent)
                    }
                }
                .navigationTitle(agent.name)
            } else {
                ContentUnavailableView(
                    "Operator Not Found",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("This operator may have been deleted.")
                )
            }
        }
        .frame(minWidth: 560, minHeight: 440)
    }
}

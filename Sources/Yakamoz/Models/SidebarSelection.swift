import Foundation

/// ATW-8: the agents-centric sidebar's selection — either an agent (routes to
/// `AgentDetailView`) or a specific timeline (routes to `ChatView`).
enum SidebarSelection: Hashable {
    case agent(UUID)
    case timeline(UUID)
}

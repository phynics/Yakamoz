import Foundation
import YakamozNetwork

/// ATW-8: the agents-centric sidebar's selection — either an agent (routes to
/// `AgentDetailView`), a specific local timeline (routes to `ChatView`), or a
/// discovered network entry (routes to the network surface).
enum SidebarSelection: Hashable {
    case agent(UUID)
    case timeline(UUID)
    case network(NetworkSidebarSelection)
}

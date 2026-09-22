import Foundation
import YakamozNetwork

/// ATW-8: the operator-centric sidebar's selection — an operator (opens its home
/// conversation via `OperatorHomeView`), a specific local conversation (`ChatView`), or a
/// discovered network entry (routes to the network surface).
enum SidebarSelection: Hashable {
    case agent(UUID)
    case timeline(UUID)
    case network(NetworkSidebarSelection)
}

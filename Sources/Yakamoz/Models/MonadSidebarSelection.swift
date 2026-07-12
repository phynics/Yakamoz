import Foundation

/// YAK-MON-4: Monad-mode sidebar's selection — either a server agent (instance or
/// template) or one of its server timelines. Deliberately a separate type from
/// `SidebarSelection` (the local-mode selection): Monad mode never mixes with local
/// Yakamoz agent/timeline ids, so keeping the types distinct makes an accidental
/// cross-mode selection a compile error rather than a runtime bug.
enum MonadSidebarSelection: Hashable {
    case agent(UUID)
    case timeline(UUID)
}

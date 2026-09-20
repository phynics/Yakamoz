import Testing
@testable import YakamozNetwork

@Suite("NetworkEntityMapping")
struct NetworkEntityMappingTests {
    @Test("An absent or unknown workspace trust level fails closed to read-only")
    func trustLevelFailsClosed() {
        #expect(NetworkWorkspaceTrustLevel(reported: nil) == .readOnly)
        #expect(NetworkWorkspaceTrustLevel(reported: "not-a-level") == .readOnly)
        #expect(NetworkWorkspaceTrustLevel(reported: "full") == .full)
        #expect(NetworkWorkspaceTrustLevel(reported: "restricted") == .restricted)
    }

    @Test("An absent workspace effective status fails closed to unavailable")
    func effectiveStatusFailsClosed() {
        #expect(NetworkWorkspaceEffectiveStatus(reported: nil) == .unavailable)
        #expect(NetworkWorkspaceEffectiveStatus(reported: "available") == .available)
    }
}

/// `YakamozRuntime` already conforms to `ChatRunning` (see `YakamozRuntime.swift`) and
/// already exposes `appHealthCheck()` matching `BackendHealthChecking`'s shape. This
/// additive conformance lets production code hand a `YakamozRuntime` straight to
/// `LocalYakamozBackend` as both its `chatRunner:` and `health:` collaborator, without
/// touching any existing `YakamozRuntime` behavior.
extension YakamozRuntime: BackendHealthChecking {
    public func backendHealthCheck() async -> AppHealthStatus {
        await appHealthCheck()
    }
}

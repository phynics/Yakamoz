import Foundation
import Logging
import Testing
@testable import YakamozCore

@Suite("YakamozLoggingBootstrap")
struct YakamozLoggingBootstrapTests {
    @Test("Bootstrap can be called without crashing")
    func bootstrapDoesNotCrash() {
        // Just verify that calling bootstrap doesn't crash
        YakamozLogging.bootstrap()
        #expect(true)
    }
}

import Foundation
import Testing
@testable import YakamozCore

@Suite("MonadInspectorTab")
struct MonadInspectorTabTests {
    @Test("Response and Tools tabs are available in Monad mode")
    func availableTabs() {
        #expect(MonadInspectorTab.response.availableInMonad)
        #expect(MonadInspectorTab.tools.availableInMonad)
    }

    @Test("Prompt, Sent, and Journal tabs are not available in Monad mode")
    func unavailableTabs() {
        #expect(!MonadInspectorTab.prompt.availableInMonad)
        #expect(!MonadInspectorTab.sent.availableInMonad)
        #expect(!MonadInspectorTab.journal.availableInMonad)
    }

    @Test("All five tabs exist")
    func allCasesCount() {
        #expect(MonadInspectorTab.allCases.count == 5)
    }

    @Test("Each tab has a non-empty title and system image")
    func titlesAndImages() {
        for tab in MonadInspectorTab.allCases {
            #expect(!tab.title.isEmpty)
            #expect(!tab.systemImage.isEmpty)
        }
    }
}

import Foundation
import Logging
import os
import Testing
@testable import YakamozCore

@Suite("YakamozLogHandler")
struct YakamozLogHandlerTests {
    // MARK: - Level Mapping Tests

    @Test("Maps .trace to OSLogType.debug")
    func mapTraceToDebug() {
        let handler = YakamozLogHandler(label: "test.logger")
        #expect(handler.osLogType(for: .trace) == .debug)
    }

    @Test("Maps .debug to OSLogType.debug")
    func mapDebugToDebug() {
        let handler = YakamozLogHandler(label: "test.logger")
        #expect(handler.osLogType(for: .debug) == .debug)
    }

    @Test("Maps .info to OSLogType.info")
    func mapInfoToInfo() {
        let handler = YakamozLogHandler(label: "test.logger")
        #expect(handler.osLogType(for: .info) == .info)
    }

    @Test("Maps .notice to OSLogType.info")
    func mapNoticeToInfo() {
        let handler = YakamozLogHandler(label: "test.logger")
        #expect(handler.osLogType(for: .notice) == .info)
    }

    @Test("Maps .warning to OSLogType.default")
    func mapWarningToDefault() {
        let handler = YakamozLogHandler(label: "test.logger")
        #expect(handler.osLogType(for: .warning) == .default)
    }

    @Test("Maps .error to OSLogType.error")
    func mapErrorToError() {
        let handler = YakamozLogHandler(label: "test.logger")
        #expect(handler.osLogType(for: .error) == .error)
    }

    @Test("Maps .critical to OSLogType.fault")
    func mapCriticalToFault() {
        let handler = YakamozLogHandler(label: "test.logger")
        #expect(handler.osLogType(for: .critical) == .fault)
    }

    // MARK: - Label Subsystem/Category Split Tests

    @Test("Splits PositronicKit label correctly")
    func splitPositronicKitLabel() {
        let handler = YakamozLogHandler(label: "com.positronickit.chat-engine")
        let (subsystem, category) = handler.splitLabel("com.positronickit.chat-engine")
        #expect(subsystem == "com.positronickit")
        #expect(category == "chat-engine")
    }

    @Test("Splits Yakamoz label correctly")
    func splitYakamozLabel() {
        let handler = YakamozLogHandler(label: "me.atkn.Yakamoz.chat")
        let (subsystem, category) = handler.splitLabel("me.atkn.Yakamoz.chat")
        #expect(subsystem == "me.atkn.Yakamoz")
        #expect(category == "chat")
    }

    @Test("Handles single-segment label")
    func splitSingleSegmentLabel() {
        let handler = YakamozLogHandler(label: "test")
        let (subsystem, category) = handler.splitLabel("test")
        #expect(subsystem == "test")
        #expect(category == "")
    }
}

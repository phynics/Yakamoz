import CoreGraphics
import Testing
@testable import YakamozCore

struct InspectorWidthClampingTests {
    @Test("inspector width clamps to minimum and detail-relative maximum")
    func clampsWidth() {
        #expect(InspectorWidthClamping.clamped(100, detailWidth: 1) == 280)
        #expect(abs(InspectorWidthClamping.clamped(1_000, detailWidth: 800) - 440) < 0.001)
        #expect(InspectorWidthClamping.clamped(360, detailWidth: 800) == 360)
    }
}

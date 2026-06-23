import Testing
import YakamozCore

@Test("Core exposes its runtime version")
func coreLoads() {
    #expect(YakamozCore.version == 1)
}

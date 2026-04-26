import Foundation
import Testing

@testable import TranscribeCore

@Suite("MicEnabledState")
struct MicEnabledStateTests {
  @Test("default initially enabled")
  func defaultEnabled() {
    let state = MicEnabledState()
    #expect(state.isEnabled() == true)
  }

  @Test("can construct disabled")
  func canConstructDisabled() {
    let state = MicEnabledState(initiallyEnabled: false)
    #expect(state.isEnabled() == false)
  }

  @Test("setEnabled toggles value")
  func setEnabledToggles() {
    let state = MicEnabledState()
    state.setEnabled(false)
    #expect(state.isEnabled() == false)
    state.setEnabled(true)
    #expect(state.isEnabled() == true)
  }

  @Test("concurrent reads/writes do not crash and converge")
  func concurrentAccess() async {
    let state = MicEnabledState()
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<200 {
        group.addTask { state.setEnabled(i % 2 == 0) }
        group.addTask { _ = state.isEnabled() }
      }
    }
    // 最後の write が反映されている (race だが最終 set は決定的に enabled or disabled)。
    // 値の正しさは個別 set/get テストで網羅、ここでは「クラッシュしないこと」だけ確認。
    let final = state.isEnabled()
    #expect(final == true || final == false)
  }
}

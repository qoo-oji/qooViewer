import Foundation
import Testing

@testable import qooViewer

/// スライダーの目盛りを置く値(Views/TickMarkSlider.swift)。
@MainActor
struct TickMarkSliderTests {
    @Test("目盛りは丸い間隔の倍数の上に置く(コメントの例のとおり)")
    func ticksSitOnRoundMultiples() {
        #expect(TickMarkSlider.tickValues(in: 0.5...30, step: 0.1) == stride(from: 2.0, through: 30, by: 2).map { $0 })
        #expect(TickMarkSlider.tickValues(in: 0...255, step: 1) == stride(from: 0.0, through: 240, by: 20).map { $0 })
    }

    @Test("極端な範囲・刻みでも落ちず、終わる(2026-09-23 の 3 回目の監査の低)")
    func extremeRangesDoNotTrapOrHang() {
        #expect(TickMarkSlider.tickValues(in: 0...1e20, step: 1).count <= 21)
        #expect(TickMarkSlider.tickValues(in: 1e18...1.0000000000000002e18, step: 50).count <= 21)
        #expect(TickMarkSlider.tickValues(in: 0...Double.infinity, step: 1).isEmpty)
        #expect(TickMarkSlider.tickValues(in: 0...10, step: .nan).count <= 21)
        #expect(TickMarkSlider.tickValues(in: 5...5, step: 1).isEmpty)
    }
}

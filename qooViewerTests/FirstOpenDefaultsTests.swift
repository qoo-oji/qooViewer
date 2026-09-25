import Foundation
import Testing

@testable import qooViewer

/// 環境設定「本を開く」の「初めて開く本」(読み方向・見開き/単ページ・表示モード)が、初めて開く本にだけ効くこと。
///
/// 見開き/単ページは 2026-09-26 まで `ViewerViewModel` で見開き固定になっていて、設定する方法が無かった。
@MainActor
struct FirstOpenDefaultsTests {
    @Test("初めて開く本は、環境設定の読み方向・見開き/単ページ・表示モードで開き、その値を本ごとに記録する")
    func aNewBookOpensWithTheDefaults() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.defaultReadingDirectionSetting = .leftToRight
        harness.preferences.defaultDisplayMode = .single
        harness.preferences.defaultScalingMode = .fitWidth
        let book = try await harness.makeBook(pageCount: 4)

        let viewer = await harness.open(book)
        #expect(viewer.readingDirection == .leftToRight)
        #expect(viewer.displayMode == .single)
        #expect(viewer.scalingMode == .fitWidth)
        let state = try #require(harness.readingState(for: book))
        #expect(state.readingDirection == .leftToRight)
        #expect(state.displayMode == .single)
        #expect(state.scalingMode == .fitWidth)
    }

    @Test("一度開いた本は、あとで既定を変えても自分の値で開く")
    func aKnownBookKeepsItsOwnSettings() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.defaultReadingDirectionSetting = .rightToLeft
        harness.preferences.defaultDisplayMode = .spread
        harness.preferences.defaultScalingMode = .fitToScreen
        let book = try await harness.makeBook(pageCount: 4)
        _ = await harness.open(book)
        harness.close()

        harness.preferences.defaultReadingDirectionSetting = .leftToRight
        harness.preferences.defaultDisplayMode = .single
        harness.preferences.defaultScalingMode = .fitWidth
        let reopened = await harness.open(try await harness.reloadBook())
        #expect(reopened.readingDirection == .rightToLeft)
        #expect(reopened.displayMode == .spread)
        #expect(reopened.scalingMode == .fitToScreen)
    }

    @Test("シークレットウインドウで初めて開く本も、同じ既定で開く(記録はしない)")
    func aPrivateWindowUsesTheDefaults() async throws {
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.defaultDisplayMode = .single
        harness.preferences.defaultScalingMode = .fitWidth
        let book = try await harness.makeBook(pageCount: 4)

        let viewer = await harness.open(book, skipsPersistence: true)
        #expect(viewer.displayMode == .single)
        #expect(viewer.scalingMode == .fitWidth)
        #expect(harness.readingState(for: book) == nil)
    }
}

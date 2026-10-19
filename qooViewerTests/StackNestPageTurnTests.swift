import Foundation
import StackNestViewerKit
import StackNestViewerKitTesting
import Testing

@testable import qooViewer

/// 応答の遅い StackNest でのページ送り(2026-10-19 の実測で見つけた待ち)。見開きの相方を 1 枚目と同時に表示として頼むこと、
/// 続けて送ったときの通過コマが取り寄せを待たないこと。速さそのものは実機で測る(docs/12「StackNest の本の実機の確かめ方」)。
@MainActor
struct StackNestPageTurnTests {
    @Test("見開きの相方も 1 枚目と同時に表示として頼む(背景の列が埋まっていても、1 枚目が届くのを待たずに取りに行く)")
    func partnerIsRequestedWithTheFirstPage() async throws {
        let fixture = try StackNestTestBook(pageCount: 30, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.defaultDisplayMode = .spread
        harness.preferences.prefetchPageCount = 0
        let book = try await FixtureBook.load(fixture.referenceURL)
        let viewer = await harness.openInWindow(book)
        #expect(viewer.displayMode == .spread)
        // 同じ StackNest への背景の取り寄せで門の背景の枠を埋める(門は接続先ごとに 1 つ。止めたサムネイル 4 件)。
        let gates = [10, 11, 12, 13, 20, 21].map { ($0, fixture.holdPage($0)) }
        defer { gates.forEach { $0.1.open() } }
        let other = PageLoader(book: book, usesThumbnailDiskCache: false)
        let thumbnails = (10..<14).map { index in Task { await other.thumbnail(at: index) } }
        let reference = try #require(book.stackNestReference)
        let shared = try StackNestSessions.shared.book(for: reference, at: book.sourceURL)
        #expect(await eventually { shared.gate.inUseCount(.background) == StackNestRequestGate.backgroundLimit })

        viewer.jump(toPageIndex: 20)
        // 1 枚目(20)の応答を止めたまま、相方(21)も届く。
        let bothArrived = await eventually(timeout: .seconds(3)) {
            let indices = fixture.pageRequestIndices
            return indices.contains(20) && indices.contains(21)
        }
        #expect(bothArrived, "相方のページを、1 枚目が届くまで頼まなかった(または背景の列で待った)")
        gates.forEach { $0.1.open() }
        for task in thumbnails { _ = await task.value }
        await viewer.settle()
        #expect(viewer.currentIndex == 20)
        #expect(viewer.currentImages.compactMap { PageColorReader.number(in: $0) } == [21, 22])
        await other.releaseAllResources()
    }

    @Test("続けて送ったとき、通過するページの取り寄せを待たない(手元にある絵だけ出して、着地のページを出す)")
    func transitFramesDoNotWaitForRemotePages() async throws {
        let fixture = try StackNestTestBook(pageCount: 30, startPage: 0)
        defer { fixture.close() }
        let harness = try ViewerHarness()
        defer { harness.close() }
        harness.preferences.defaultDisplayMode = .spread
        harness.preferences.prefetchPageCount = 0
        let viewer = await harness.openInWindow(try await FixtureBook.load(fixture.referenceURL))
        #expect(viewer.currentImages.count == 2)
        // 通過するページ(2〜5)の応答を止める。着地(6・7)は止めない。
        let gates = (2...5).map { fixture.holdPage($0) }
        defer { gates.forEach { $0.open() } }
        // キーを続けて押した形(待ち行列に 2・4・6 が積まれる)。
        viewer.advance(forward: true)
        viewer.advance(forward: true)
        viewer.advance(forward: true)
        let landed = await eventually(timeout: .seconds(3)) {
            await MainActor.run {
                viewer.currentIndex == 6 && viewer.currentImages.compactMap { PageColorReader.number(in: $0) } == [7, 8]
            }
        }
        #expect(landed, "通過するページの取り寄せを待って、着地のページが出なかった")
        gates.forEach { $0.open() }
        await viewer.settle()
        #expect(viewer.currentIndex == 6)
    }
}

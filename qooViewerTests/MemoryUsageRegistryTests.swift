import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// リソースモニタの「メモリ」の内訳(Services/MemoryUsageRegistry.swift、2026-10-11)。
///
/// 帳簿はアプリで 1 つの状態なので、**`MemoryUsageRegistry.shared` には触れない** ―― ここでは自前のインスタンスを作る
/// (アプリの中の届け出は `forCurrentProcess` を使い、テストでは nil になる)。
struct MemoryUsageRegistryTests {
    private func item(_ kind: MemoryUsageKind, _ bytes: Int, limit: Int? = nil) -> MemoryUsageItem {
        MemoryUsageItem(kind: kind, usedBytes: bytes, limitBytes: limit, count: 1)
    }

    @Test("テストの中では、アプリの中の届け出先は無い(共有の帳簿に触れない)")
    func theProcessRegistryIsAbsentUnderTests() {
        #expect(MemoryUsageRegistry.forCurrentProcess == nil)
    }

    @Test("届け出た順に持ち主ごとにまとめ、項目を足すだけの届け出は同じ持ち主の行へ足す")
    func ownersComeInRegistrationOrderWithExtrasMerged() async {
        let registry = MemoryUsageRegistry()
        let book = MemoryUsageRegistration()
        let zoom = MemoryUsageRegistration(ownerID: book.ownerID)
        let home = MemoryUsageRegistration()
        let pageImages = item(.pageImages, 10, limit: 100)
        let zoomImages = item(.zoomImages, 7)
        let thumbnails = item(.fileBrowserThumbnails, 3, limit: 50)
        book.activate(in: registry, role: .viewerBook(title: "fictional")) { [pageImages] in [pageImages] }
        home.activate(in: registry, role: .homeCaches) { [thumbnails] in [thumbnails] }
        zoom.activate(in: registry, role: nil) { [zoomImages] in [zoomImages] }

        let owners = await registry.report()
        #expect(owners.map(\.id) == [book.ownerID, home.ownerID])
        #expect(owners.first?.role == .viewerBook(title: "fictional"))
        #expect(owners.first?.items == [pageImages, zoomImages])
        #expect(owners.first?.totalBytes == 17)
        withExtendedLifetime((book, zoom, home)) {}
    }

    @Test("本体が外れたら、足すだけの届け出も出さない。end() と解放のどちらでも外れる")
    func endingOrReleasingARegistrationRemovesIt() async {
        let registry = MemoryUsageRegistry()
        let book = MemoryUsageRegistration()
        let zoom = MemoryUsageRegistration(ownerID: book.ownerID)
        book.activate(in: registry, role: .viewerBook(title: nil)) { [] }
        zoom.activate(in: registry, role: nil) { [] }
        #expect(registry.entryCount == 2)

        book.end()
        book.end()  // 何度呼んでもよい
        #expect(await registry.report().isEmpty)
        #expect(registry.entryCount == 1)

        var other: MemoryUsageRegistration? = MemoryUsageRegistration()
        other?.activate(in: registry, role: .actualSize) { [] }
        #expect(registry.entryCount == 2)
        other = nil
        #expect(registry.entryCount == 1)
        withExtendedLifetime(zoom) {}
    }

    @Test("届け出先が nil(テスト)なら何もしない")
    func activatingWithoutARegistryDoesNothing() async {
        let registration = MemoryUsageRegistration()
        registration.activate(in: nil, role: .exporting) { [] }
        registration.end()
    }

    @Test("内訳: 3 つの機能は空でも同じ順に並び、付け足しの持ち主は 0 なら出さない。見積もりは合計に足さない")
    func theBreakdownGroupsByFeature() {
        let book = MemoryUsageOwner(id: UUID(), role: .viewerBook(title: "a"), items: [item(.pageImages, 0, limit: 10)])
        let emptyCells = MemoryUsageOwner(id: UUID(), role: .pageListCells, items: [item(.cellImages, 0)])
        let cells = MemoryUsageOwner(id: UUID(), role: .smartLibraryCells, items: [item(.cellImages, 500)])
        let home = MemoryUsageOwner(id: UUID(), role: .homeCaches, items: [
            item(.fileBrowserThumbnails, 30, limit: 100), item(.collectionCovers, 20, limit: 100),
        ])
        let breakdown = MemoryUsageBreakdown(owners: [book, emptyCells, cells, home])
        #expect(breakdown.groups.map(\.feature) == [.viewer, .toolWindows, .home])
        #expect(breakdown.groups[0].owners.map(\.id) == [book.id], "本は 0 でも出す。0 の一覧は出さない")
        #expect(breakdown.groups[1].owners.isEmpty)
        #expect(breakdown.groups[2].owners.map(\.id) == [cells.id, home.id])
        #expect(breakdown.groups[2].totalBytes == 50, "一覧の見積もり(500)は足さない")
        #expect(breakdown.attributedBytes == 50)
        #expect(breakdown.bookReaderCount == 1)
    }

    @Test("内訳の無いメモリは、フットプリントから内訳の合計を引いた残り。負になるなら nil(圧縮で帳簿より小さい)")
    func theUnattributedMemoryIsWhatIsLeft() {
        let owner = MemoryUsageOwner(id: UUID(), role: .exporting, items: [item(.pageImages, 300, limit: 1000)])
        let breakdown = MemoryUsageBreakdown(owners: [owner])
        #expect(breakdown.unattributedBytes(footprint: 1000) == 700)
        #expect(breakdown.unattributedBytes(footprint: 300) == 0)
        #expect(breakdown.unattributedBytes(footprint: 299) == nil)
    }

    @Test("本を読む PageLoader の統計から 5 つの項目を作る(ディスクの上の入れ子の書庫は入れない)")
    func pageLoaderStatisticsBecomeItems() {
        var statistics = ResourceSnapshotFactory.statistics(
            pageImages: (100, 1000, ["p0", "p1"]), thumbnails: (20, 200), gridThumbnails: (3, 300))
        statistics.nestedArchives.inMemoryBytes = 7
        statistics.nestedArchives.inMemoryLimitBytes = 70
        statistics.nestedArchives.inMemoryArchiveCount = 1
        statistics.nestedArchives.temporaryBytes = 5000
        statistics.nestedArchives.decompressionBufferBytes = 11
        let items = MemoryUsageItem.items(from: statistics)
        #expect(items.map(\.kind) == [.pageImages, .thumbnails, .gridThumbnails, .nestedArchives, .sevenZipDecoder])
        #expect(items.map(\.usedBytes) == [100, 20, 3, 7, 11])
        #expect(items.map(\.limitBytes) == [1000, 200, 300, 70, nil])
        #expect(items.reduce(0) { $0 + $1.usedBytes } == 141)
    }

    @Test("CGImage の並びはビットマップの大きさで数える")
    func imagesAreCountedByTheirBitmaps() throws {
        let context = try #require(CGContext(
            data: nil, width: 10, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let usage = MemoryUsageItem.images(.zoomImages, [image, image])
        #expect(usage.usedBytes == image.bytesPerRow * image.height * 2)
        #expect(usage.count == 2)
    }

    @Test("一覧の帳簿は、前回の作り直しから抱えた量を答え、作り直しで 0 へ戻る")
    @MainActor
    func theCellBudgetReportsWhatItHoldsSinceTheLastRebuild() {
        var budget = LazyCellImageBudget(byteBudget: 100)
        budget.note(retainedBytes: 40, minimumCellCount: 1)
        #expect(budget.retainedByteCount == 40)
        #expect(budget.retainedCells == 1)
        budget.note(retainedBytes: 70, minimumCellCount: 1)
        #expect(budget.epoch == 1)
        #expect(budget.retainedByteCount == 0)
    }
}

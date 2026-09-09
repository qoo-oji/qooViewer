import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// 焼いたコレクションのタイル(Services/CollectionTileImageStore.swift)。
///
/// **保存先は必ず一時フォルダを渡すこと。** 既定は利用者の
/// `~/Library/Caches/<bundle id>/CollectionTiles/` で、テストはそこへ書いてはいけない
/// (CollectionCoverStoreTestsと同じ約束)。
struct CollectionTileImageStoreTests {
    private struct Harness {
        var covers: CollectionCoverStore
        var tiles: CollectionTileImageStore
        var directory: URL
        /// 解放されると消えるので、テストが終わるまで持っておくこと。
        var temporary: TemporaryDirectory
    }

    private func makeHarness(_ label: String) throws -> Harness {
        let temporary = try TemporaryDirectory(label)
        let covers = CollectionCoverStore(directory: temporary.file("covers"))
        let directory = temporary.file("tiles")
        return Harness(
            covers: covers,
            tiles: CollectionTileImageStore(coverStore: covers, directory: directory),
            directory: directory, temporary: temporary
        )
    }

    /// 番号を色に埋めたカバーを`numbers`のぶんだけ書き、その注文書を返す。
    private func makeRequest(
        _ harness: Harness, collectionID: UUID = UUID(),
        aspectRatio: CoverAspectRatio = .portrait, numbers: [UInt8],
        anchor: CoverCropAnchor = .center
    ) async throws -> CollectionTileImageRequest {
        var cells: [CollectionTileImageRequest.Cell] = []
        for number in numbers {
            let itemID = UUID()
            try await harness.covers.write(PageImageFactory.cgImage(number: number), for: itemID)
            cells.append(
                .init(
                    itemID: itemID, anchor: anchor,
                    coverAspect: Double(PageImageFactory.width) / Double(PageImageFactory.height)
                )
            )
        }
        return CollectionTileImageRequest(
            collectionID: collectionID, aspectRatio: aspectRatio, cells: cells
        )
    }

    /// 焼いた1枚の`index`番目のセルに、どの番号のカバーが入っているか。
    private func number(inCell index: Int, of sheet: CGImage, aspectRatio: CoverAspectRatio) -> Int? {
        let rect = CollectionTileLayout.cellRect(
            index: index, inImageOfSize: (sheet.width, sheet.height), aspectRatio: aspectRatio
        )
        guard let cell = sheet.cropping(to: rect) else { return nil }
        return PageColorReader.number(in: cell)
    }

    private func fileCount(in directory: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .count ?? 0
    }

    // MARK: - 割り付け

    @Test("セルの矩形は、隙間も重なりも無く1枚を覆う", arguments: CoverAspectRatio.allCases)
    func theCellRectsTileTheSheet(aspectRatio: CoverAspectRatio) {
        let size = CollectionTileLayout.sheetPixelSize(aspectRatio)
        var covered = 0.0
        for index in 0..<aspectRatio.tileCellCount {
            let rect = CollectionTileLayout.cellRect(
                index: index, inImageOfSize: size, aspectRatio: aspectRatio
            )
            covered += rect.width * rect.height
            // どの矩形も画像からはみ出さない(cropping(to:)がnilを返す条件)。
            #expect(rect.minX >= 0 && rect.maxX <= Double(size.width))
            #expect(rect.minY >= 0 && rect.maxY <= Double(size.height))
        }
        #expect(covered == Double(size.width * size.height))
    }

    @Test("焼く1枚の縦横比は、札の大きさに依らない定数(列数 : 行数 ÷ 比)",
          arguments: CoverAspectRatio.allCases)
    func theSheetAspectDoesNotDependOnTheTileSize(aspectRatio: CoverAspectRatio) {
        let size = CollectionTileLayout.sheetPixelSize(aspectRatio)
        let expected = Double(aspectRatio.tileColumns) / Double(aspectRatio.tileRows) * aspectRatio.value
        let actual = Double(size.width) / Double(size.height)
        // 画素への丸め(cellPixelSizeの.rounded(.up))ぶんだけずれる。
        #expect(abs(actual - expected) < 0.01)
    }

    // MARK: - 指紋

    @Test("中身が同じなら指紋も同じ")
    func theSignatureIsStableForTheSameContent() {
        let id = UUID()
        let cells = [CollectionTileImageRequest.Cell(itemID: id, anchor: .center, coverAspect: 0.6667)]
        let first = CollectionTileImageRequest(
            collectionID: UUID(), aspectRatio: .portrait, cells: cells)
        let second = CollectionTileImageRequest(
            collectionID: UUID(), aspectRatio: .portrait, cells: cells)
        // コレクションのidは指紋に入らない(入れるとファイル名で二重に持つことになる)。
        #expect(first.signature == second.signature)
    }

    @Test("並び・切り出す位置・比・冊数が変われば指紋も変わる")
    func theSignatureFollowsEverythingThatChangesThePicture() {
        let first = UUID()
        let second = UUID()
        func request(
            _ cells: [CollectionTileImageRequest.Cell], _ aspectRatio: CoverAspectRatio = .portrait
        ) -> String {
            CollectionTileImageRequest(
                collectionID: first, aspectRatio: aspectRatio, cells: cells
            ).signature
        }
        let base = [
            CollectionTileImageRequest.Cell(itemID: first, anchor: .center, coverAspect: 0.6667),
            CollectionTileImageRequest.Cell(itemID: second, anchor: .center, coverAspect: 0.6667),
        ]
        #expect(request(base) != request(base.reversed()))
        #expect(request(base) != request(Array(base.dropLast())))
        #expect(request(base) != request(base, .square))
        var moved = base
        moved[0].anchor = .start
        #expect(request(base) != request(moved))
        var restretched = base
        restretched[1].coverAspect = 1.5
        #expect(request(base) != request(restretched))
    }

    // MARK: - 合成

    @Test("焼いた1枚には、注文どおりの並びでカバーが入る")
    func theSheetHoldsTheCoversInOrder() async throws {
        let harness = try makeHarness("tiles-compose")
        let numbers: [UInt8] = [11, 22, 33, 44, 55, 66]
        let request = try await makeRequest(harness, numbers: numbers)
        let size = CollectionTileLayout.sheetPixelSize(.portrait)

        let sheet = try #require(
            await harness.tiles.image(for: request, pixelSize: max(size.width, size.height))
        )
        for (index, expected) in numbers.enumerated() {
            let read = try #require(number(inCell: index, of: sheet, aspectRatio: .portrait))
            let difference = abs(read - Int(expected))
            // JPEGの誤差(PageColorReader.matchesと同じ許容)。
            #expect(difference <= 2, "\(index)番目のセル")
        }
    }

    @Test("冊数が足りない札も焼ける(空きセルは表示側が描く)")
    func aPartlyFilledTileIsStillBaked() async throws {
        let harness = try makeHarness("tiles-partial")
        let request = try await makeRequest(harness, numbers: [7, 8])
        let size = CollectionTileLayout.sheetPixelSize(.portrait)

        let sheet = try #require(
            await harness.tiles.image(for: request, pixelSize: max(size.width, size.height))
        )
        let first = try #require(number(inCell: 0, of: sheet, aspectRatio: .portrait))
        let second = try #require(number(inCell: 1, of: sheet, aspectRatio: .portrait))
        #expect(abs(first - 7) <= 2)
        #expect(abs(second - 8) <= 2)
    }

    @Test("カバーが1枚でも読めなければ焼かない(穴の空いた絵を残さない)")
    func aMissingCoverAbortsTheWholeSheet() async throws {
        let harness = try makeHarness("tiles-missing-cover")
        let written = try await makeRequest(harness, numbers: [1, 2])
        // 3枚目だけ、カバーのファイルを書いていないitemを混ぜる。
        let request = CollectionTileImageRequest(
            collectionID: written.collectionID, aspectRatio: written.aspectRatio,
            cells: written.cells + [.init(itemID: UUID(), anchor: .center, coverAspect: 0.6667)]
        )

        #expect(await harness.tiles.image(for: request, pixelSize: 256) == nil)
        #expect(fileCount(in: harness.directory) == 0)
    }

    @Test("2回目はディスクにもメモリにも残っているので、カバーを消しても戻る")
    func theSecondReadComesFromTheCache() async throws {
        let harness = try makeHarness("tiles-cached")
        let request = try await makeRequest(harness, numbers: [3, 4])
        #expect(await harness.tiles.image(for: request, pixelSize: 256) != nil)

        // 材料(カバー)を消しても、焼いたものが残っている限り描ける。
        await harness.covers.remove(request.cells.map(\.itemID))
        #expect(await harness.tiles.image(for: request, pixelSize: 256) != nil)
        // 同期の覗き見(グリッド作り直し直後の最初のフレームが使う経路)でも返る。
        let key = CollectionTileImageStore.cacheKey(request, pixelSize: 256)
        #expect(harness.tiles.cachedImage(forKey: key) != nil)
    }

    @Test("同じ札を焼き直しても、ディスクに残るのは新しいほうから2枚まで")
    func onlyTheNewestSheetsPerCollectionSurvive() async throws {
        let harness = try makeHarness("tiles-prune")
        let collectionID = UUID()
        for numbers in [[1], [1, 2], [1, 2, 3], [1, 2, 3, 4]] {
            let request = try await makeRequest(
                harness, collectionID: collectionID, numbers: numbers.map(UInt8.init))
            #expect(await harness.tiles.image(for: request, pixelSize: 256) != nil)
        }
        #expect(fileCount(in: harness.directory) == 2)
    }

    // MARK: - 後始末

    @Test("invalidate は、そのコレクションの札をディスクからもメモリからも捨てる")
    func invalidateDropsBothCopies() async throws {
        let harness = try makeHarness("tiles-invalidate")
        let collectionID = UUID()
        let request = try await makeRequest(harness, collectionID: collectionID, numbers: [5, 6])
        #expect(await harness.tiles.image(for: request, pixelSize: 256) != nil)

        await harness.tiles.invalidate(collectionIDs: [collectionID])

        let key = CollectionTileImageStore.cacheKey(request, pixelSize: 256)
        #expect(harness.tiles.cachedImage(forKey: key) == nil)
        #expect(fileCount(in: harness.directory) == 0)
        // 材料が残っているので、次に求められたときは焼き直せる。
        #expect(await harness.tiles.image(for: request, pixelSize: 256) != nil)
    }

    @Test("sweepOrphans は、行の残っていないコレクションの札だけを消す")
    func sweepOrphansKeepsOnlyTheLivingCollections() async throws {
        let harness = try makeHarness("tiles-sweep")
        let kept = UUID()
        let orphan = UUID()
        for collectionID in [kept, orphan] {
            let request = try await makeRequest(harness, collectionID: collectionID, numbers: [9])
            #expect(await harness.tiles.image(for: request, pixelSize: 256) != nil)
        }
        // このアプリが書いたものではないファイルには触らない(CollectionCoverStoreと同じ)。
        let foreign = harness.directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: foreign)

        await harness.tiles.sweepOrphans(keeping: [kept])

        let names = try FileManager.default.contentsOfDirectory(
            at: harness.directory, includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        #expect(names.contains { $0.hasPrefix(kept.uuidString) })
        #expect(!names.contains { $0.hasPrefix(orphan.uuidString) })
        #expect(names.contains("notes.txt"))
    }

    // MARK: - 復号サイズの見積もり

    @Test("切って捨てるぶんを見込んだ復号サイズ")
    func theDecodeSizeAccountsForTheCrop() {
        let target = CoverAspectRatio.portrait.value
        // 比がぴったり合っていれば、欲しい幅から高さぶんだけ見込む(長辺 = 幅 ÷ 比)。
        #expect(
            CoverImageResolver.decodePixelSize(
                croppedWidth: 100, targetAspect: target, imageAspect: target) == 150
        )
        // 横長の画像は左右を切るので、切った後に100pxが残るよう大きめに求める。
        #expect(
            CoverImageResolver.decodePixelSize(
                croppedWidth: 100, targetAspect: target, imageAspect: 1.5) > 150
        )
        // まだ比が分からない(0)ときは、枠の比とみなす。
        #expect(
            CoverImageResolver.decodePixelSize(
                croppedWidth: 100, targetAspect: target, imageAspect: 0) == 150
        )
    }
}

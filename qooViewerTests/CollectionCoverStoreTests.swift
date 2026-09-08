import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// コレクションのカバー画像の保管庫(Services/CollectionCoverStore.swift)。
///
/// **保存先は必ず一時フォルダを渡すこと。** 既定は利用者の
/// `~/Library/Application Support/<bundle id>/CollectionCovers/` で、テストはそこへ書いてはいけない。
struct CollectionCoverStoreTests {
    private func makeStore(_ label: String) throws -> (CollectionCoverStore, TemporaryDirectory) {
        let temporary = try TemporaryDirectory(label)
        return (CollectionCoverStore(directory: temporary.file("covers")), temporary)
    }

    @Test("書いたカバーは読み戻せて、消せる")
    func aCoverCanBeWrittenReadBackAndRemoved() async throws {
        let (store, temporary) = try makeStore("covers-roundtrip")
        _ = temporary
        let itemID = UUID()
        try await store.write(PageImageFactory.cgImage(number: 7), for: itemID)

        let image = try #require(await store.image(for: itemID))
        #expect(image.width == PageImageFactory.width)
        #expect(image.height == PageImageFactory.height)

        await store.remove([itemID])
        #expect(await store.image(for: itemID) == nil)
    }

    @Test("まだ書いていないカバーは nil(ファイルが無いだけで失敗にはしない)")
    func amissingCoverReadsAsNil() async throws {
        let (store, temporary) = try makeStore("covers-missing")
        _ = temporary
        #expect(await store.image(for: UUID()) == nil)
    }

    @Test("sweepOrphans は、行が残っていないカバーだけを消す")
    func sweepOrphansKeepsOnlyTheLivingItems() async throws {
        let (store, temporary) = try makeStore("covers-sweep")
        let kept = UUID()
        let orphan = UUID()
        try await store.write(PageImageFactory.cgImage(number: 1), for: kept)
        try await store.write(PageImageFactory.cgImage(number: 2), for: orphan)
        // このアプリが書いたものではないファイルには触らない。
        let foreign = temporary.file("covers/notes.txt")
        try Data("hello".utf8).write(to: foreign)

        await store.sweepOrphans(keeping: [kept])

        #expect(await store.image(for: kept) != nil)
        #expect(await store.image(for: orphan) == nil)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test("removeAll はフォルダごと消す")
    func removeAllClearsTheDirectory() async throws {
        let (store, temporary) = try makeStore("covers-remove-all")
        _ = temporary
        let itemID = UUID()
        try await store.write(PageImageFactory.cgImage(number: 1), for: itemID)
        await store.removeAll()
        #expect(FileManager.default.fileExists(atPath: store.directory.path) == false)
    }
}

import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// **ディスク上の使い捨てストア**で、「保存 → 閉じる → 開き直す」と「前のバージョンのストアからの
/// 移行」を通して確かめる(2026-09-13。DisposableStoreの型コメント)。
///
/// 2026-09-11にコレクション表紙の3列が消えた事故の後、原因を切り分けるために手作業でやった
/// 確認(1.54時代のストアの写しを開いて移行し、閉じて開き直す)を、そのまま自動にしたもの。
/// メモリ内のストア(InMemoryLibrary)のテストは「開き直したら何が残るか」を一度も通らない。
///
/// **足した列は、ここで開き直しを通すこと。** 新しい属性を足したら、下の
/// `layoutColumnsSurviveReopening`のように、書く → 閉じる → 開き直して読む、を1本足す。
@MainActor
struct StorePersistenceTests {
    @Test("1.54のスキーマの写しは、1.54時代の実物のストアと同じ指紋を持つ(写し間違いが無い)")
    func snapshotMatchesTheReleasedSchema() {
        let hashes = StoreSchemaGuard.currentHashes(for: SchemaSnapshot_1_54.types)
        #expect(StoreSchemaGuard.fingerprint(of: hashes) == StoreSchemaGuardTests.fingerprint1_54)
    }

    @Test("コレクション表紙と切り出し位置の列は、開き直しても残る")
    func layoutColumnsSurviveReopening() async throws {
        let store = try DisposableStore("layout-columns")
        let sources = CollectionCoverSourceStore(directory: store.file("CollectionCoverSources"))
        let imageData = PageImageFactory.jpeg(number: 7)
        var storedImageName: String?
        do {
            let container = try store.openCurrent()
            let layouts = LayoutStore(modelContext: container.mainContext, coverSourceStore: sources)
            layouts.setShelfCoverPageKey(
                forBookID: "/books/page", sourceURL: nil, pageKey: "003.jpg", displayName: "003.jpg"
            )
            // zipの読み込みと同じ入口(検査に通れば元のバイトのまま保存する)。
            try await layouts.setShelfCoverImage(forBookID: "/books/image", sourceURL: nil, data: imageData)
            layouts.setCoverCropAnchor(forBookID: "/books/image", sourceURL: nil, anchor: .end)
            storedImageName = layouts.shelfCoverImageFileName(forBookID: "/books/image")
        }
        let name = try #require(storedImageName)

        let container = try store.openCurrent()
        let layouts = LayoutStore(modelContext: container.mainContext, coverSourceStore: sources)
        #expect(layouts.shelfCoverPageKey(forBookID: "/books/page") == "003.jpg")
        #expect(layouts.shelfCoverImageFileName(forBookID: "/books/image") == name)
        #expect(layouts.bookLayoutSettings(forBookID: "/books/image")?.coverCropAnchor == .end)
        // 書き出しの一覧(ユーザー報告の画面)にも、開き直した後で出る。
        #expect(layouts.shelfCoverArchiveEntries().map(\.bookID) == ["/books/image"])
    }

    @Test("1.54のストアを開いて表紙の分離を移行し、閉じて開き直しても結果が残る")
    func upgradeFrom1_54KeepsTheMigratedCovers() throws {
        let store = try DisposableStore("upgrade-1.54")
        // 1.54が書いたストア: 外部ファイルを指定した本と、本の中のページを指定した本、
        // それぞれがコレクションに入っている。
        do {
            let container = try store.open(SchemaSnapshot_1_54.types)
            let context = container.mainContext
            let external = SchemaSnapshot_1_54.BookLayoutSettings(bookID: "/books/external")
            external.externalCoverBookmarkData = Data([1, 2, 3])
            external.externalCoverFileName = "cover.webp"
            let page = SchemaSnapshot_1_54.BookLayoutSettings(bookID: "/books/page")
            page.coverPageKey = "002.jpg"
            page.coverPageDisplayName = "002.jpg"
            let library = SchemaSnapshot_1_54.BookLibrary(name: "Shelf")
            let collection = SchemaSnapshot_1_54.BookCollection(name: "Books", library: library)
            context.insert(external)
            context.insert(page)
            context.insert(library)
            context.insert(collection)
            context.insert(SchemaSnapshot_1_54.CollectionItem(bookID: "/books/external", collection: collection))
            try context.save()
        }
        // 1.55以降で開く(ここで軽量マイグレーションが走る)。移行の本体をアプリと同じ関数で。
        do {
            let container = try store.openCurrent()
            let layouts = LayoutStore(
                modelContext: container.mainContext,
                coverSourceStore: CollectionCoverSourceStore(directory: store.file("CollectionCoverSources"))
            )
            let result = layouts.migrateCoverSeparation { _ in "migrated.jpg" }
            #expect(result.images == 1)
            #expect(result.pages == 1)
        }
        // 開き直す。
        let container = try store.openCurrent()
        let rows = try container.mainContext.fetch(FetchDescriptor<BookLayoutSettings>())
        let external = try #require(rows.first { $0.bookID == "/books/external" })
        let page = try #require(rows.first { $0.bookID == "/books/page" })
        #expect(external.shelfCoverImageFileName == "migrated.jpg")
        #expect(external.externalCoverBookmarkData == nil)
        #expect(page.shelfCoverPageKey == "002.jpg")
        #expect(page.coverPageKey == "002.jpg")
        // 移行と無関係なデータ(コレクション)も残っている。
        let items = try container.mainContext.fetch(FetchDescriptor<CollectionItem>())
        #expect(items.map(\.bookID) == ["/books/external"])
        #expect(items.first?.collection?.library?.name == "Shelf")
    }
}

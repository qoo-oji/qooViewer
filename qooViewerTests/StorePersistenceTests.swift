import Foundation
import SwiftData
import QooMetaKit
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

    @Test("メタデータの qooMeta の欄(著者の並び・ジャンルなど)は、開き直しても残る")
    func metadataColumnsSurviveReopening() throws {
        let store = try DisposableStore("metadata-columns")
        let values = BookMetadataValues(title: "題名", authors: ["著者1", "著者2", "著者3"], genre: "ジャンル",
                                        event: "催し", source: "原作", info: "付記", series: "題名",
                                        volume: "総集編1", volumeSort: 101)
        do {
            let container = try store.openCurrent()
            let metadata = BookMetadataStore(modelContext: container.mainContext)
            metadata.upsert(bookID: "/books/meta", values: values)
        }
        let container = try store.openCurrent()
        let metadata = BookMetadataStore(modelContext: container.mainContext)
        let row = try #require(metadata.metadata(forBookID: "/books/meta"))
        #expect(row.values == values)
        // 先頭の著者は従来の列にも入っている(先頭だけを読む書き出し・古い版のため)。
        #expect(row.author == "著者1")
    }

    @Test("読書位置の「最後のページが写っていた」は、開き直しても残る")
    func readingStateLastPageSurvivesReopening() throws {
        let store = try DisposableStore("reading-last-page")
        do {
            let container = try store.openCurrent()
            let state = BookReadingState(bookID: "/books/finished", lastPageIndex: 8)
            state.isAtLastPage = true
            container.mainContext.insert(state)
            container.mainContext.insert(BookReadingState(bookID: "/books/reading", lastPageIndex: 2))
            try container.mainContext.save()
        }
        let container = try store.openCurrent()
        let states = try container.mainContext.fetch(FetchDescriptor<BookReadingState>())
        #expect(Dictionary(uniqueKeysWithValues: states.map { ($0.bookID, $0.isAtLastPage) })
            == ["/books/finished": true, "/books/reading": false])
    }

    @Test("1.54のストアのメタデータは、欄を足した後も同じ値で読め、足した欄は空")
    func metadataFrom1_54KeepsItsValues() throws {
        let store = try DisposableStore("metadata-1.54")
        do {
            let container = try store.open(SchemaSnapshot_1_54.types)
            let old = SchemaSnapshot_1_54.BookMetadata(bookID: "/books/old")
            old.author = "著者"
            old.title = "題名"
            old.series = "シリーズ"
            old.seriesIndex = "3"
            container.mainContext.insert(old)
            try container.mainContext.save()
        }
        let container = try store.openCurrent()
        let metadata = BookMetadataStore(modelContext: container.mainContext)
        let row = try #require(metadata.metadata(forBookID: "/books/old"))
        #expect(row.values == BookMetadataValues(title: "題名", authors: ["著者"], series: "シリーズ", volume: "3"))
        // それまでの行はどれも利用者が登録したもの。ロックした行として入る(2026-09-22)。
        #expect(row.isLocked)
        #expect(!row.didImportSourceMetadata)
    }

    @Test("メタデータのロック・直した欄・ルールセット・取り込み済みの印は、開き直しても残る")
    func metadataLockAndEditsSurviveReopening() throws {
        let store = try DisposableStore("metadata-lock")
        let edits = Confirmation.series(name: "直したシリーズ", volume: "2", fields: ConfirmedFields([.title: ["直した題"]]))
        do {
            let container = try store.openCurrent()
            let metadata = BookMetadataStore(modelContext: container.mainContext)
            metadata.upsertAll([
                .init(bookID: "/books/unlocked", values: BookMetadataValues(title: "直した題"),
                      state: BookMetadataRowState(isLocked: false, edits: edits, ruleSet: "doujinshi")),
                .init(bookID: "/books/locked", values: BookMetadataValues(title: "ロックした題"), state: .locked),
            ])
            metadata.metadata(forBookID: "/books/unlocked")?.didImportSourceMetadata = true
            try container.mainContext.save()
        }
        let container = try store.openCurrent()
        let metadata = BookMetadataStore(modelContext: container.mainContext)
        let unlocked = try #require(metadata.metadata(forBookID: "/books/unlocked"))
        #expect(!unlocked.isLocked)
        #expect(unlocked.edits == edits)
        #expect(unlocked.ruleSet == "doujinshi")
        #expect(unlocked.didImportSourceMetadata)
        #expect(metadata.metadata(forBookID: "/books/locked")?.isLocked == true)
    }
}

import Foundation
import Testing

@testable import qooViewer

/// メタデータの編集ウインドウの持ちもの(`MetadataEditorModel`)のうち、窓を開いた後の実在の確かめ(2026-10-04 の監査 MD-3 と、
/// そのレビューの R4-3・R4-4)。アプリの中の変更の知らせはテスト専用の箱(`FileSystemChangeCenter`)から、規則の窓への名前の置き場も
/// 専用のもの(`MetadataRulesPicked`)を渡す ―― 共有の状態に触れない。ストアはテスト専用のライブラリ(InMemoryLibrary)の上。
///
/// 本の名前はすべて架空(docs/02「個人情報の流出防止」)。
@MainActor
struct MetadataEditorModelTests {
    private func makeModel(_ library: InMemoryLibrary, books: [String], center: FileSystemChangeCenter,
                           access: FolderAccessStore) -> MetadataEditorModel {
        let generator = library.makeMetadataGenerator(books: books)
        generator.start()
        let relocator = BookRecordRelocator(
            favoritesStore: library.favorites, bookmarkStore: library.bookmarks, layoutStore: library.layouts,
            metadataStore: library.metadata, collectionStore: library.collections, modelContext: library.context
        )
        return MetadataEditorModel(
            metadataStore: library.metadata, rulesStore: library.metadataRules,
            stores: .init(favoritesStore: library.favorites, collectionStore: library.collections, bookmarkStore: library.bookmarks,
                          layoutStore: library.layouts, metadataStore: library.metadata, folderAccess: access,
                          generator: generator, modelContext: library.context),
            preferences: library.preferences, relocator: relocator, fileSystemChanges: center,
            rulesPicked: MetadataRulesPicked(), resolveURL: { _ in nil })
    }

    /// 本(中身は何でもよい)を作り、ロックした行を場所の手がかり(ブックマーク)つきで登録する。
    private func registerBook(_ url: URL, in library: InMemoryLibrary) throws {
        try Data("a".utf8).write(to: url)
        library.metadata.upsertAll([BookMetadataStore.BatchEntry(
            bookID: url.path, values: BookMetadataValues(title: "架空の題"), sourceURL: url, state: .locked)])
        #expect(library.metadata.metadata(forBookID: url.path)?.bookmarkData != nil)
    }

    @Test("アプリの中の変更が契機の確かめは、保存データを付け替えず、その変更で移った本を灰色にしない。消えた本は灰色にする(R4-3)")
    func partialChecksAfterAnInAppChangeDoNotRelocate() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let temporary = try TemporaryDirectory("editor-model-partial")
        let suite = PreferencesSuite(label: "editor-model-partial")
        let book = temporary.file("[架空工房] 月の庭 1.zip")
        let other = temporary.file("[架空工房] 月の庭 2.zip")
        try registerBook(book, in: library)
        try registerBook(other, in: library)
        // 消えた本を「無い」と言い切れるのは、許可したフォルダの中だけ(BookExistenceProbe)。
        let access = FolderAccessStore(defaults: suite.defaults)
        #expect(access.add(url: temporary.url))
        let center = FileSystemChangeCenter()
        let model = makeModel(library, books: [book.path, other.path], center: center, access: access)
        defer { model.close() }
        await model.open()
        await model.waitForExistenceChecks()
        let workspace = try #require(model.workspace)
        #expect(workspace.row(book.path)?.isMissing == false)

        // アプリの中で名前を変えた(付け替えは AppStores の役 ―― このテストでは誰も付け替えない)。
        let renamed = temporary.file("[架空工房] 月の庭 01.zip")
        try FileManager.default.moveItem(at: book, to: renamed)
        center.report(FileSystemChange(relocations: [.init(from: book, to: renamed)]))
        center.flush()
        await model.waitForExistenceChecks()

        // 以前はこの確かめが、ブックマークの指す先へ「アプリの外での移動」(同時の写し)として改めて付け替えた ―― 調べている間に
        // 次のアプリの中の操作(⌘Z で戻すなど)の付け替えが先に並ぶと、古い写しが後から当たった。
        #expect(library.metadata.metadata(forBookID: book.path) != nil, "アプリの中の変更の確かめが保存データを付け替えた")
        #expect(library.metadata.metadata(forBookID: renamed.path) == nil)
        #expect(workspace.row(book.path)?.isMissing == false, "この変更で移った本を灰色にした(移った先の行まで灰色で運ばれる)")

        // アプリの中で消した本は、今までどおり灰色になる。
        try FileManager.default.removeItem(at: other)
        center.report(FileSystemChange(removed: [other]))
        center.flush()
        await model.waitForExistenceChecks()
        #expect(workspace.row(other.path)?.isMissing == true)
    }

    @Test("閉じたら、走っている実在の確かめはすべて止まる ―― 一部の確かめが全冊の確かめを待っていても(R4-4)")
    func closingCancelsEveryExistenceCheck() async throws {
        let library = try InMemoryLibrary()
        defer { library.close() }
        let temporary = try TemporaryDirectory("editor-model-close")
        let suite = PreferencesSuite(label: "editor-model-close")
        let book = temporary.file("[架空工房] 月の庭 1.zip")
        try registerBook(book, in: library)
        // 窓を開く前に、アプリの外で名前を変えた(全冊の確かめが見つけて付け替える本)。
        let renamed = temporary.file("[架空工房] 月の庭 01.zip")
        try FileManager.default.moveItem(at: book, to: renamed)
        let center = FileSystemChangeCenter()
        let model = makeModel(library, books: [book.path], center: center, access: FolderAccessStore(defaults: suite.defaults))

        // 開くと全冊の確かめが並ぶ(まだ走っていない)。続けてアプリの中の変更で一部の確かめが、その後ろに並ぶ。
        await model.open()
        center.report(FileSystemChange(created: [temporary.file("[架空工房] 月の庭 1.zip")]))
        center.flush()
        let running = model.runningExistenceChecks
        #expect(running.count == 2)
        model.close()
        for task in running { await task.value }

        // 以前は閉じたときに最後の 1 つ(一部の確かめ)だけを取り消し、全冊の確かめは閉じた後も付け替えまで進んだ。
        #expect(library.metadata.metadata(forBookID: book.path) != nil, "閉じた後も全冊の確かめが付け替えた")
        #expect(library.metadata.metadata(forBookID: renamed.path) == nil)
    }
}

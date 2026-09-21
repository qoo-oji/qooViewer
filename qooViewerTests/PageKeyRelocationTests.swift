import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// フォルダの本のページの鍵(絶対パス)の付け替え(Services/BookRelocation.swift の `PageKeyRelocation`)。
/// 2026-09-21 まで付け替えていたのは `bookID` だけで、フォルダの本を移すとページ単位の指定・表紙の指定・ブックマークの鍵が外れた。
@MainActor
struct PageKeyRelocationTests {
    // MARK: - 鍵の計算

    @Test("本の配下の絶対パスの鍵だけを付け替える。本の中で閉じた鍵(書庫・PDF)と、よその鍵は変えない")
    func relocatesOnlyKeysUnderTheBook() {
        let old = "/Volumes/X/shelf/book"
        let new = "/Volumes/X/moved/book2"
        #expect(PageKeyRelocation.relocated("\(old)/ch1/001.png", fromBookID: old, toBookID: new) == "\(new)/ch1/001.png")
        #expect(PageKeyRelocation.relocated("\(old)/inner.zip/001.png", fromBookID: old, toBookID: new) == "\(new)/inner.zip/001.png")
        #expect(PageKeyRelocation.relocated("ch1/001.png", fromBookID: "/Volumes/X/a.zip", toBookID: "/Volumes/X/b.zip") == nil)
        #expect(PageKeyRelocation.relocated("00000003", fromBookID: "/Volumes/X/a.pdf", toBookID: "/Volumes/X/b.pdf") == nil)
        #expect(PageKeyRelocation.relocated("\(old)-other/001.png", fromBookID: old, toBookID: new) == nil, "名前の頭が同じだけの別のフォルダ")
        #expect(PageKeyRelocation.relocated("\(old)/001.png", fromBookID: old, toBookID: old) == nil)
    }

    @Test("付け替え漏れの鍵は、昔のパスの候補がちょうど 1 つのときだけ直す")
    func repairsStaleKeysOnlyWhenUnambiguous() {
        let book = "/Volumes/X/new/book"
        let pages = ["\(book)/001.png", "\(book)/ch1/001.png", "\(book)/ch1/002.png"]
        // 昔のパスは /Volumes/X/old/book。もう無いページの鍵は直さず、いまの鍵は触らない。
        let repairs = PageKeyRelocation.repairs(
            forStaleKeys: ["/Volumes/X/old/book/ch1/002.png", "/Volumes/X/old/book/gone.png", "\(book)/001.png"],
            bookID: book, currentPageKeys: pages
        )
        #expect(repairs == ["/Volumes/X/old/book/ch1/002.png": "\(book)/ch1/002.png"])

        // 昔のフォルダ名がサブフォルダと同じ名前で、同じ名前の画像がある: 2 通りに読めるので直さない。
        #expect(PageKeyRelocation.repairs(
            forStaleKeys: ["/Volumes/X/ch1/001.png"], bookID: book, currentPageKeys: pages
        ).isEmpty)
        // もう 1 つの鍵が候補を 1 つに絞れば直す。
        #expect(PageKeyRelocation.repairs(
            forStaleKeys: ["/Volumes/X/ch1/001.png", "/Volumes/X/ch1/ch1/002.png"], bookID: book, currentPageKeys: pages
        ) == ["/Volumes/X/ch1/001.png": "\(book)/001.png", "/Volumes/X/ch1/ch1/002.png": "\(book)/ch1/002.png"])
        // 書庫の本(鍵が本の中で閉じている)では何もしない。
        #expect(PageKeyRelocation.repairs(
            forStaleKeys: ["001.png"], bookID: "/Volumes/X/a.zip", currentPageKeys: ["001.png", "002.png"]
        ).isEmpty)
    }

    // MARK: - ストア

    private func makeBook(at url: URL) throws {
        try FixtureFolder.make(at: url, pages: [.init("001.png", number: 1), .init("002.png", number: 2), .init("003.png", number: 3)])
    }

    /// フォルダの本に、鍵で持つ保存データを一式付ける。
    private func addKeyedRecords(for book: MangaBook, in library: InMemoryLibrary) throws {
        let second = book.pages[1].sortKey
        let third = book.pages[2].sortKey
        library.layouts.setPageLayoutState(for: book, pageKey: second, state: .single)
        library.layouts.setCoverPageKey(forBookID: book.id, sourceURL: book.sourceURL, pageKey: third, displayName: "003.png")
        library.layouts.setShelfCoverPageKey(forBookID: book.id, sourceURL: book.sourceURL, pageKey: second, displayName: "002.png")
        #expect(library.bookmarks.addBookmark(
            bookID: book.id, pageIndex: 2, pageKey: third, name: "p3", fileNodeIdentifier: FileNodeIdentifier.current(for: book.sourceURL)
        ))
        let state = BookReadingState(bookID: book.id)
        state.lastPageKey = second
        library.context.insert(state)
        try library.context.save()
    }

    private func expectKeys(in library: InMemoryLibrary, bookID: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let settings = try #require(library.layouts.bookLayoutSettings(forBookID: bookID), sourceLocation: sourceLocation)
        #expect(settings.coverPageKey == "\(bookID)/003.png", sourceLocation: sourceLocation)
        #expect(settings.shelfCoverPageKey == "\(bookID)/002.png", sourceLocation: sourceLocation)
        let overrides = library.layouts.pageOverrides(forBookID: bookID)
        #expect(overrides.map(\.pageKey) == ["\(bookID)/002.png"], sourceLocation: sourceLocation)
        // `compositeKey` は見ない: NUL 区切りの文字列は、保存して読み直すと NUL の手前で切れて戻ってくる(実測 2026-09-21。ストアの都合)。
        // もともとデバッグ表示用で、どこからも読まれない(PageLayoutOverride.compositeKey のコメント)。引くのは下の bookID + pageKey。
        #expect(library.layouts.pageOverride(forBookID: bookID, pageKey: "\(bookID)/002.png")?.state == .single, sourceLocation: sourceLocation)
        #expect(library.bookmarks.bookmarks(forBookID: bookID).map(\.pageKey) == ["\(bookID)/003.png"], sourceLocation: sourceLocation)
    }

    @Test("アプリが移したフォルダの本は、ページ単位の指定・表紙の指定・ブックマーク・読書位置の鍵も新しいパスになる。取り消せば戻る")
    func relocationRewritesPageKeysOfFolderBooks() async throws {
        let library = try InMemoryLibrary(label: "pagekey-relocate")
        defer { library.close() }
        let temporary = try TemporaryDirectory("pagekey-relocate")
        let original = temporary.file("book-a")
        try makeBook(at: original)
        let book = try await FixtureBook.load(original)
        try addKeyedRecords(for: book, in: library)
        try expectKeys(in: library, bookID: original.path)

        let relocator = BookRecordRelocator(
            favoritesStore: library.favorites, bookmarkStore: library.bookmarks, layoutStore: library.layouts,
            metadataStore: library.metadata, collectionStore: library.collections, modelContext: library.context
        )
        let moved = temporary.file("book-b")
        try FileManager.default.moveItem(at: original, to: moved)
        await relocator.apply(FileSystemChange(relocations: [.init(from: original, to: moved)])).value
        try expectKeys(in: library, bookID: moved.path)
        let states = try library.context.fetch(FetchDescriptor<BookReadingState>())
        #expect(states.map(\.lastPageKey) == ["\(moved.path)/002.png"])

        try FileManager.default.moveItem(at: moved, to: original)
        await relocator.apply(FileSystemChange(relocations: [.init(from: moved, to: original)])).value
        try expectKeys(in: library, bookID: original.path)
    }

    @Test("Finder で移したフォルダの本は、開いたときの追従で鍵も新しいパスになる")
    func reconcileRewritesPageKeysOfFolderBooks() async throws {
        let library = try InMemoryLibrary(label: "pagekey-reconcile")
        defer { library.close() }
        let temporary = try TemporaryDirectory("pagekey-reconcile")
        let original = temporary.file("book-a")
        try makeBook(at: original)
        try addKeyedRecords(for: try await FixtureBook.load(original), in: library)

        let moved = temporary.file("book-b")
        try FileManager.default.moveItem(at: original, to: moved)
        let reopened = try await FixtureBook.load(moved)
        library.layouts.reconcileBookIDIfMoved(book: reopened)
        library.bookmarks.reconcileBookIDIfMoved(book: reopened)
        try expectKeys(in: library, bookID: moved.path)
    }

    @Test("以前の版で付け替え漏れになった鍵は、本を開いたときに直る")
    func staleKeysAreRepairedOnOpen() async throws {
        let library = try InMemoryLibrary(label: "pagekey-repair")
        defer { library.close() }
        let temporary = try TemporaryDirectory("pagekey-repair")
        let folder = temporary.file("book-now")
        try makeBook(at: folder)
        let book = try await FixtureBook.load(folder)
        // 以前の版の結果を作る: bookID は新しいパス、鍵は昔のパスのまま。
        let oldRoot = temporary.file("book-before").path
        library.layouts.setPageLayoutState(for: book, pageKey: "\(oldRoot)/002.png", state: .single)
        library.layouts.setCoverPageKey(forBookID: book.id, sourceURL: folder, pageKey: "\(oldRoot)/003.png", displayName: "003.png")
        library.layouts.setShelfCoverPageKey(forBookID: book.id, sourceURL: folder, pageKey: "\(oldRoot)/002.png", displayName: "002.png")
        #expect(library.bookmarks.addBookmark(bookID: book.id, pageIndex: 2, pageKey: "\(oldRoot)/003.png", name: "p3"))

        let keys = book.pages.map(\.sortKey)
        library.layouts.repairStalePageKeys(forBookID: book.id, currentPageKeys: keys)
        library.bookmarks.repairStalePageKeys(forBookID: book.id, currentPageKeys: keys)
        try expectKeys(in: library, bookID: book.id)
    }
}

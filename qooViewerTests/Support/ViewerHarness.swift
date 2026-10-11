import Foundation
import SwiftData

@testable import qooViewer

/// テスト 1 つぶんのビューア一式 ―― 作業フォルダ・メモリ内のライブラリ・その場限りの環境設定。
///
/// `ViewerViewModel` は本を開く経路そのもので、**実物のアプリと共有するもの**へ手が届く:
/// SwiftData の保存先(→ `InMemoryLibrary`)、`UserDefaults.standard`(→ `PreferencesSuite`)、
/// サムネイルとページ寸法のディスクキャッシュ(→ 既定は `usesDiskCaches: false`。キャッシュの経路を通すテストは
/// `open(_:usesDiskCaches: true)` で、作業フォルダの中の `diskCaches` を使う)、そして
/// 「いま開いている本」の静的な登録簿(→ `close()` で必ず外す)。この 4 つを塞いだ入口。
///
/// 起動時に投げられる Task は `ViewerViewModel.settle()` で待ち合わせる。**時間で待たないこと**
/// ―― 並行して走るテストが増えると壊れる(段階 2 の実測。docs/13)。
@MainActor
final class ViewerHarness {
    let temporary: TemporaryDirectory
    let library: InMemoryLibrary
    let preferencesSuite: PreferencesSuite
    let preferences: AppPreferences
    private var openViewers: [ViewerViewModel] = []
    /// 作業フォルダの中のディスクキャッシュ(BookDiskCaches)。`open(_:usesDiskCaches: true)` と `loadBookCachingPageList` が使う。
    private(set) lazy var diskCaches = BookDiskCaches(directory: temporary.file("caches"))

    init(label: String = "viewer") throws {
        temporary = try TemporaryDirectory(label)
        library = try InMemoryLibrary(label: label)
        preferencesSuite = PreferencesSuite(label: label)
        preferences = preferencesSuite.makePreferences()
    }

    // MARK: - 本

    /// 画像を並べたフォルダを作り、`BookLoader` で本として開く(`cachesPageList: false`)。
    func makeBook(named name: String = "book", pages: [FixtureFolder.Page]) async throws -> MangaBook {
        let directory = temporary.file(name)
        try FixtureFolder.make(at: directory, pages: pages)
        return try await FixtureBook.load(directory)
    }

    /// 縦長のページが `pageCount` 枚並んだ本。ページ画像の R = ページ番号(`PageColorReader`)。
    func makeBook(named name: String = "book", pageCount: Int) async throws -> MangaBook {
        try await makeBook(
            named: name,
            pages: (1...pageCount).map {
                FixtureFolder.Page(String(format: "p%02d.png", $0), number: UInt8($0))
            }
        )
    }

    /// 本を、ページ一覧を `diskCaches` へ書き戻す読み込み(`cachesPageList: true`)で開き、書き終えるまで待つ。
    /// ページ寸法・「取り込むものが無かった」記録は、この読み込みが作った行にだけ書き足される(BookPageListCache)。
    func loadBookCachingPageList(_ url: URL) async throws -> MangaBook {
        let stored = OneShotSignal()
        let book = try await BookLoader.load(
            from: url, cachesPageList: true, caches: diskCaches, onPageListStored: { stored.fire() }
        )
        _ = await stored.wait()
        return book
    }

    /// 同じフォルダを開き直す(差し替え検知のテストで、中身を変えてから読み直すために使う)。
    func reloadBook(named name: String = "book") async throws -> MangaBook {
        try await FixtureBook.load(temporary.file(name))
    }

    // MARK: - ビューア

    /// ビューアを開き、起動時の Task が落ち着くまで待つ。
    func open(
        _ book: MangaBook, skipsPersistence: Bool = false, usesDiskCaches: Bool = false,
        initialPageID: String? = nil, initialEdge: InitialPageEdge? = nil
    ) async -> ViewerViewModel {
        let viewer = ViewerViewModel(
            book: book, modelContext: library.context, preferences: preferences,
            layoutStore: library.layouts, metadataStore: library.metadata,
            skipsPersistence: skipsPersistence,
            // 実物のアプリと共有するディスクキャッシュ(サムネイル・ページ寸法)には触れない。
            // DB(メモリ内のコンテナ)へは書く ―― この組み合わせを表すための引数。キャッシュを使うときも作業フォルダのもの。
            usesDiskCaches: usesDiskCaches, diskCaches: diskCaches,
            initialPageID: initialPageID, initialEdge: initialEdge
        )
        openViewers.append(viewer)
        await viewer.settle()
        return viewer
    }

    /// 開いたビューアをすべて閉じる。**必ず呼ぶこと** ―― `ViewerViewModel.openBookIDs`
    /// (静的な登録簿)から外れず、以後のテストやアプリ側の判定に残る。
    func close() {
        for viewer in openViewers { viewer.releaseResources() }
        openViewers = []
        library.close()
    }

    // MARK: - 保存されたもの

    /// この本の読書状態の行(無ければ nil)。
    func readingState(for book: MangaBook) -> BookReadingState? {
        let all = (try? library.context.fetch(FetchDescriptor<BookReadingState>())) ?? []
        return all.first { $0.bookID == book.id }
    }

    /// この本のブックマークの行。
    func bookmarks(for book: MangaBook) -> [Bookmark] {
        let all = (try? library.context.fetch(FetchDescriptor<Bookmark>())) ?? []
        return all.filter { $0.bookID == book.id }.sorted { $0.pageIndex < $1.pageIndex }
    }
}

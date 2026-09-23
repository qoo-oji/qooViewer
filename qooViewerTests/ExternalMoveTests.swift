import Foundation
import os
import SwiftData
import Testing

@testable import qooViewer

/// アプリの外(Finder など)で名前を変えた本の保存データの付け替え(2026-09-22、利用者の指示)。
/// ストアはテスト専用のライブラリ(InMemoryLibrary)の上。
@MainActor
struct ExternalMoveTests {
    private func makeRelocator(_ library: InMemoryLibrary) -> BookRecordRelocator {
        BookRecordRelocator(
            favoritesStore: library.favorites, bookmarkStore: library.bookmarks, layoutStore: library.layouts,
            metadataStore: library.metadata, collectionStore: library.collections, modelContext: library.context
        )
    }

    /// 利用者が登録した(ロックした)メタデータの行を、ブックマークと識別子つきで作る。
    private func registerLocked(_ url: URL, in library: InMemoryLibrary) {
        _ = library.metadata.upsert(bookID: url.path, author: "A", title: "T", series: "", seriesIndex: "", sourceURL: url)
    }

    @Test("新しいパスに読みだけの行があっても、付け替えは直した行で置き換える")
    func relocationReplacesAParsedOnlyRow() async throws {
        let library = try InMemoryLibrary(label: "outside-move-replace")
        defer { library.close() }
        let temporary = try TemporaryDirectory("outside-move-replace")
        let old = temporary.file("before.cbz")
        try Data("a".utf8).write(to: old)
        registerLocked(old, in: library)
        let new = temporary.file("after.cbz")
        try FileManager.default.moveItem(at: old, to: new)
        library.metadata.registerParsedForTesting(bookID: new.path, rules: library.metadataRules.rules)
        #expect(library.metadata.metadata(forBookID: new.path)?.isParsedOnly == true)

        await makeRelocator(library).apply(FileSystemChange(relocations: [.init(from: old, to: new)])).value

        #expect(library.metadata.registeredBookIDs == [new.path])
        #expect(library.metadata.metadata(forBookID: new.path)?.author == "A")
    }

    @Test("本を開いたときの付け替えも、新しいパスの読みだけの行を置き換え、元のパスを返す")
    func reconcileOnOpenReplacesAParsedOnlyRow() throws {
        let library = try InMemoryLibrary(label: "outside-move-open")
        defer { library.close() }
        let temporary = try TemporaryDirectory("outside-move-open")
        let old = temporary.file("before.cbz")
        try Data("a".utf8).write(to: old)
        registerLocked(old, in: library)
        let new = temporary.file("after.cbz")
        try FileManager.default.moveItem(at: old, to: new)
        library.metadata.registerParsedForTesting(bookID: new.path, rules: library.metadataRules.rules)

        let book = MangaBook(id: new.path, title: "after", sourceURL: new, pages: [])
        #expect(library.metadata.reconcileBookIDIfMoved(book: book) == old.path)
        #expect(library.metadata.registeredBookIDs == [new.path])
        #expect(library.metadata.metadata(forBookID: new.path)?.author == "A")
    }

    @Test("本を開いたときの追従: 識別子を持たないメタデータの行も、ほかのストアが見つけた元のパスで付いてくる")
    func openingFollowsRowsWithoutIdentity() throws {
        // AppState.open と同じ手順(5 つの reconcile → 元のパスで applyBookRelocation)を、ストアの上で通す。
        let library = try InMemoryLibrary(label: "outside-move-open-all")
        defer { library.close() }
        let temporary = try TemporaryDirectory("outside-move-open-all")
        let old = temporary.file("before.cbz")
        try Data("a".utf8).write(to: old)
        // レイアウトは識別子つき、メタデータは識別子無し(メタデータの編集ウインドウが作った形)。
        library.layouts.setForcedDisplayMode(for: MangaBook(id: old.path, title: "before", sourceURL: old, pages: []), .single)
        library.metadata.upsertAll([.init(bookID: old.path, values: BookMetadataValues(title: "直した題"), state: .locked)])
        let new = temporary.file("after.cbz")
        try FileManager.default.moveItem(at: old, to: new)
        let book = MangaBook(id: new.path, title: "after", sourceURL: new, pages: [])

        let movedFrom = library.layouts.reconcileBookIDIfMoved(book: book)
        #expect(movedFrom == old.path)
        #expect(library.metadata.reconcileBookIDIfMoved(book: book) == nil, "識別子が無いので自分では見つけられない")
        let plan = BookRelocationPlan(bookIDs: [old.path: new.path], locators: [:], directoryBookIDs: [])
        library.metadata.applyBookRelocation(plan)

        #expect(library.metadata.metadata(forBookID: new.path)?.title == "直した題")
        #expect(library.metadata.metadata(forBookID: old.path) == nil)
    }

    @Test("ロックしていない行を付け替えたら知らせ、メタデータ生成が読み直すと新しいファイル名の値になる(2026-09-22 の監査)")
    func relocatedUnlockedRowsAreReparsed() async throws {
        let library = try InMemoryLibrary(label: "outside-move-reparse")
        defer { library.close() }
        let old = "/書庫/[架空工房] 月の庭.zip", new = "/書庫/[架空工房] 星の海.zip"
        library.metadata.registerParsedForTesting(bookID: old, rules: library.metadataRules.rules)
        #expect(library.metadata.record(forBookID: old)?.values.title == "月の庭")
        // Sendable な閉包から捕まえた変数を書き換えると CI(古いコンパイラ)だけ落ちるので、鍵つきの箱に入れる。
        let notified = OSAllocatedUnfairLock(initialState: false)
        let observer = NotificationCenter.default.addObserver(
            forName: .bookMetadataUnlockedRowsRelocated, object: library.metadata, queue: nil
        ) { _ in notified.withLock { $0 = true } }
        defer { NotificationCenter.default.removeObserver(observer) }

        library.metadata.applyBookRelocation(BookRelocationPlan(bookIDs: [old: new], locators: [:], directoryBookIDs: []))
        #expect(notified.withLock { $0 })
        #expect(library.metadata.record(forBookID: new)?.values.title == "月の庭", "付け替えだけでは古い読みのまま")

        // 読み直すのはメタデータ生成(2026-09-22。以前は AppStores が `reparseUnlockedRows` を呼んだ)。
        let generator = library.makeMetadataGenerator()
        await generator.update()
        #expect(library.metadata.record(forBookID: new)?.values.title == "星の海")
    }

    @Test("フォルダの設定の控え: 作る・アプリの外での名前の変更を見つける・付け替えた先へ鍵を移す・要らなくなった控えを捨てる")
    func folderSettingBookmarksFollowOutsideRenames() async throws {
        let suite = PreferencesSuite(label: "folder-setting-bookmarks")
        let temporary = try TemporaryDirectory("folder-setting-bookmarks")
        let folder = try temporary.directory("excluded")
        let path = MountTable.normalized(folder.path)
        let bookmarks = FolderSettingBookmarks(defaults: suite.defaults)

        await bookmarks.sync(paths: [path])
        #expect(Array(bookmarks.bookmarks.keys) == [path])
        #expect(await bookmarks.movedFolders().isEmpty)

        let renamed = temporary.file("excluded-renamed")
        try FileManager.default.moveItem(at: folder, to: renamed)
        let moved = await bookmarks.movedFolders()
        #expect(moved.map(\.from.path) == [path])
        #expect(moved.map { BookExistenceProbe.comparablePath($0.to.path) } == [BookExistenceProbe.comparablePath(renamed.path)])

        bookmarks.relocate(using: FileSystemChange(relocations: moved))
        let newPath = try #require(moved.first?.to.path)
        #expect(Array(bookmarks.bookmarks.keys) == [newPath])
        #expect(FolderSettingBookmarks(defaults: suite.defaults).bookmarks.keys.first == newPath, "保存されていない")

        await bookmarks.sync(paths: [])
        #expect(bookmarks.bookmarks.isEmpty)
    }

    @Test("アプリの外で見つけた移動は同じ時点の写しで、互いにつながない: 振り直し・入れ替え(2026-09-23 の 3 回目の監査の高 3)")
    func movesFoundOutsideTheAppAreSimultaneous() async throws {
        let library = try InMemoryLibrary(label: "outside-move-simultaneous")
        defer { library.close() }
        let temporary = try TemporaryDirectory("outside-move-simultaneous")
        func book(_ name: String, author: String) throws -> URL {
            let url = temporary.file(name)
            try Data(author.utf8).write(to: url)
            _ = library.metadata.upsert(bookID: url.path, author: author, title: "T", series: "", seriesIndex: "", sourceURL: url)
            return url
        }
        // Finder で 2 巻 → 3 巻、1 巻 → 2 巻と振り直した。見つかる一覧は [1 → 2, 2 → 3](記録したパスの順)。
        let one = try book("vol1.cbz", author: "one"), two = try book("vol2.cbz", author: "two")
        let three = temporary.file("vol3.cbz")
        try FileManager.default.moveItem(at: two, to: three)
        try FileManager.default.moveItem(at: one, to: two)
        // つなぐと 1 → 3 になり、1 巻の保存データが今の 3 巻に付いた。
        #expect(FileSystemChange(relocations: [.init(from: one, to: two), .init(from: two, to: three)]).relocatedPath(for: one.path)
            == three.path)
        let found = FileSystemChange.foundOutsideTheApp([.init(from: one, to: two), .init(from: two, to: three)])
        #expect(found.relocatedPath(for: one.path) == two.path)
        #expect(found.relocatedPath(for: two.path) == three.path)
        await makeRelocator(library).apply(found).value
        #expect(library.metadata.metadata(forBookID: two.path)?.author == "one")
        #expect(library.metadata.metadata(forBookID: three.path)?.author == "two")
        #expect(library.metadata.metadata(forBookID: one.path) == nil)

        // 入れ替え(A ⇄ B)。
        let a = try book("a.cbz", author: "a"), b = try book("b.cbz", author: "b")
        let swap = temporary.file("swap.tmp")
        try FileManager.default.moveItem(at: a, to: swap)
        try FileManager.default.moveItem(at: b, to: a)
        try FileManager.default.moveItem(at: swap, to: b)
        await makeRelocator(library).apply(FileSystemChange.foundOutsideTheApp([.init(from: a, to: b), .init(from: b, to: a)])).value
        #expect(library.metadata.metadata(forBookID: a.path)?.author == "b")
        #expect(library.metadata.metadata(forBookID: b.path)?.author == "a")

        // フォルダと中の本の両方が見つかったら、本自身の組が勝つ(いちばん深い組)。
        let nested = FileSystemChange.foundOutsideTheApp([
            .init(from: URL(fileURLWithPath: "/F"), to: URL(fileURLWithPath: "/G")),
            .init(from: URL(fileURLWithPath: "/F/b.cbz"), to: URL(fileURLWithPath: "/H/b.cbz")),
        ])
        #expect(nested.relocatedPath(for: "/F/b.cbz") == "/H/b.cbz")
        #expect(nested.relocatedPath(for: "/F/c.cbz") == "/G/c.cbz")
        #expect(nested.relocatedPath(for: "/Fx/c.cbz") == nil)
    }

    @Test("動かす組は付け替えの後の姿で決める: 出ていく行の先は空く・止まった行の先へは入らない・入れ替えもできる(2026-09-22 の監査)")
    func movesAreDecidedAfterTheRelocation() {
        func plan(_ pairs: [String: String]) -> BookRelocationPlan {
            BookRelocationPlan(bookIDs: pairs, locators: [:], directoryBookIDs: [])
        }
        // A → B、C → A が続けて届いた。A は出ていくので C は A へ入れる。
        #expect(plan(["/A": "/B", "/C": "/A"]).moves(present: ["/A", "/C"]) == ["/A": "/B", "/C": "/A"])
        // 入れ替え。
        #expect(plan(["/A": "/B", "/B": "/A"]).moves(present: ["/A", "/B"]) == ["/A": "/B", "/B": "/A"])
        // B は埋まっていて出ていかない → A は止まる → A へ入るはずの C も止まる(同じパスに 2 つ作らない)。
        #expect(plan(["/A": "/B", "/C": "/A"]).moves(present: ["/A", "/B", "/C"]).isEmpty)
        // 行の無いパスは動かさない。
        #expect(plan(["/X": "/Y"]).moves(present: []).isEmpty)
    }

    @Test("本の名前と形式は、書庫・PDF・EPUB の拡張子だけを外す(フォルダの名前の「.3」は名前のうち。2026-09-22 の監査)")
    func bookNamesKeepDotsInFolderNames() {
        #expect(BookFileName.displayName(forBookID: "/x/Title vol.3") == "Title vol.3")
        #expect(BookFileName.bookExtension(forBookID: "/x/Title vol.3") == "")
        #expect(BookFileName.displayName(forBookID: "/x/Title vol.3.CBZ") == "Title vol.3")
        #expect(BookFileName.bookExtension(forBookID: "/x/Title vol.3.CBZ") == "cbz")
        #expect(BookExportSourceFormat.folder.matches(bookID: "/x/Title vol.3"))
    }

    @Test("一時フォルダへ書き出した入れ子の書庫の本は、保存データに何も残さない本として扱う(2026-09-22 の監査)")
    func temporaryCopiesLeaveNoRecord() {
        let temporary = TemporaryFileStore.makeFileURL(extension: "cbz")
        #expect(MangaBook(id: temporary.path, title: "x", sourceURL: temporary, pages: []).leavesNoRecord)
        let ordinary = URL(fileURLWithPath: "/Users/someone/book-a.cbz")
        #expect(!MangaBook(id: ordinary.path, title: "x", sourceURL: ordinary, pages: []).leavesNoRecord)
    }

    @Test("消したメタデータは、この起動の間だけ「消した」と覚える(ファイル名の読みだけの書き手には外させない)")
    func deletedRowsAreRememberedForTheSession() throws {
        let library = try InMemoryLibrary(label: "metadata-deleted")
        defer { library.close() }
        let bookID = "/nowhere/deleted.cbz"
        library.metadata.registerParsedForTesting(bookID: bookID, rules: library.metadataRules.rules)
        library.metadata.upsertAll([.init(bookID: bookID, values: nil)])
        #expect(library.metadata.deletedThisSession == [bookID])

        // スマートライブラリ・規則の読み直しと同じ書き方(onlyIfUnlocked)では外れない。
        library.metadata.upsertAll([.init(bookID: bookID, values: BookMetadataValues(title: "T"), onlyIfUnlocked: true)])
        #expect(library.metadata.deletedThisSession == [bookID])
        // 本を開いた・窓が登録した(読みだけではない書き手)なら外れる。
        library.metadata.upsertAll([.init(bookID: bookID, values: nil)])
        library.metadata.registerParsedForTesting(bookID: bookID, rules: library.metadataRules.rules)
        #expect(library.metadata.deletedThisSession.isEmpty)
    }

    @Test("読書位置も付け替える(新しいパスに既にあれば触らない)")
    func readingStatesFollow() throws {
        let library = try InMemoryLibrary(label: "outside-move-reading")
        defer { library.close() }
        library.context.insert(BookReadingState(bookID: "/x/old.cbz", lastPageIndex: 5))
        library.context.insert(BookReadingState(bookID: "/x/a.cbz"))
        library.context.insert(BookReadingState(bookID: "/x/b.cbz"))
        try library.context.save()

        BookRecordRelocator.relocateReadingStates(["/x/old.cbz": "/x/new.cbz", "/x/a.cbz": "/x/b.cbz"], in: library.context)

        let states = try library.context.fetch(FetchDescriptor<BookReadingState>())
        #expect(Set(states.map(\.bookID)) == ["/x/new.cbz", "/x/a.cbz", "/x/b.cbz"])
        #expect(states.first { $0.bookID == "/x/new.cbz" }?.lastPageIndex == 5)
    }

    @Test("コレクションの実在確認は、別の名前で見つかった本を知らせる")
    func collectionRefreshReportsRenamedBooks() async throws {
        let library = try InMemoryLibrary(label: "outside-move-collection")
        defer { library.close() }
        let temporary = try TemporaryDirectory("outside-move-collection")
        let old = temporary.file("before.cbz")
        try Data("a".utf8).write(to: old)
        let target = try #require(library.collections.libraries.first)
        let pending = try #require(CollectionStore.makePendingItem(for: old))
        _ = try #require(library.collections.createCollection(name: "Series", in: target, items: [pending]))
        await library.collections.settleExistenceRefresh()
        var reported: [FileSystemChange.Relocation] = []
        library.collections.onBooksFoundAtNewPaths = { reported += $0 }

        let new = temporary.file("after.cbz")
        try FileManager.default.moveItem(at: old, to: new)
        library.collections.scheduleExistenceRefresh()
        await library.collections.settleExistenceRefresh()

        #expect(reported.map(\.from.path) == [old.path])
        #expect(reported.map { BookExistenceProbe.comparablePath($0.to.path) } == [BookExistenceProbe.comparablePath(new.path)])
    }

    @Test("起動後の見回りは、ブックマークを持つ本の新しい名前を見つける(持たない本と、動いていない本は挙げない)")
    func theSweeperFindsRenamedBooks() async throws {
        let library = try InMemoryLibrary(label: "outside-move-sweep")
        defer { library.close() }
        let suite = PreferencesSuite(label: "outside-move-sweep")
        let temporary = try TemporaryDirectory("outside-move-sweep")
        let old = temporary.file("before.cbz"), still = temporary.file("still.cbz")
        try Data("a".utf8).write(to: old)
        try Data("a".utf8).write(to: still)
        registerLocked(old, in: library)
        registerLocked(still, in: library)
        library.context.insert(BookReadingState(bookID: temporary.file("no-bookmark.cbz").path))
        try library.context.save()
        let new = temporary.file("after.cbz")
        try FileManager.default.moveItem(at: old, to: new)

        let moved = await ExternalMoveSweeper.movedBooks(
            favoritesStore: library.favorites, collectionStore: library.collections, bookmarkStore: library.bookmarks,
            layoutStore: library.layouts, metadataStore: library.metadata,
            folderAccess: FolderAccessStore(defaults: suite.defaults), modelContext: library.context,
            skipsCollectionBooks: true)

        #expect(moved.map(\.from.path) == [old.path])
        #expect(moved.first.map { BookExistenceProbe.comparablePath($0.to.path) } == BookExistenceProbe.comparablePath(new.path))
    }

    @Test("ビューアで開いている本(その中・その上のフォルダも)の付け替えは見送る")
    func openBooksAreNotRelocated() {
        let relocations: [FileSystemChange.Relocation] = [
            .init(from: URL(fileURLWithPath: "/x/open.cbz"), to: URL(fileURLWithPath: "/x/open-renamed.cbz")),
            .init(from: URL(fileURLWithPath: "/y/shelf"), to: URL(fileURLWithPath: "/y/shelf-renamed")),
            .init(from: URL(fileURLWithPath: "/z/closed.cbz"), to: URL(fileURLWithPath: "/z/closed-renamed.cbz")),
        ]
        let kept = ExternalMoveSweeper.excludingOpenBooks(relocations, openBookIDs: ["/x/open.cbz", "/y/shelf/book-a"])
        #expect(kept.map(\.from.path) == ["/z/closed.cbz"])
        #expect(ExternalMoveSweeper.excludingOpenBooks(relocations, openBookIDs: []).count == 3)
    }

    @Test("繋がっていないボリュームの本は見ない")
    func unmountedVolumesAreSkipped() {
        let mounts = MountTable.current()
        #expect(ExternalMoveSweeper.isLocallyReachable("/Users/someone/book.cbz", mounts: mounts))
        #expect(!ExternalMoveSweeper.isLocallyReachable(
            "/Volumes/qooViewer-no-such-volume-\(UUID().uuidString)/book.cbz", mounts: mounts))
    }

    @Test("ゴミ箱へ移した本は付け替え先にしない(「無い」になる)")
    func aBookMovedToTheTrashIsNotARelocation() throws {
        let temporary = try TemporaryDirectory("outside-move-trash")
        let old = temporary.file("before.cbz")
        try Data("a".utf8).write(to: old)
        let bookmark = try old.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        // 本物のゴミ箱には触らない(CLAUDE.md)。ブックマークは移動を追うので、`.Trash` という名前のフォルダへ移せば同じ形になる。
        let trash = try temporary.directory(".Trash")
        try FileManager.default.moveItem(at: old, to: trash.appendingPathComponent("before.cbz"))

        let located = BookExistenceProbe(bookID: old.path, bookmarkCandidates: [bookmark], isPathCovered: true)
            .locateAtRecordedPath()
        #expect(located.result == .missing)
        #expect(located.movedTo == nil)
    }
}

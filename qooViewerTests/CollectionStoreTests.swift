import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// ライブラリ・コレクション・その中の本(ViewModels/CollectionStore.swift)。
///
/// ここで押さえるのは、間違えると保存データが壊れる/画面が操作不能になるもの:
/// - ライブラリは**必ず1つ以上**(帯が空になるとコレクションの作り先が無くなる)
/// - 名前の一意性の範囲 ―― コレクションは「同じライブラリの中だけ」、ライブラリは全体
/// - 同じコレクションに同じ本を二重に入れない(パスでも iノードでも)
/// - 削除でディスク上のカバー画像まで消える(SwiftData の cascade はファイルを見ない)
@MainActor
struct CollectionStoreTests {
    /// 実体のあるフォルダの本を作る。セキュリティスコープ付きブックマークを作る必要があるため、
    /// コレクションへの登録は**実在するファイル/フォルダ**でないと失敗する(docs/13)。
    private func makeBookFolder(_ temporary: TemporaryDirectory, named name: String) throws -> URL {
        let directory = temporary.file(name)
        try FixtureFolder.make(at: directory, pages: [.init("001.jpg", number: 1)])
        return directory
    }

    private func pendingItems(_ urls: [URL]) -> [CollectionStore.PendingItem] {
        urls.compactMap { CollectionStore.makePendingItem(for: $0) }
    }

    /// 非同期に走る後始末(カバー画像の削除)を待つ。時間ではなく条件で待つ。
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("条件が満たされない")
    }

    // MARK: - ライブラリ

    @Test("ストアを作った時点でライブラリが1つある(帯を空にしない)")
    func aDefaultLibraryAlwaysExists() throws {
        let library = try InMemoryLibrary(label: "collections-default")
        defer { library.close() }
        #expect(library.collections.libraries.count == 1)
    }

    @Test("ライブラリが1つしか無いときは削除できない")
    func theLastLibraryCannotBeDeleted() throws {
        let library = try InMemoryLibrary(label: "collections-last-library")
        defer { library.close() }
        let only = try #require(library.collections.libraries.first)
        library.collections.delete(only)
        #expect(library.collections.libraries.count == 1)
    }

    @Test("既定のライブラリは名前を持たず、表示言語の見出しを出す")
    func theDefaultLibraryHasNoNameOfItsOwn() throws {
        let library = try InMemoryLibrary(label: "collections-default-name")
        defer { library.close() }
        let only = try #require(library.collections.libraries.first)

        #expect(only.usesDefaultName)
        #expect(only.displayName(language: Locale(identifier: "ja")) == "ライブラリ")
        #expect(only.displayName(language: Locale(identifier: "en")) == "Library")
    }

    @Test("日本語訳を入れる前のビルドが作った「Library」も既定のライブラリとして拾い直す")
    func anOldDefaultLibraryIsAdoptedByItsName() throws {
        let library = try InMemoryLibrary(label: "collections-default-adopt")
        defer { library.close() }
        let store = library.collections
        let only = try #require(store.libraries.first)
        // 属性を足す前の保存データの再現(名前だけがあり、既定の印は付いていない)。
        only.name = "Library"
        only.usesDefaultName = false

        store.adoptDefaultLibraryName()

        #expect(only.usesDefaultName)
        #expect(only.displayName(language: Locale(identifier: "ja")) == "ライブラリ")
    }

    @Test("名前を付けたら既定ではなくなる(表示言語を変えても付けた名前のまま)")
    func namingALibraryStopsItFromFollowingTheDisplayLanguage() throws {
        let library = try InMemoryLibrary(label: "collections-default-rename")
        defer { library.close() }
        let store = library.collections
        let only = try #require(store.libraries.first)

        store.rename(only, to: "マンガ")

        #expect(only.usesDefaultName == false)
        #expect(only.displayName(language: Locale(identifier: "ja")) == "マンガ")
        #expect(only.displayName(language: Locale(identifier: "en")) == "マンガ")
    }

    @Test("既定のライブラリは、どの言語の既定名でも二重に作らせない")
    func theDefaultLibraryOccupiesItsNameInEveryLanguage() throws {
        let library = try InMemoryLibrary(label: "collections-default-unique")
        defer { library.close() }
        let store = library.collections

        // 表示言語が何であれ、「ライブラリ」も「Library」も既定のライブラリが塞いでいる
        // (許すと、表示言語を切り替えた瞬間に同じ名前が2つ帯に並ぶ)。
        #expect(store.hasLibraryNamed("ライブラリ"))
        #expect(store.hasLibraryNamed("Library"))
        #expect(store.createLibrary(name: "ライブラリ") == nil)
        #expect(store.createLibrary(name: " Library ") == nil)
        #expect(store.libraries.count == 1)
        // 関係のない名前は作れる。
        #expect(store.createLibrary(name: "Doujinshi") != nil)
    }

    @Test("ライブラリ名は全体で一意(前後の空白は無視する)")
    func libraryNamesAreUniqueAcrossTheWholeApp() throws {
        let library = try InMemoryLibrary(label: "collections-library-names")
        defer { library.close() }
        #expect(library.collections.createLibrary(name: "Doujinshi") != nil)
        #expect(library.collections.createLibrary(name: "  Doujinshi  ") == nil)
        #expect(library.collections.createLibrary(name: "   ") == nil)
        #expect(library.collections.libraries.filter { $0.name == "Doujinshi" }.count == 1)
    }

    // MARK: - 帯の並べ替え

    @Test("ライブラリの並びは、渡した順に付け替わる")
    func reorderingLibrariesFollowsTheGivenOrder() throws {
        let library = try InMemoryLibrary(label: "collections-reorder")
        defer { library.close() }
        let first = try #require(library.collections.libraries.first)
        let second = try #require(library.collections.createLibrary(name: "CG"))
        let third = try #require(library.collections.createLibrary(name: "資料"))
        #expect(library.collections.libraries.map(\.id) == [first.id, second.id, third.id])

        // 3 番目を先頭へ(チップを左端へ落としたとき)。
        library.collections.reorderLibraries([third.id, first.id, second.id])

        #expect(library.collections.libraries.map(\.id) == [third.id, first.id, second.id])
        #expect(third.sortOrder == 0)
        #expect(first.sortOrder == 1)
        #expect(second.sortOrder == 2)
    }

    @Test("数が合わない並びは黙って捨てる(別のウインドウが同時に増減させていた場合)")
    func apartialOrderIsIgnored() throws {
        let library = try InMemoryLibrary(label: "collections-reorder-partial")
        defer { library.close() }
        let first = try #require(library.collections.libraries.first)
        let second = try #require(library.collections.createLibrary(name: "CG"))
        let before = library.collections.libraries.map(\.id)

        // 1 つ足りない / 重複している / 知らない id が混ざっている、のいずれも何も起きない。
        library.collections.reorderLibraries([second.id])
        library.collections.reorderLibraries([second.id, second.id])
        library.collections.reorderLibraries([second.id, UUID()])

        #expect(library.collections.libraries.map(\.id) == before)
        #expect(first.sortOrder == 0)
        #expect(second.sortOrder == 1)
    }

    // MARK: - カバーの見せ方(ライブラリ単位)

    @Test("新しいライブラリのカバーは 2:3・中央から始まる")
    func anewLibraryStartsWithThePortraitDefaults() throws {
        let library = try InMemoryLibrary(label: "collections-cover-defaults")
        defer { library.close() }
        let target = try #require(library.collections.libraries.first)
        #expect(target.coverAspectRatio == .portrait)
        #expect(target.coverCropAnchor == .center)
        #expect(target.coverAspectRatio.tileCellCount == 6)
    }

    @Test("カバーの縦横比と切り出し位置はライブラリごとに保存され、他のライブラリには移らない")
    func thecoverAppearanceIsPerLibrary() throws {
        let library = try InMemoryLibrary(label: "collections-cover-appearance")
        defer { library.close() }
        let first = try #require(library.collections.libraries.first)
        let second = try #require(library.collections.createLibrary(name: "CG"))

        library.collections.setCoverAppearance(second, aspectRatio: .square, anchor: .start)

        #expect(second.coverAspectRatio == .square)
        #expect(second.coverCropAnchor == .start)
        // 1:1 の札は 2 列 2 段 = 4 冊(CoverAspectRatio.tileColumns)。
        #expect(second.coverAspectRatio.tileCellCount == 4)
        #expect(first.coverAspectRatio == .portrait)
        #expect(first.coverCropAnchor == .center)
    }

    @Test("札の割り付けは、どの比でもほぼ正方形に収まる組み合わせになっている")
    func thetileLayoutStaysSquareForEveryRatio() {
        // セルの幅を w・間隔を s とすると、幅 = 列 × w + (列 - 1)s、
        // 高さ = 行 × (w / 比) + (行 - 1)s。ずれは間隔 1 本ぶんまで。
        let w: CGFloat = 60
        let s: CGFloat = 3
        for ratio in CoverAspectRatio.allCases {
            let width = CGFloat(ratio.tileColumns) * w + CGFloat(ratio.tileColumns - 1) * s
            let height = CGFloat(ratio.tileRows) * (w / ratio.value) + CGFloat(ratio.tileRows - 1) * s
            #expect(abs(width - height) <= s, "\(ratio.rawValue) は \(width) × \(height)")
        }
        #expect(CoverAspectRatio.landscape.tileColumns == 2)
        #expect(CoverAspectRatio.landscape.tileRows == 3)
    }

    @Test("カバーの見せ方を変えても、抽出済みのカバーは作り直しにならない")
    func changingTheCoverAppearanceDoesNotInvalidateCovers() throws {
        let library = try InMemoryLibrary(label: "collections-cover-appearance-keeps")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-cover-appearance-keeps")
        let target = try #require(library.collections.libraries.first)
        let book = try makeBookFolder(temporary, named: "book")
        let collection = try #require(library.collections.createCollection(
            name: "Shelf", in: target, items: pendingItems([book])
        ))
        let item = try #require(collection.items.first)
        library.collections.setCoverStatus(.ready, aspect: 1.6, for: item)

        library.collections.setCoverAppearance(target, aspectRatio: .square, anchor: .end)

        // 保存してあるのは切っていない画像なので、比を変えても抽出待ちには戻らない
        // (CoverImageResolver.cropped(_:to:anchor:) のコメント)。
        #expect(item.coverState == .ready)
        #expect(item.coverAspect == 1.6)
        #expect(library.collections.itemsAwaitingCover().isEmpty)
    }

    // MARK: - コレクション

    @Test("全件を pending へ戻すのは save 1 回(保存の世代の移行が使う)")
    func markingEveryCoverPendingSavesOnce() throws {
        let library = try InMemoryLibrary(label: "collections-mark-all-pending")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-mark-all-pending")
        let shelf = try #require(library.collections.libraries.first)
        let items = pendingItems([
            try makeBookFolder(temporary, named: "a"), try makeBookFolder(temporary, named: "b"),
        ])
        let collection = try #require(
            library.collections.createCollection(name: "Shelf", in: shelf, items: items)
        )
        for item in collection.items {
            library.collections.setCoverStatus(.ready, aspect: 1.5, for: item)
        }
        let revisionBefore = library.collections.revision

        library.collections.markAllCoversPending()

        #expect(collection.items.allSatisfy { $0.coverState == .pending })
        // 通し番号は save のたびに 1 進む。2 冊で 1 回だけ。
        #expect(library.collections.revision == revisionBefore + 1)
        // 戻すものが無ければ save も通知もしない。
        library.collections.markAllCoversPending()
        #expect(library.collections.revision == revisionBefore + 1)
    }

    @Test("起動時の掃除は、行の無いカバー画像だけを消す")
    func sweepingOrphanedCoversKeepsTheLivingOnes() async throws {
        let library = try InMemoryLibrary(label: "collections-sweep-orphans")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-sweep-orphans")
        let shelf = try #require(library.collections.libraries.first)
        let collection = try #require(
            library.collections.createCollection(
                name: "Shelf", in: shelf,
                items: pendingItems([try makeBookFolder(temporary, named: "a")])
            )
        )
        let living = try #require(collection.items.first)
        let orphanID = UUID()
        try await library.collectionCovers.write(PageImageFactory.cgImage(number: 1), for: living.id)
        try await library.collectionCovers.write(PageImageFactory.cgImage(number: 2), for: orphanID)

        library.collections.sweepOrphanedCovers()
        // 掃除は保管庫の actor へ非同期に渡る。消えたことを条件に待つ(時間では待たない)。
        for _ in 0..<500 {
            if await library.collectionCovers.image(for: orphanID) == nil { break }
            await Task.yield()
        }

        #expect(await library.collectionCovers.image(for: living.id) != nil)
        #expect(await library.collectionCovers.image(for: orphanID) == nil)
    }

    @Test("コレクション名は同じライブラリの中だけで一意(別のライブラリなら同名でよい)")
    func collectionNamesAreUniqueWithinTheirLibrary() throws {
        let library = try InMemoryLibrary(label: "collections-names")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-names")
        let book = try makeBookFolder(temporary, named: "book-a")
        let first = try #require(library.collections.libraries.first)
        let second = try #require(library.collections.createLibrary(name: "Second"))

        #expect(library.collections.createCollection(
            name: "Series", in: first, items: pendingItems([book])
        ) != nil)
        // 同じライブラリの同名は作れない(前後の空白・大文字小文字はそのまま比べる)。
        #expect(library.collections.createCollection(
            name: " Series ", in: first, items: pendingItems([book])
        ) == nil)
        #expect(library.collections.hasCollectionNamed("series", in: first) == false)
        // 別のライブラリなら同じ名前でよい。
        #expect(library.collections.createCollection(
            name: "Series", in: second, items: pendingItems([book])
        ) != nil)
    }

    @Test("本が1冊も入らないコレクションは作らない")
    func anEmptyCollectionIsNeverCreated() throws {
        let library = try InMemoryLibrary(label: "collections-empty")
        defer { library.close() }
        let target = try #require(library.collections.libraries.first)
        #expect(library.collections.createCollection(name: "Empty", in: target, items: []) == nil)
        #expect(library.collections.collections(in: target, sort: .nameAscending).isEmpty)
    }

    @Test("同じコレクションに同じ本は1つだけ(パス一致・iノード一致のどちらでも)")
    func aBookIsAddedToACollectionOnlyOnce() throws {
        let library = try InMemoryLibrary(label: "collections-duplicates")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-duplicates")
        let book = try makeBookFolder(temporary, named: "book-a")
        let other = try makeBookFolder(temporary, named: "book-b")
        let target = try #require(library.collections.libraries.first)
        let collection = try #require(library.collections.createCollection(
            name: "Series", in: target, items: pendingItems([book, book, other])
        ))
        #expect(collection.items.count == 2)

        // 同じパスをもう一度。
        #expect(library.collections.add(pendingItems([book]), to: collection).isEmpty)
        #expect(collection.items.count == 2)

        // パスは違うが同じ実体(iノードが一致する)を指すブックマークも弾く。
        let identifier = try #require(FileNodeIdentifier.current(for: book))
        let sameNodeDifferentPath = CollectionStore.PendingItem(
            url: temporary.file("moved-away"),
            bookmarkData: Data([0x01]), title: "moved-away", identifier: identifier
        )
        #expect(library.collections.add([sameNodeDifferentPath], to: collection).isEmpty)
        #expect(collection.items.count == 2)
    }

    // MARK: - 移動

    @Test("コレクションは別のライブラリへ移せる。同名が居る先へは移せない")
    func acollectionMovesBetweenLibraries() throws {
        let library = try InMemoryLibrary(label: "collections-move-collection")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-move-collection")
        let home = try #require(library.collections.libraries.first)
        let away = try #require(library.collections.createLibrary(name: "CG"))
        let book = try makeBookFolder(temporary, named: "book")
        let shelf = try #require(library.collections.createCollection(
            name: "シリーズ", in: home, items: pendingItems([book])
        ))

        #expect(library.collections.canMove(shelf, to: away))
        #expect(library.collections.move(shelf, to: away))
        #expect(library.collections.collections(in: home, sort: .nameAscending).isEmpty)
        #expect(library.collections.collections(in: away, sort: .nameAscending).map(\.name) == ["シリーズ"])
        // 中の本は付いていく。
        #expect(shelf.items.count == 1)

        // 移した先に同名が居るときは動かさない(同じライブラリ内で名前は重複させない)。
        let other = try makeBookFolder(temporary, named: "other")
        let clash = try #require(library.collections.createCollection(
            name: "シリーズ", in: home, items: pendingItems([other])
        ))
        #expect(library.collections.canMove(clash, to: away) == false)
        #expect(library.collections.move(clash, to: away) == false)
        #expect(clash.library?.id == home.id)

        // いま居るライブラリへは移せない。
        #expect(library.collections.canMove(shelf, to: away) == false)
    }

    @Test("コレクションはまとめて移せる。1つでも同名が居たら1つも動かさない")
    func collectionsMoveTogetherOrNotAtAll() throws {
        let library = try InMemoryLibrary(label: "collections-move-many")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-move-many")
        let home = try #require(library.collections.libraries.first)
        let away = try #require(library.collections.createLibrary(name: "CG"))
        let first = try #require(library.collections.createCollection(
            name: "A", in: home, items: pendingItems([try makeBookFolder(temporary, named: "a")])
        ))
        let second = try #require(library.collections.createCollection(
            name: "B", in: home, items: pendingItems([try makeBookFolder(temporary, named: "b")])
        ))

        #expect(library.collections.move([first, second], to: away))
        #expect(library.collections.collections(in: home, sort: .nameAscending).isEmpty)
        #expect(
            library.collections.collections(in: away, sort: .nameAscending).map(\.name) == ["A", "B"]
        )

        // 移した先に同名が1つでも居たら、選んだぶんは1つも動かさない。
        let third = try #require(library.collections.createCollection(
            name: "A", in: home, items: pendingItems([try makeBookFolder(temporary, named: "c")])
        ))
        let fourth = try #require(library.collections.createCollection(
            name: "C", in: home, items: pendingItems([try makeBookFolder(temporary, named: "d")])
        ))
        #expect(library.collections.move([third, fourth], to: away) == false)
        #expect(third.library?.id == home.id)
        #expect(fourth.library?.id == home.id)

        // 空の指定は何もしない。
        #expect(library.collections.move([], to: away) == false)
    }

    // MARK: - 自動登録フォルダ

    @Test("自動登録フォルダは設定・変更・クリアでき、クリアしても中の本は残る")
    func theAutoAddFolderIsStoredAndClearedWithoutTouchingTheBooks() throws {
        let library = try InMemoryLibrary(label: "collections-auto-folder")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-auto-folder")
        let home = try #require(library.collections.libraries.first)
        let book = try makeBookFolder(temporary, named: "book")
        let shelf = try temporary.directory("shelf")
        let collection = try #require(library.collections.createCollection(
            name: "Shelf", in: home, items: pendingItems([book])
        ))
        #expect(collection.autoFolderURL == nil)
        #expect(library.collections.autoFolderTargets().isEmpty)

        library.collections.setAutoFolder(shelf, for: collection)

        #expect(collection.autoFolderURL?.path == shelf.path)
        let targets = library.collections.autoFolderTargets()
        #expect(targets.count == 1)
        #expect(targets.first?.id == collection.id)
        #expect(targets.first?.folder.path == shelf.path)

        library.collections.setAutoFolder(nil, for: collection)

        #expect(collection.autoFolderURL == nil)
        #expect(library.collections.autoFolderTargets().isEmpty)
        // クリアは設定を外すだけ。それまでに入った本はそのまま残る。
        #expect(collection.items.count == 1)
    }

    @Test("走査が渡すURLからは、既に入っている本が落ちる")
    func alreadyRegisteredBooksAreFilteredOutBeforeMakingBookmarks() throws {
        let library = try InMemoryLibrary(label: "collections-auto-folder-filter")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-auto-folder-filter")
        let home = try #require(library.collections.libraries.first)
        let first = try makeBookFolder(temporary, named: "first")
        let second = try makeBookFolder(temporary, named: "second")
        let collection = try #require(library.collections.createCollection(
            name: "Shelf", in: home, items: pendingItems([first])
        ))

        #expect(
            library.collections.unregisteredURLs([first, second], in: collection).map(\.path)
                == [second.path]
        )

        _ = library.collections.add(pendingItems([second]), to: collection)

        #expect(library.collections.unregisteredURLs([first, second], in: collection).isEmpty)
    }

    // MARK: - 削除

    @Test("ライブラリを消すと、配下のコレクション・本・カバー画像まで消える")
    func deletingALibraryCascadesToItsCoversOnDisk() async throws {
        let library = try InMemoryLibrary(label: "collections-cascade")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-cascade")
        let book = try makeBookFolder(temporary, named: "book-a")
        // 消される側のライブラリ。既定のライブラリが残るので削除が通る。
        let target = try #require(library.collections.createLibrary(name: "Doomed"))
        let collection = try #require(library.collections.createCollection(
            name: "Series", in: target, items: pendingItems([book])
        ))
        let item = try #require(collection.items.first)
        try await library.collectionCovers.write(PageImageFactory.cgImage(number: 1), for: item.id)
        let coverURL = library.collectionCovers.url(for: item.id)
        #expect(FileManager.default.fileExists(atPath: coverURL.path))

        library.collections.delete(target)

        #expect(library.collections.libraries.contains { $0.id == target.id } == false)
        #expect(library.collections.collection(withID: collection.id) == nil)
        #expect(library.collections.item(withID: item.id) == nil)
        await waitUntil { !FileManager.default.fileExists(atPath: coverURL.path) }
    }

    @Test("コレクションをまとめて削除すると、選んだぶんだけがカバー画像ごと消える")
    func deletingSeveralCollectionsAtOnceLeavesTheRestAlone() async throws {
        let library = try InMemoryLibrary(label: "collections-bulk-delete")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-bulk-delete")
        let target = try #require(library.collections.libraries.first)

        var doomedCoverURLs: [URL] = []
        var doomed: [BookCollection] = []
        for name in ["A", "B"] {
            let book = try makeBookFolder(temporary, named: "book-\(name)")
            let collection = try #require(library.collections.createCollection(
                name: name, in: target, items: pendingItems([book])
            ))
            let item = try #require(collection.items.first)
            try await library.collectionCovers.write(PageImageFactory.cgImage(number: 1), for: item.id)
            doomedCoverURLs.append(library.collectionCovers.url(for: item.id))
            doomed.append(collection)
        }
        let keptBook = try makeBookFolder(temporary, named: "book-kept")
        let kept = try #require(library.collections.createCollection(
            name: "Kept", in: target, items: pendingItems([keptBook])
        ))
        #expect(doomedCoverURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        library.collections.delete(doomed)

        #expect(library.collections.collections(in: target, sort: .nameAscending).map(\.name) == ["Kept"])
        #expect(library.collections.collection(withID: kept.id) != nil)
        await waitUntil {
            doomedCoverURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    @Test("本をまとめてコレクションから外しても、外さなかった本とその実体は残る")
    func removingSeveralBooksAtOnceLeavesTheRestAlone() async throws {
        let library = try InMemoryLibrary(label: "collections-bulk-remove")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-bulk-remove")
        let books = try ["a", "b", "c"].map { try makeBookFolder(temporary, named: "book-\($0)") }
        let target = try #require(library.collections.libraries.first)
        let collection = try #require(library.collections.createCollection(
            name: "Series", in: target, items: pendingItems(books)
        ))
        let removed = Array(library.collections.items(in: collection, sort: .nameAscending).prefix(2))
        let coverURLs = removed.map { library.collectionCovers.url(for: $0.id) }
        for item in removed {
            try await library.collectionCovers.write(PageImageFactory.cgImage(number: 1), for: item.id)
        }

        library.collections.remove(removed)

        #expect(library.collections.items(in: collection, sort: .nameAscending).map(\.title) == ["book-c"])
        await waitUntil { coverURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
        // 本の実体には触れない(コレクションから外すだけ)。
        #expect(books.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("「保存データの削除」からの一括削除は、その本の登録だけを全コレクションから外す")
    func removingABookLeavesTheOtherBooksAlone() throws {
        let library = try InMemoryLibrary(label: "collections-remove-book")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-remove-book")
        let book = try makeBookFolder(temporary, named: "book-a")
        let other = try makeBookFolder(temporary, named: "book-b")
        let target = try #require(library.collections.libraries.first)
        let first = try #require(library.collections.createCollection(
            name: "A", in: target, items: pendingItems([book, other])
        ))
        let second = try #require(library.collections.createCollection(
            name: "B", in: target, items: pendingItems([book])
        ))
        #expect(library.collections.membershipCount(forBookID: book.path) == 2)

        library.collections.removeItems(forBookID: book.path)

        #expect(library.collections.membershipCount(forBookID: book.path) == 0)
        #expect(first.items.map(\.bookID) == [other.path])
        #expect(second.items.isEmpty)
    }

    @Test("deleteAll はライブラリ・コレクション・本をすべて消し、既定のライブラリを作り直す")
    func deleteAllStartsOverWithOneLibrary() throws {
        let library = try InMemoryLibrary(label: "collections-delete-all")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-delete-all")
        let book = try makeBookFolder(temporary, named: "book-a")
        let target = try #require(library.collections.createLibrary(name: "Doujinshi"))
        _ = library.collections.createCollection(name: "Series", in: target, items: pendingItems([book]))

        library.collections.deleteAll()

        #expect(library.collections.libraries.count == 1)
        #expect(library.collections.allRegisteredBookIDs().isEmpty)
    }

    // MARK: - 移動・リネームへの追従

    @Test("同一ボリューム内で移動した本は、次に開いたときに登録が追従する")
    func aMovedBookKeepsItsCollectionEntry() async throws {
        let library = try InMemoryLibrary(label: "collections-reconcile")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-reconcile")
        let original = try makeBookFolder(temporary, named: "book-a")
        let target = try #require(library.collections.libraries.first)
        let collection = try #require(library.collections.createCollection(
            name: "Series", in: target, items: pendingItems([original])
        ))

        let moved = temporary.file("book-a-renamed")
        try FileManager.default.moveItem(at: original, to: moved)
        let book = try await FixtureBook.load(moved)
        library.collections.reconcileBookIDIfMoved(book: book)

        #expect(library.collections.allRegisteredBookIDs() == [moved.path])
        // 表示名も新しいフォルダ名へ追従する(カバー下のキャプションに古い名前が残らない)。
        #expect(collection.items.map(\.title) == ["book-a-renamed"])
    }

    @Test("リネームに追従した書庫の表示名は、登録時と同じ規則(拡張子を落とす)で付け直される")
    func aRenamedArchiveKeepsTheRegistrationTitleRule() async throws {
        let library = try InMemoryLibrary(label: "collections-reconcile-title")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-reconcile-title")
        var builder = ZipFixtureBuilder()
        builder.add("001.png", PageImageFactory.png(number: 1))
        let original = temporary.file("volume-01.cbz")
        try builder.write(to: original)
        let target = try #require(library.collections.libraries.first)
        let collection = try #require(library.collections.createCollection(
            name: "Series", in: target, items: pendingItems([original])
        ))
        #expect(collection.items.map(\.title) == ["volume-01"])

        let renamed = temporary.file("volume-02.cbz")
        try FileManager.default.moveItem(at: original, to: renamed)
        let book = try await FixtureBook.load(renamed)
        library.collections.reconcileBookIDIfMoved(book: book)

        #expect(library.collections.allRegisteredBookIDs() == [renamed.path])
        #expect(collection.items.map(\.title) == ["volume-02"])
    }

    @Test("iノードが一致しない別のファイルでは、登録も表示名も書き換えない")
    func anUnrelatedBookLeavesTheEntryAlone() async throws {
        let library = try InMemoryLibrary(label: "collections-reconcile-other")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-reconcile-other")
        let registered = try makeBookFolder(temporary, named: "book-a")
        let other = try makeBookFolder(temporary, named: "book-b")
        let target = try #require(library.collections.libraries.first)
        let collection = try #require(library.collections.createCollection(
            name: "Series", in: target, items: pendingItems([registered])
        ))

        let book = try await FixtureBook.load(other)
        library.collections.reconcileBookIDIfMoved(book: book)

        #expect(library.collections.allRegisteredBookIDs() == [registered.path])
        #expect(collection.items.map(\.title) == ["book-a"])
    }

    // MARK: - 並び順

    @Test("コレクションと本の並びは、指定した基準と向きに従う")
    func sortingFollowsTheRequestedOrder() throws {
        let library = try InMemoryLibrary(label: "collections-sort")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-sort")
        let target = try #require(library.collections.libraries.first)
        let bookB = try makeBookFolder(temporary, named: "b-book")
        let bookA = try makeBookFolder(temporary, named: "a-book")

        // 作成順は Zebra → Alpha。追加順は b → a。
        let zebra = try #require(library.collections.createCollection(
            name: "Zebra", in: target, items: pendingItems([bookB])
        ))
        _ = library.collections.add(pendingItems([bookA]), to: zebra)
        _ = try #require(library.collections.createCollection(
            name: "Alpha", in: target, items: pendingItems([bookA])
        ))

        #expect(library.collections.collections(in: target, sort: .nameAscending).map(\.name)
            == ["Alpha", "Zebra"])
        #expect(library.collections.collections(in: target, sort: .nameDescending).map(\.name)
            == ["Zebra", "Alpha"])
        #expect(library.collections.collections(in: target, sort: .dateAddedAscending).map(\.name)
            == ["Zebra", "Alpha"])
        #expect(library.collections.collections(in: target, sort: .dateAddedDescending).map(\.name)
            == ["Alpha", "Zebra"])

        #expect(library.collections.items(in: zebra, sort: .nameAscending).map(\.title)
            == ["a-book", "b-book"])
        #expect(library.collections.items(in: zebra, sort: .dateAddedAscending).map(\.title)
            == ["b-book", "a-book"])
        // 本には「更新日時」が無いので、追加日時と同じ並びになる(items(in:sort:) のコメント)。
        #expect(library.collections.items(in: zebra, sort: .dateUpdatedAscending).map(\.title)
            == ["b-book", "a-book"])
    }

    // MARK: - 常に先頭/末尾に表示

    @Test("常に先頭/末尾に指定したコレクションは、並び順の向きに関わらず端に出る")
    func pinnedCollectionsStayAtTheEnds() throws {
        let library = try InMemoryLibrary(label: "collections-pin")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-pin")
        let target = try #require(library.collections.libraries.first)
        let book = try makeBookFolder(temporary, named: "book")
        let names = ["Alpha", "Middle", "Zebra", "未分類"]
        var created: [String: BookCollection] = [:]
        for name in names {
            // #require の結果を辞書へ直に入れない ―― 代入先が Optional なので、マクロが
            // 「元から非 Optional」と誤って判断して「この #require は不要」の警告を出す
            // (CI は警告をエラーにする)。いったん let で受ける。
            let collection = try #require(library.collections.createCollection(
                name: name, in: target, items: pendingItems([book])
            ))
            created[name] = collection
        }

        library.collections.setPinnedCollection(created["未分類"], atStart: true, in: target)
        library.collections.setPinnedCollection(created["Zebra"], atStart: false, in: target)

        #expect(library.collections.collections(in: target, sort: .nameAscending).map(\.name)
            == ["未分類", "Alpha", "Middle", "Zebra"])
        // 向きを逆にしても端の2つは動かない(間だけが入れ替わる)。
        #expect(library.collections.collections(in: target, sort: .nameDescending).map(\.name)
            == ["未分類", "Middle", "Alpha", "Zebra"])
        // 書き出しが使う「指定を無視した純粋な並び」(applyingPins: false)。
        #expect(
            library.collections
                .collections(in: target, sort: .nameAscending, applyingPins: false).map(\.name)
                == ["Alpha", "Middle", "Zebra", "未分類"]
        )
    }

    @Test("同じコレクションを先頭と末尾の両方には指定できない(元の側が外れる)")
    func aCollectionCannotBePinnedToBothEnds() throws {
        let library = try InMemoryLibrary(label: "collections-pin-both")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-pin-both")
        let target = try #require(library.collections.libraries.first)
        let book = try makeBookFolder(temporary, named: "book")
        let collection = try #require(library.collections.createCollection(
            name: "未分類", in: target, items: pendingItems([book])
        ))

        library.collections.setPinnedCollection(collection, atStart: true, in: target)
        library.collections.setPinnedCollection(collection, atStart: false, in: target)

        #expect(target.pinnedFirstCollectionID == nil)
        #expect(library.collections.pinnedLastCollection(in: target)?.name == "未分類")
    }

    @Test("指定したコレクションを削除・別のライブラリへ移すと、指定は外れる")
    func pinsAreClearedWhenTheCollectionLeaves() throws {
        let library = try InMemoryLibrary(label: "collections-pin-clear")
        defer { library.close() }
        let temporary = try TemporaryDirectory("collections-pin-clear")
        let home = try #require(library.collections.libraries.first)
        let away = try #require(library.collections.createLibrary(name: "別の棚"))
        let book = try makeBookFolder(temporary, named: "book")
        let moving = try #require(library.collections.createCollection(
            name: "移すほう", in: home, items: pendingItems([book])
        ))
        let deleting = try #require(library.collections.createCollection(
            name: "消すほう", in: home, items: pendingItems([book])
        ))

        library.collections.setPinnedCollection(moving, atStart: true, in: home)
        library.collections.setPinnedCollection(deleting, atStart: false, in: home)

        #expect(library.collections.move(moving, to: away))
        library.collections.delete(deleting)

        #expect(home.pinnedFirstCollectionID == nil)
        #expect(home.pinnedLastCollectionID == nil)
        // 移した先で勝手に固定されることもない。
        #expect(away.pinnedFirstCollectionID == nil)
    }
}

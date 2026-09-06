import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// お気に入りの上限とフォルダの移動(ViewModels/FavoritesStore.swift)。
///
/// 見るのは、間違えると木が壊れる 2 つ:
/// - 総数 999 / 階層 3 の上限(`FavoritesLimits`)。
/// - `move(_:to:)` の循環禁止 ―― 自分自身や自分の子孫へ移すと親子関係が輪になり、`depth` や
///   `breadcrumb` が無限に辿り続ける。
@MainActor
struct FavoritesLimitTests {
    /// 上限の付近を試すために、ストアを通さず行だけを直に入れる。
    /// `forceAddFavorite` を 998 回呼ぶには本物の本が 998 冊要る(セキュリティスコープ付き
    /// ブックマークを作るため)ので、件数を作るところだけ手で埋める。
    private func fillFavorites(_ library: InMemoryLibrary, count: Int) {
        for index in 0..<count {
            library.context.insert(FavoriteBook(
                bookID: "/books/filler\(index)", bookmarkData: Data([0x01]),
                title: "filler\(index)", folder: nil, sortOrder: index
            ))
        }
        try? library.context.save()
        library.favorites.reload()
    }

    private func makeBook(_ temporary: TemporaryDirectory, named name: String) async throws -> MangaBook {
        let directory = temporary.file(name)
        try FixtureFolder.make(at: directory, pages: [.init("001.jpg", number: 1)])
        return try await FixtureBook.load(directory)
    }

    // MARK: - 件数の上限

    @Test("上限は 999 件・3 階層(アプリ全体がこの 2 つの数値に従う)")
    func theLimitsAreDeclaredInOnePlace() {
        #expect(FavoritesLimits.maxFavoritesCount == 999)
        #expect(FavoritesLimits.maxFolderDepth == 3)
    }

    @Test("上限の 1 つ手前までは登録でき、上限に達したら limitReached")
    func theLastSlotIsUsableAndTheNextOneIsRefused() async throws {
        let library = try InMemoryLibrary(label: "favorites-limit")
        defer { library.close() }
        let temporary = try TemporaryDirectory("favorites-limit")
        let first = try await makeBook(temporary, named: "book-a")
        let second = try await makeBook(temporary, named: "book-b")

        fillFavorites(library, count: FavoritesLimits.maxFavoritesCount - 1)
        #expect(library.favorites.totalFavoritesCount() == 998)

        // 999 件目は入る。
        switch library.favorites.forceAddFavorite(book: first, to: nil) {
        case .added: break
        case let other: Issue.record("999 件目が登録できない: \(other)")
        }
        #expect(library.favorites.totalFavoritesCount() == 999)

        // 1000 件目は断られる ―― 件数は増えない。
        switch library.favorites.forceAddFavorite(book: second, to: nil) {
        case .limitReached: break
        case let other: Issue.record("1000 件目が断られない: \(other)")
        }
        #expect(library.favorites.totalFavoritesCount() == 999)
    }

    @Test("上限に達していても、同じフォルダの登録済みの本は上書きできる(件数が増えないため)")
    func overwritingAnExistingEntryIsAllowedAtTheLimit() async throws {
        let library = try InMemoryLibrary(label: "favorites-overwrite")
        defer { library.close() }
        let temporary = try TemporaryDirectory("favorites-overwrite")
        let book = try await makeBook(temporary, named: "book")

        library.favorites.forceAddFavorite(book: book, to: nil)
        fillFavorites(library, count: FavoritesLimits.maxFavoritesCount - 1)
        #expect(library.favorites.totalFavoritesCount() == 999)

        switch library.favorites.addFavorite(book: book, to: nil) {
        case .overwritten: break
        case let other: Issue.record("上書きにならない: \(other)")
        }
        #expect(library.favorites.totalFavoritesCount() == 999)
    }

    // MARK: - 階層の上限

    @Test("フォルダは 3 階層まで。4 階層目は作れない")
    func foldersStopAtTheDepthLimit() throws {
        let library = try InMemoryLibrary(label: "favorites-depth")
        defer { library.close() }
        let favorites = library.favorites

        #expect(favorites.canCreateSubfolder(in: nil))
        let level1 = try #require(try? favorites.createFolder(name: "1", parent: nil).get())
        let level2 = try #require(try? favorites.createFolder(name: "2", parent: level1).get())
        let level3 = try #require(try? favorites.createFolder(name: "3", parent: level2).get())
        let depths: [Int] = [level1.depth, level2.depth, level3.depth]
        #expect(depths == [1, 2, 3])

        #expect(!favorites.canCreateSubfolder(in: level3))
        switch favorites.createFolder(name: "4", parent: level3) {
        case .failure(.folderDepthLimitReached): break
        case let other: Issue.record("4 階層目が作れてしまう: \(other)")
        }
    }

    // MARK: - フォルダの移動

    /// `a > b > c` の 3 階層と、ルート直下の `other` を作る。
    private func makeTree(_ favorites: FavoritesStore)
        throws -> (a: FavoriteFolder, b: FavoriteFolder, c: FavoriteFolder, other: FavoriteFolder)
    {
        let a = try #require(try? favorites.createFolder(name: "a", parent: nil).get())
        let b = try #require(try? favorites.createFolder(name: "b", parent: a).get())
        let c = try #require(try? favorites.createFolder(name: "c", parent: b).get())
        let other = try #require(try? favorites.createFolder(name: "other", parent: nil).get())
        return (a, b, c, other)
    }

    @Test("自分自身の中へは移せない(親子が輪になる)")
    func aFolderCannotBeMovedIntoItself() throws {
        let library = try InMemoryLibrary(label: "favorites-self")
        defer { library.close() }
        let tree = try makeTree(library.favorites)
        #expect(!library.favorites.move(tree.a, to: tree.a))
        #expect(tree.a.parent == nil)
    }

    @Test("自分の子孫の中へも移せない")
    func aFolderCannotBeMovedIntoItsOwnDescendant() throws {
        let library = try InMemoryLibrary(label: "favorites-descendant")
        defer { library.close() }
        let tree = try makeTree(library.favorites)
        #expect(!library.favorites.move(tree.a, to: tree.b))
        #expect(!library.favorites.move(tree.a, to: tree.c))  // 孫でも同じ
        #expect(tree.a.parent == nil)
        #expect(tree.b.parent?.id == tree.a.id)
    }

    @Test("移した先で 3 階層を超えるなら断る(部分木の高さごと見る)")
    func movingASubtreeThatWouldOverflowTheDepthIsRefused() throws {
        let library = try InMemoryLibrary(label: "favorites-overflow")
        defer { library.close() }
        let tree = try makeTree(library.favorites)

        // a は自分の下に 2 段(b・c)を抱えている。other(深さ 1)の下へ移すと a が 2 階層目、
        // c が 4 階層目になるので断る。
        #expect(!library.favorites.move(tree.a, to: tree.other))
        #expect(tree.a.parent == nil)

        // 一番深い c(下に何も無い)だけなら other の下(2 階層目)へ移せる。
        #expect(library.favorites.move(tree.c, to: tree.other))
        #expect(tree.c.parent?.id == tree.other.id)
        #expect(tree.c.depth == 2)
    }

    @Test("移せたら親が変わり、配下の子も付いてくる")
    func aSuccessfulMoveReparentsTheWholeSubtree() throws {
        let library = try InMemoryLibrary(label: "favorites-move")
        defer { library.close() }
        let favorites = library.favorites
        let tree = try makeTree(favorites)
        let sibling = try #require(try? favorites.createFolder(name: "sibling", parent: tree.other).get())

        #expect(favorites.move(tree.b, to: tree.other))
        #expect(tree.b.parent?.id == tree.other.id)
        // 一覧の**並び**は `sortOption`(利用者の設定)で決まるので、ここでは顔ぶれだけを見る。
        #expect(Set(favorites.subfolders(of: tree.other).map(\.name)) == Set([sibling.name, tree.b.name]))
        // 子(c)は付いてくる。
        #expect(tree.c.parent?.id == tree.b.id)
        #expect(tree.c.depth == 3)
    }

    @Test("ルート直下へ戻せる")
    func aFolderCanBeMovedBackToTheTopLevel() throws {
        let library = try InMemoryLibrary(label: "favorites-toroot")
        defer { library.close() }
        let tree = try makeTree(library.favorites)
        #expect(library.favorites.move(tree.c, to: nil))
        #expect(tree.c.parent == nil)
        #expect(tree.c.depth == 1)
    }

    @Test("同じ親への「移動」は断らない(何も変わらないだけ)")
    func movingToTheSameParentSucceedsWithoutChanges() throws {
        let library = try InMemoryLibrary(label: "favorites-same")
        defer { library.close() }
        let tree = try makeTree(library.favorites)
        #expect(library.favorites.move(tree.b, to: tree.a))
        #expect(tree.b.parent?.id == tree.a.id)
    }
}

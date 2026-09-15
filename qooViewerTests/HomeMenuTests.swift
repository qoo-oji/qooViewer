import Combine
import Foundation
import Testing

@testable import qooViewer

/// メニューバーの「ホーム」メニュー(2026-09-15)のうち、画面を出さずに確かめられるもの。
///
/// - 何を相手にするか(HomeMenuState)―― 間違えると、見えていないコレクションを消す・別のライブラリへ移す
/// - 名前の写し(HomeMenuDirectoryStore)―― 名前に関わらない変化でメニューを作り直さない
/// - 画面への依頼(WelcomeLibraryState.menuRequest)―― 受け持たない画面が依頼を取り上げない
///
/// メニューの見た目と、依頼を拾った画面がシート・確認を出すところは実機で確かめる(docs/09)。
@MainActor
struct HomeMenuTests {
    // MARK: - 相手

    private func shelf(
        opened: UUID? = nil, collections: [UUID] = [], items: [UUID] = [], allowsEditing: Bool = true
    ) -> HomeMenuState {
        HomeMenuState(
            isShown: true, mode: .shelf, allowsEditing: allowsEditing, libraryID: UUID(),
            openedCollectionID: opened, isEditing: true,
            selectedCollectionIDs: collections, selectedItemIDs: items
        )
    }

    @Test("コレクションの中にいるときは、選択に関係なくそのコレクションが相手")
    func theOpenedCollectionIsTheTarget() {
        let opened = UUID()
        let state = shelf(opened: opened, items: [UUID(), UUID()])
        #expect(state.collectionTargets == [opened])
        #expect(state.singleCollectionTarget == opened)
        #expect(state.canRenameCollection)
        #expect(state.canAddBooks)
        #expect(state.itemTargets.count == 2)
        #expect(state.singleItemTarget == nil)
        #expect(state.canShowCollectionSettings)
        #expect(!state.canShowLibrarySettings)
    }

    @Test("一覧では選んだコレクションが相手。名前の変更と本の追加は1つだけのとき")
    func theSelectionIsTheTargetInTheList() {
        let first = UUID()
        let second = UUID()
        let two = shelf(collections: [first, second])
        #expect(two.collectionTargets == [first, second])
        #expect(two.canDeleteCollections)
        #expect(!two.canRenameCollection)
        #expect(!two.canAddBooks)
        // 一覧には本の選択が無い。
        #expect(two.itemTargets.isEmpty)
        #expect(!two.canRemoveItems)

        let none = shelf()
        #expect(none.collectionTargets.isEmpty)
        #expect(!none.canDeleteCollections)
        #expect(none.canCreateCollection)
        #expect(none.canShowLibrarySettings)
    }

    @Test("本を開いている・ファイルブラウザ・シークレットウインドウでは何も相手にしない")
    func nothingIsTargetedOutsideTheShelf() {
        let id = UUID()
        var reading = shelf(collections: [id])
        reading.isShown = false
        #expect(reading.collectionTargets.isEmpty)
        #expect(!reading.canCreateLibrary)
        #expect(!reading.canToggleEditing)

        var browsing = shelf(opened: id, items: [UUID()])
        browsing.mode = .browser
        #expect(browsing.collectionTargets.isEmpty)
        #expect(browsing.itemTargets.isEmpty)
        #expect(!browsing.canCreateCollection)
        // ライブラリの作成はファイルブラウザからもできる(帯の「＋」と同じ)。
        #expect(browsing.canCreateLibrary)

        let privateWindow = shelf(opened: id, items: [UUID()], allowsEditing: false)
        #expect(!privateWindow.canRenameCollection)
        #expect(!privateWindow.canDeleteCollections)
        #expect(!privateWindow.canRemoveItems)
        #expect(!privateWindow.canCreateLibrary)
        #expect(!privateWindow.canToggleEditing)
    }

    @Test("最後の1つのライブラリは削除できない")
    func theLastLibraryCannotBeDeletedFromTheMenu() {
        let state = shelf()
        let one = HomeMenuDirectory(libraries: [library(state.libraryID!, collections: [])])
        #expect(!state.canDeleteLibrary(in: one))
        let two = HomeMenuDirectory(libraries: one.libraries + [library(UUID(), collections: [])])
        #expect(state.canDeleteLibrary(in: two))
    }

    @Test("移す先に同じ名前があれば、1つでも衝突したら行き先ごと選べない")
    func movingIsRefusedWhenANameClashes() {
        let a = UUID()
        let b = UUID()
        var state = shelf(collections: [a, b])
        let currentID = state.libraryID!
        let otherID = UUID()
        let clashingID = UUID()
        let directory = HomeMenuDirectory(libraries: [
            library(currentID, collections: [.init(id: a, name: "Shelf A"), .init(id: b, name: "Shelf B")]),
            library(otherID, collections: [.init(id: UUID(), name: "Shelf C")]),
            // 前後の空白を除いた完全一致で衝突(CollectionStore.hasCollectionNamed と同じ)。
            library(clashingID, collections: [.init(id: UUID(), name: " Shelf B ")]),
        ])
        #expect(state.canMoveCollections(to: otherID, in: directory))
        #expect(!state.canMoveCollections(to: clashingID, in: directory))
        // いま居るライブラリへは移せない。
        #expect(!state.canMoveCollections(to: currentID, in: directory))

        state.selectedCollectionIDs = [a]
        #expect(state.canMoveCollections(to: clashingID, in: directory))
    }

    private func library(_ id: UUID, collections: [HomeMenuDirectory.Collection]) -> HomeMenuDirectory.Library {
        HomeMenuDirectory.Library(id: id, name: "Library \(id.uuidString.prefix(4))", usesDefaultName: false, collections: collections)
    }

    // MARK: - 名前の写し

    private func makeBookFolder(_ temporary: TemporaryDirectory, named name: String) throws -> URL {
        let directory = temporary.file(name)
        try FixtureFolder.make(at: directory, pages: [.init("001.jpg", number: 1)])
        return directory
    }

    /// 写しの更新は1ランループ待ってから(HomeMenuDirectoryStore.scheduleRefresh)。時間ではなく条件で待つ。
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("条件が満たされない")
    }

    /// 後から来る知らせが無いことを確かめるために、少しだけ待つ。
    private func settle() async {
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("名前・所属が変わったときだけ写しが変わり、表紙の状態では知らせない")
    func theDirectoryPublishesOnlyWhenNamesChange() async throws {
        let library = try InMemoryLibrary(label: "home-menu-directory")
        defer { library.close() }
        let temporary = try TemporaryDirectory("home-menu-directory")
        let store = HomeMenuDirectoryStore(collectionStore: library.collections)
        var publishCount = 0
        let subscription = store.objectWillChange.sink { publishCount += 1 }
        defer { subscription.cancel() }

        let shelf = try #require(library.collections.libraries.first)
        // `#require` は入れ子にしない(マクロの展開が再帰になってビルドが通らない)。
        let book = try #require(CollectionStore.makePendingItem(for: try makeBookFolder(temporary, named: "book")))
        let otherBook = try #require(CollectionStore.makePendingItem(for: try makeBookFolder(temporary, named: "other")))
        let collection = try #require(library.collections.createCollection(name: "Shelf B", in: shelf, items: [book]))
        _ = library.collections.createCollection(name: "Shelf A", in: shelf, items: [otherBook])
        await waitUntil { store.directory.libraries.first?.collections.count == 2 }
        // 並びは名前の昇順。
        #expect(store.directory.libraries.first?.collections.map(\.name) == ["Shelf A", "Shelf B"])

        await settle()
        let countBefore = publishCount
        let item = try #require(collection.items.first)
        library.collections.setCoverStatus(.ready, aspect: 1.5, for: item)
        await settle()
        #expect(publishCount == countBefore)

        library.collections.rename(collection, to: "Shelf C")
        await waitUntil { store.directory.libraries.first?.collections.last?.name == "Shelf C" }
        #expect(publishCount > countBefore)

        let other = try #require(library.collections.createLibrary(name: "Second"))
        #expect(library.collections.move(collection, to: other))
        await waitUntil { store.directory.library(withID: other.id)?.collections.map(\.id) == [collection.id] }
    }

    // MARK: - 画面への依頼

    @Test("受け持たない依頼は取り上げず、別の画面のために残す")
    func requestsAreLeftForTheViewThatHandlesThem() {
        let suite = PreferencesSuite(label: "home-menu-request")
        defer { withExtendedLifetime(suite) {} }
        let state = WelcomeLibraryState(defaults: suite.defaults)
        let id = UUID()
        state.request(.renameLibrary(id))

        let ignored = state.takeMenuRequest { if case .renameCollection = $0 { true } else { false } }
        #expect(ignored == nil)
        #expect(state.menuRequest?.kind == .renameLibrary(id))

        let taken = state.takeMenuRequest { if case .renameLibrary = $0 { true } else { false } }
        #expect(taken == .renameLibrary(id))
        #expect(state.menuRequest == nil)

        // 同じ依頼を続けて出しても別の値になる(onChange が拾える)。
        state.request(.focusSearch)
        let first = state.menuRequest
        state.request(.focusSearch)
        #expect(state.menuRequest != first)

        // 本を開いたときの後始末で捨てる(戻ってきたときに古い依頼で確認が出ない)。
        state.endEditing()
        #expect(state.menuRequest == nil)
    }
}

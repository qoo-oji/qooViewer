import Foundation
import Testing

@testable import qooViewer

/// ファイルブラウザの小さな値(改善要望7 段階3): 矢印キーの移動・ウインドウへ渡す値・よく使う項目・
/// ウェルカム画面のモード。
@MainActor
struct FileBrowserModelTests {
    // MARK: - GridKeyboardNavigation

    @Test("未選択ならどの矢印でも先頭。項目が無ければ nil")
    func gridStartsAtTheFirstItem() {
        for direction in [GridKeyboardNavigation.Direction.up, .down, .left, .right] {
            #expect(GridKeyboardNavigation.target(from: nil, count: 5, columns: 3, direction: direction) == 0)
        }
        #expect(GridKeyboardNavigation.target(from: nil, count: 0, columns: 3, direction: .down) == nil)
    }

    @Test("←→は行をまたいで前後へ、両端では動かない")
    func gridHorizontalMovement() {
        #expect(GridKeyboardNavigation.target(from: 2, count: 7, columns: 3, direction: .right) == 3)
        #expect(GridKeyboardNavigation.target(from: 3, count: 7, columns: 3, direction: .left) == 2)
        #expect(GridKeyboardNavigation.target(from: 0, count: 7, columns: 3, direction: .left) == 0)
        #expect(GridKeyboardNavigation.target(from: 6, count: 7, columns: 3, direction: .right) == 6)
    }

    @Test("↑↓は同じ列の上下。最終行が短ければ最後の項目へ、最終行にいれば動かない")
    func gridVerticalMovement() {
        // 0 1 2 / 3 4 5 / 6
        #expect(GridKeyboardNavigation.target(from: 1, count: 7, columns: 3, direction: .down) == 4)
        #expect(GridKeyboardNavigation.target(from: 4, count: 7, columns: 3, direction: .down) == 6)
        #expect(GridKeyboardNavigation.target(from: 6, count: 7, columns: 3, direction: .down) == 6)
        #expect(GridKeyboardNavigation.target(from: 4, count: 7, columns: 3, direction: .up) == 1)
        #expect(GridKeyboardNavigation.target(from: 1, count: 7, columns: 3, direction: .up) == 1)
    }

    // MARK: - WindowContentRequest

    @Test("ウインドウへ渡す値は Codable で往復する")
    func windowContentRequestRoundTrips() throws {
        let book = WindowContentRequest.book(BookOpenRequest(URL(fileURLWithPath: "/tmp/sample.cbz")))
        let folder = WindowContentRequest.browse(URL(fileURLWithPath: "/tmp/folder", isDirectory: true))
        for value in [book, folder] {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(WindowContentRequest.self, from: data) == value)
        }
        #expect(book.bookRequest != nil && book.browsedFolder == nil)
        #expect(folder.browsedFolder?.path == "/tmp/folder" && folder.bookRequest == nil)
    }

    @Test("同じフォルダでも、開くたびに別の値になる(同じフォルダを2枚で見られる)。本は同じ値のまま")
    func browseRequestsAreNeverEqual() {
        let url = URL(fileURLWithPath: "/tmp/folder", isDirectory: true)
        #expect(WindowContentRequest.browse(url) != WindowContentRequest.browse(url))
        let book = BookOpenRequest(URL(fileURLWithPath: "/tmp/sample.cbz"))
        #expect(WindowContentRequest.book(book) == WindowContentRequest.book(book))
    }

    // MARK: - FavoriteLocationStore

    @Test("よく使う項目は同じパスを二重に登録せず、保存されて開き直しても残る")
    func favoriteLocationsPersist() {
        let suite = PreferencesSuite(label: "favorite-locations")
        let store = FavoriteLocationStore(defaults: suite.defaults)
        let first = store.add(URL(fileURLWithPath: "/tmp/one/", isDirectory: true))
        let again = store.add(URL(fileURLWithPath: "/tmp/one", isDirectory: true))
        store.add(URL(fileURLWithPath: "/tmp/two", isDirectory: true))
        #expect(first == again)
        #expect(store.items.map(\.path) == ["/tmp/one", "/tmp/two"])

        let reopened = FavoriteLocationStore(defaults: suite.defaults)
        #expect(reopened.items == store.items)
        reopened.remove(id: first.id)
        #expect(FavoriteLocationStore(defaults: suite.defaults).items.map(\.path) == ["/tmp/two"])
    }

    // MARK: - WelcomeLibraryState.mode

    @Test("ウェルカム画面のモードは保存され、本棚へ戻ると編集モードから出る")
    func welcomeModePersists() {
        let suite = PreferencesSuite(label: "welcome-mode")
        let state = WelcomeLibraryState(defaults: suite.defaults)
        #expect(state.mode == .shelf)
        state.isEditing = true
        state.mode = .browser
        #expect(!state.isEditing)
        #expect(WelcomeLibraryState(defaults: suite.defaults).mode == .browser)
    }
}

import Foundation
import Testing

@testable import qooViewer

/// 開いているウインドウ/タブの登録簿(ViewModels/LaunchCoordinator.swift)。
///
/// 「すでに開いている本をもう一度開こうとしたら、そのウインドウを前に出す」の判定役。
/// 落とし穴が 2 つあり、どちらも過去に直したもの:
/// - **性質の一致で見る。** 通常ウインドウの要求にシークレットウインドウを返してはいけない
///   (記録が残るつもりの本が、どこにも残らないウインドウで開く)。逆も同じ。
/// - **複数枚の画像をまとめた本は対象外。** その `sourceURL` は「先頭 1 枚の画像」でしかなく、
///   あとから同じ画像 1 枚を開くと、無関係な本を開いているウインドウが前に出てきてしまう。
///
/// ウインドウの前後関係を見る `frontmostContentAppState` は `NSWindow` が要るので、ここでは扱わない
/// (docs/13 の「実機に残すもの」)。
@MainActor
struct LaunchCoordinatorTests {
    private struct Environment {
        let library: InMemoryLibrary
        let suite: PreferencesSuite
        let preferences: AppPreferences
        let recentFiles: RecentFilesStore
        let temporary: TemporaryDirectory
        let coordinator = LaunchCoordinator()

        init() throws {
            library = try InMemoryLibrary(label: "launch")
            suite = PreferencesSuite(label: "launch")
            preferences = suite.makePreferences()
            recentFiles = RecentFilesStore(defaults: suite.defaults)
            temporary = try TemporaryDirectory("launch")
        }

        func close() { library.close() }

        func makeAppState(isPrivate: Bool = false) -> AppState {
            let state = AppState(isPrivateWindow: isPrivate, usesPageListCache: false)
            state.preferences = preferences
            state.favoritesStore = library.favorites
            state.bookmarkStore = library.bookmarks
            state.layoutStore = library.layouts
            state.metadataStore = library.metadata
            state.recentFiles = recentFiles
            return state
        }

        func makeFolder(_ name: String, pageCount: Int = 2) throws -> URL {
            let directory = temporary.file(name)
            try FixtureFolder.make(at: directory, pages: (1...pageCount).map {
                FixtureFolder.Page(String(format: "p%02d.png", $0), number: UInt8($0))
            })
            return directory
        }

        func makeImages(_ name: String, count: Int) throws -> [URL] {
            let directory = temporary.file(name)
            try FixtureFolder.make(at: directory, pages: (1...count).map {
                FixtureFolder.Page(String(format: "i%02d.png", $0), number: UInt8($0))
            })
            return (1...count).map { directory.appendingPathComponent(String(format: "i%02d.png", $0)) }
        }

        /// 本を開いて登録簿へ入れたウインドウを 1 つ作る。
        func openWindow(_ request: BookOpenRequest, isPrivate: Bool = false) async -> AppState {
            let state = makeAppState(isPrivate: isPrivate)
            state.open(request: request)
            await state.openTask?.value
            coordinator.registerOpenAppState(state)
            return state
        }
    }

    // MARK: - 登録

    @Test("同じウインドウを二重に登録しない")
    func registeringTheSameWindowTwiceIsIdempotent() throws {
        let env = try Environment()
        defer { env.close() }
        let state = env.makeAppState()

        env.coordinator.registerOpenAppState(state)
        env.coordinator.registerOpenAppState(state)
        #expect(env.coordinator.allOpenAppStates.count == 1)
    }

    @Test("本を開いていないウインドウ(ウェルカム画面)も一覧には並ぶ")
    func aWindowWithoutABookIsStillListed() throws {
        let env = try Environment()
        defer { env.close() }
        let first = env.makeAppState()
        let second = env.makeAppState()
        env.coordinator.registerOpenAppState(first)
        env.coordinator.registerOpenAppState(second)

        #expect(env.coordinator.allOpenAppStates.count == 2)
        // ただし「この本を開いているウインドウ」としては当たらない。
        #expect(env.coordinator.openAppState(forBookAt: URL(fileURLWithPath: "/x"), isPrivate: false) == nil)
    }

    // MARK: - URL で探す

    @Test("同じ本を開いているウインドウが見つかる")
    func anOpenBookIsFoundByItsURL() async throws {
        let env = try Environment()
        defer { env.close() }
        let url = try env.makeFolder("book")
        let state = await env.openWindow(BookOpenRequest(url))

        #expect(env.coordinator.openAppState(forBookAt: url, isPrivate: false) === state)
    }

    @Test("別の本を開いているウインドウは当たらない")
    func aDifferentBookDoesNotMatch() async throws {
        let env = try Environment()
        defer { env.close() }
        let opened = try env.makeFolder("opened")
        let other = try env.makeFolder("other")
        _ = await env.openWindow(BookOpenRequest(opened))

        #expect(env.coordinator.openAppState(forBookAt: other, isPrivate: false) == nil)
    }

    @Test("性質の違うウインドウは候補にしない(通常 ⇄ シークレット)")
    func aWindowOfTheOtherPrivacyIsNotACandidate() async throws {
        let env = try Environment()
        defer { env.close() }
        let url = try env.makeFolder("book")
        let privateState = await env.openWindow(BookOpenRequest(url), isPrivate: true)

        // シークレットで開いている本を、通常ウインドウの要求で拾ってはいけない。
        #expect(env.coordinator.openAppState(forBookAt: url, isPrivate: false) == nil)
        // シークレットの要求でなら当たる(「シークレットは一律に対象外」ではない)。
        #expect(env.coordinator.openAppState(forBookAt: url, isPrivate: true) === privateState)
    }

    @Test("通常とシークレットが同じ本を開いていても、要求した性質の方だけを返す")
    func eachPrivacyFindsItsOwnWindow() async throws {
        let env = try Environment()
        defer { env.close() }
        let url = try env.makeFolder("book")
        let regular = await env.openWindow(BookOpenRequest(url), isPrivate: false)
        let secret = await env.openWindow(BookOpenRequest(url), isPrivate: true)

        #expect(env.coordinator.openAppState(forBookAt: url, isPrivate: false) === regular)
        #expect(env.coordinator.openAppState(forBookAt: url, isPrivate: true) === secret)
    }

    @Test("複数枚の画像をまとめた本は対象外(先頭の 1 枚を開いても前に出てこない)")
    func aMultiImageBookIsNeverMatched() async throws {
        let env = try Environment()
        defer { env.close() }
        let images = try env.makeImages("images", count: 3)
        let request = try #require(BookOpenRequest(openingCandidates: images))
        let state = await env.openWindow(request)
        #expect(state.currentBook?.isIdentifiedBySourceURL == false)

        // その場限りの本の sourceURL は先頭 1 枚。それで探しても当たらない。
        #expect(env.coordinator.openAppState(forBookAt: images[0], isPrivate: false) == nil)
    }

    @Test("画像 1 枚の本は、他の形式と同じく重複を防ぐ")
    func aSingleImageBookIsMatchedLikeAnyOtherBook() async throws {
        let env = try Environment()
        defer { env.close() }
        let images = try env.makeImages("single", count: 1)
        let state = await env.openWindow(BookOpenRequest(images[0]))
        #expect(state.currentBook?.isIdentifiedBySourceURL == true)
        #expect(env.coordinator.openAppState(forBookAt: images[0], isPrivate: false) === state)
    }

    // MARK: - bookID で探す

    @Test("bookID でも同じウインドウが見つかる")
    func anOpenBookIsFoundByItsBookID() async throws {
        let env = try Environment()
        defer { env.close() }
        let url = try env.makeFolder("book")
        let state = await env.openWindow(BookOpenRequest(url))
        let bookID = try #require(state.currentBook?.id)

        #expect(env.coordinator.openAppState(forBookID: bookID) === state)
        #expect(env.coordinator.openAppState(forBookID: "/books/not-open.cbz") == nil)
    }

    @Test("bookID の側でも、複数枚の画像をまとめた本は対象外")
    func aMultiImageBookIsNotMatchedByBookIDEither() async throws {
        let env = try Environment()
        defer { env.close() }
        let images = try env.makeImages("images-id", count: 3)
        let request = try #require(BookOpenRequest(openingCandidates: images))
        let state = await env.openWindow(request)
        let bookID = try #require(state.currentBook?.id)

        #expect(env.coordinator.openAppState(forBookID: bookID) == nil)
    }

    // MARK: - いま読んでいる本

    @Test("「今読んでいる本」は明示的に設定したものだけが入る")
    func theActiveBookIsSetExplicitly() throws {
        let env = try Environment()
        defer { env.close() }
        let first = env.makeAppState()
        let second = env.makeAppState()
        env.coordinator.registerOpenAppState(first)
        env.coordinator.registerOpenAppState(second)
        // 登録しただけでは決まらない(独立ウインドウがキーになっても変わらないのと同じ理屈)。
        #expect(env.coordinator.activeBookAppState == nil)

        env.coordinator.setActiveBookAppState(first)
        #expect(env.coordinator.activeBookAppState === first)
        env.coordinator.setActiveBookAppState(second)
        #expect(env.coordinator.activeBookAppState === second)
    }

    @Test("起動時の初期化は既定で「まだ」、編集ウインドウの呼び出し元は既定で無指定")
    func theInitialStateIsUntouched() throws {
        let env = try Environment()
        defer { env.close() }
        #expect(!env.coordinator.didPerformInitialLaunchActions)
        #expect(env.coordinator.pendingEditorInitialFocus == nil)
        #expect(env.coordinator.primaryAppState == nil)
        #expect(env.coordinator.allOpenAppStates.isEmpty)
    }
}

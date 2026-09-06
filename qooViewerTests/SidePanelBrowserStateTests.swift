import Foundation
import Testing

@testable import qooViewer

/// サイドパネル上段(フォルダブラウザ)の閲覧状態(ViewModels/SidePanelBrowserState.swift)。
///
/// 見るのは**状態機械の部分** ―― 履歴スタック、上へ移動、本を開いたときの再アンカー、
/// そして読み込みの結果(一覧・「直下に画像があるか」・アクセス権が要るか)。
/// `NSOpenPanel` を出す `requestFolderAccess()` と `NSWorkspace` を叩く `openInFinder()` は
/// 実機側(docs/13 の「実機に残すもの」)。
///
/// 読み込みの待ち合わせは `reloadTask`(テストのための口)。**時間で待たないこと。**
@MainActor
struct SidePanelBrowserStateTests {
    private struct Fixture {
        let temporary: TemporaryDirectory
        let suite: PreferencesSuite
        let preferences: AppPreferences
        let state = SidePanelBrowserState()
        /// `root/inner/leaf` の 3 階層と、`root/images`(画像だけが入るフォルダ)。
        let root: URL
        let inner: URL
        let leaf: URL
        let images: URL

        init(_ label: String) throws {
            temporary = try TemporaryDirectory(label)
            suite = PreferencesSuite(label: label)
            preferences = suite.makePreferences()
            root = try temporary.directory("root")
            inner = try temporary.directory("root/inner")
            leaf = try temporary.directory("root/inner/leaf")
            // フォルダとして作る(末尾に `/` の付く形)。`deletingLastPathComponent()` が返す
            // 親フォルダの URL と、そのまま `==` で比べられるようにするため。
            images = try temporary.directory("root/images")
            try FixtureFolder.make(at: images, pages: [
                .init("001.png", number: 1), .init("002.png", number: 2),
            ])
            state.preferences = preferences
        }

        /// 読み込みが片付くまで待つ。
        func settle() async { await state.reloadTask?.value }

        /// 画像ファイルを**直接**開いた本(`MangaBook.BookOrigin.imageFiles`)。
        /// フォルダとして開くと `.fileSystem` になり、再アンカーの分岐が変わる。
        func makeImageBook() async throws -> MangaBook {
            try await BookLoader.load(imageFiles: [
                images.appendingPathComponent("001.png"),
                images.appendingPathComponent("002.png"),
            ])
        }
    }

    // MARK: - 移動と履歴

    @Test("作りたてはボリューム一覧(currentDirectory は nil)で、どこへも戻れない")
    func afreshStateShowsTheVolumeList() async throws {
        let fixture = try Fixture("browser-fresh")
        await fixture.settle()
        #expect(fixture.state.currentDirectory == nil)
        #expect(!fixture.state.canGoBack)
        #expect(!fixture.state.canGoForward)
        #expect(!fixture.state.canGoUp)
    }

    @Test("フォルダへ入ると、そこが現在地になり、戻れるようになる")
    func navigatingPushesTheHistory() async throws {
        let fixture = try Fixture("browser-navigate")
        await fixture.settle()

        fixture.state.navigate(into: fixture.root)
        await fixture.settle()
        #expect(fixture.state.currentDirectory == fixture.root)
        #expect(fixture.state.canGoBack)
        #expect(fixture.state.canGoUp)
        #expect(!fixture.state.canGoForward)
        // 入った先は「元いた場所を指し示す」対象を持たない。
        #expect(fixture.state.highlightedURL == nil)
    }

    @Test("戻る・進むが履歴を往復する")
    func backAndForwardWalkTheHistory() async throws {
        let fixture = try Fixture("browser-backforward")
        await fixture.settle()
        fixture.state.navigate(into: fixture.root)
        await fixture.settle()
        fixture.state.navigate(into: fixture.inner)
        await fixture.settle()

        fixture.state.goBack()
        await fixture.settle()
        #expect(fixture.state.currentDirectory == fixture.root)
        #expect(fixture.state.canGoForward)

        fixture.state.goBack()
        await fixture.settle()
        #expect(fixture.state.currentDirectory == nil)   // ボリューム一覧まで戻る
        #expect(!fixture.state.canGoBack)

        fixture.state.goForward()
        await fixture.settle()
        #expect(fixture.state.currentDirectory == fixture.root)
        fixture.state.goForward()
        await fixture.settle()
        #expect(fixture.state.currentDirectory == fixture.inner)
        #expect(!fixture.state.canGoForward)
    }

    @Test("戻った先から新しく移動すると、進む先は捨てられる")
    func navigatingAfterGoingBackDropsTheForwardHistory() async throws {
        let fixture = try Fixture("browser-branch")
        await fixture.settle()
        fixture.state.navigate(into: fixture.root)
        await fixture.settle()
        fixture.state.navigate(into: fixture.inner)
        await fixture.settle()
        fixture.state.goBack()
        await fixture.settle()
        #expect(fixture.state.canGoForward)

        fixture.state.navigate(into: fixture.images)
        await fixture.settle()
        #expect(!fixture.state.canGoForward)
        #expect(fixture.state.currentDirectory == fixture.images)
    }

    @Test("行き止まりでは何も起きない(空の履歴で戻る・進むを押しても現在地が変わらない)")
    func walkingPastTheEndsIsANoOp() async throws {
        let fixture = try Fixture("browser-ends")
        await fixture.settle()
        fixture.state.goBack()
        fixture.state.goForward()
        await fixture.settle()
        #expect(fixture.state.currentDirectory == nil)
        #expect(!fixture.state.canGoBack)
        #expect(!fixture.state.canGoForward)
    }

    // MARK: - 上へ

    @Test("上へ移動すると 1 階層上へ行き、元いたフォルダが指し示される")
    func goingUpHighlightsWhereYouCameFrom() async throws {
        let fixture = try Fixture("browser-up")
        await fixture.settle()
        fixture.state.navigate(into: fixture.leaf)
        await fixture.settle()

        fixture.state.goUp()
        await fixture.settle()
        #expect(fixture.state.currentDirectory == fixture.inner)
        // ユーザー要望: 上へ移動したら元いたフォルダがフォーカスされる。
        #expect(fixture.state.highlightedURL == fixture.leaf)
        #expect(fixture.state.canGoBack)
    }

    @Test("ボリューム一覧では上へ移動できない")
    func goingUpFromTheVolumeListDoesNothing() async throws {
        let fixture = try Fixture("browser-up-top")
        await fixture.settle()
        #expect(!fixture.state.canGoUp)
        fixture.state.goUp()
        await fixture.settle()
        #expect(fixture.state.currentDirectory == nil)
        #expect(!fixture.state.canGoBack)
    }

    // MARK: - 本を開いたときの再アンカー

    @Test("本を開くと、その親フォルダを表示して本自身を指し示す")
    func openingABookAnchorsToItsParent() async throws {
        let fixture = try Fixture("browser-anchor")
        await fixture.settle()
        let temporary = try TemporaryDirectory("browser-anchor-book")
        let directory = temporary.file("shelf/book")
        try FixtureFolder.make(at: directory, pages: [.init("001.png", number: 1)])
        let book = try await FixtureBook.load(directory)

        fixture.state.handlePanelRevealed(currentBook: book)
        await fixture.settle()
        #expect(fixture.state.currentDirectory == directory.deletingLastPathComponent())
        #expect(fixture.state.highlightedURL == book.sourceURL)
    }

    @Test("画像を直接開いた本は**もう 1 階層上**を表示し、画像の入ったフォルダを指し示す")
    func anImageBookAnchorsOneLevelHigher() async throws {
        let fixture = try Fixture("browser-anchor-images")
        await fixture.settle()
        let book = try await fixture.makeImageBook()
        #expect(book.origin == .imageFiles)

        // 一覧は画像ファイルを行に出さないので、画像フォルダをそのまま表示すると空に見える。
        // 1 階層上なら、その画像フォルダ自体が「1 冊の本」として行に並ぶ(ユーザー要望)。
        fixture.state.handlePanelRevealed(currentBook: book)
        await fixture.settle()
        #expect(fixture.state.currentDirectory == fixture.root)
        #expect(fixture.state.highlightedURL == fixture.images)
    }

    @Test("本を開いていなければ、今いる場所を保つ(ウェルカム画面で毎回先頭へ戻されない)")
    func noBookLeavesTheBrowserWhereItIs() async throws {
        let fixture = try Fixture("browser-anchor-none")
        await fixture.settle()
        fixture.state.navigate(into: fixture.inner)
        await fixture.settle()

        fixture.state.handlePanelRevealed(currentBook: nil)
        await fixture.settle()
        #expect(fixture.state.currentDirectory == fixture.inner)
    }

    @Test("パネルの中のクリックで開いた本は、再アンカーを 1 回だけ見送る")
    func aClickInsideThePanelSkipsTheNextAnchor() async throws {
        let fixture = try Fixture("browser-skip")
        await fixture.settle()
        let book = try await fixture.makeImageBook()

        // フォルダ行のクリックは「入る」と「開く」を同時に行う。ここで再アンカーすると、
        // せっかく入ったフォルダから親へ弾き返される。
        fixture.state.navigate(into: fixture.images)
        await fixture.settle()
        fixture.state.skipNextAnchorOnce()
        fixture.state.handlePanelRevealed(currentBook: book)
        await fixture.settle()
        #expect(fixture.state.currentDirectory == fixture.images)

        // 見送るのは 1 回だけ。次からは通常どおり再アンカーする。
        fixture.state.handlePanelRevealed(currentBook: book)
        await fixture.settle()
        #expect(fixture.state.currentDirectory == fixture.root)
    }

    @Test("同じフォルダへの再アンカーでは履歴を積まない")
    func reAnchoringToTheSameFolderDoesNotPushHistory() async throws {
        let fixture = try Fixture("browser-anchor-same")
        await fixture.settle()
        let book = try await fixture.makeImageBook()

        fixture.state.handlePanelRevealed(currentBook: book)
        await fixture.settle()
        fixture.state.goBack()          // さっき積んだぶんを消費する
        await fixture.settle()
        fixture.state.handlePanelRevealed(currentBook: book)
        await fixture.settle()
        let depthAfterFirst = fixture.state.canGoBack

        fixture.state.handlePanelRevealed(currentBook: book)  // 同じ場所へもう一度
        await fixture.settle()
        #expect(fixture.state.canGoBack == depthAfterFirst)
        #expect(fixture.state.currentDirectory == fixture.root)
    }

    // MARK: - 読み込みの結果

    @Test("一覧にはサブフォルダが並び、画像ファイルは行にならない")
    func theListingShowsFoldersAndNotImages() async throws {
        let fixture = try Fixture("browser-listing")
        await fixture.settle()
        fixture.state.navigate(into: fixture.root)
        await fixture.settle()

        let names = Set(fixture.state.entries.map(\.url.lastPathComponent))
        #expect(names == ["inner", "images"])
        #expect(!fixture.state.needsFolderAccessGrant)
    }

    @Test("「直下に画像がある」は、その導線を出すためだけの印(一覧の中身とは別)")
    func theHasImagesFlagFollowsTheCurrentFolder() async throws {
        let fixture = try Fixture("browser-hasimages")
        await fixture.settle()

        // 画像だけのフォルダ ―― 一覧は空になるが、行き止まりではないことを示す。
        fixture.state.navigate(into: fixture.images)
        await fixture.settle()
        #expect(fixture.state.entries.isEmpty)
        #expect(fixture.state.currentDirectoryHasImages)

        // サブフォルダだけのフォルダには印が付かない。
        fixture.state.navigate(into: fixture.inner)
        await fixture.settle()
        #expect(!fixture.state.currentDirectoryHasImages)
    }

    @Test("読めないフォルダは、空フォルダとは区別してアクセス権の要求として扱う")
    func anUnreadableFolderAsksForAccessInsteadOfLookingEmpty() async throws {
        let fixture = try Fixture("browser-denied")
        await fixture.settle()
        // 実在しない場所は列挙が失敗する ―― パネルは「その場から許可する」ボタンを出す。
        fixture.state.navigate(into: fixture.temporary.file("does-not-exist"))
        await fixture.settle()
        #expect(fixture.state.entries.isEmpty)
        #expect(fixture.state.needsFolderAccessGrant)
        #expect(!fixture.state.currentDirectoryHasImages)

        // 読める場所へ移れば印は下りる。
        fixture.state.navigate(into: fixture.root)
        await fixture.settle()
        #expect(!fixture.state.needsFolderAccessGrant)
    }

    @Test("並べ替え設定を変えると、ディスクを読み直さずに今の一覧を並べ替える")
    func changingTheSortReordersWithoutReloading() async throws {
        let fixture = try Fixture("browser-sort")
        await fixture.settle()
        fixture.state.navigate(into: fixture.root)
        await fixture.settle()
        let ascending = fixture.state.entries.map(\.url.lastPathComponent)

        fixture.preferences.folderBrowserSortDirection = .descending
        fixture.state.applySortSettings()
        #expect(fixture.state.entries.map(\.url.lastPathComponent) == ascending.reversed())

        // 設定が変わっていなければ何もしない(呼び出し側が気軽に呼べる)。
        fixture.state.applySortSettings()
        #expect(fixture.state.entries.map(\.url.lastPathComponent) == ascending.reversed())
    }
}

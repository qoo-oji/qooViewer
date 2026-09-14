import AppKit
import Foundation
import Testing

@testable import qooViewer

/// ファイルブラウザと既存機能の接続(改善要望7 段階 8)。
///
/// - 「ファイルブラウザで開く」: 出す場所(このウインドウ / 新しいタブ・ウインドウ)と、何を見せるか(フォルダの中 / 入っている
///   フォルダで選ぶ)。新しいウインドウへ渡す値の往復と、受け取ったウインドウがその項目を選ぶこと。
/// - 右クリックの「コレクションを作成」「コレクションに登録」「メタデータの編集…」「本の書き出し」「このアプリケーションで開く」の
///   淡色の判定と、選んだときの振り分け(画像フォルダかどうかは選んだときに調べる)。
///
/// 待ち合わせは各操作が返す Task(テストのための口)と `settle()`。時間では待たない。
@MainActor
struct FileBrowserIntegrationTests {
    private struct Fixture {
        let temporary: TemporaryDirectory
        let suite: PreferencesSuite
        let preferences: AppPreferences
        let library: InMemoryLibrary
        let welcome: WelcomeLibraryState
        let state: FileBrowserState
        let appState: AppState
        let actions = FileBrowserActions()
        let presenter = FileBrowserOperationsTests.ScriptedPresenter()

        init(_ label: String, isPrivate: Bool = false) throws {
            temporary = try TemporaryDirectory(label)
            suite = PreferencesSuite(label: label)
            preferences = suite.makePreferences()
            library = try InMemoryLibrary(label: label)
            welcome = WelcomeLibraryState(defaults: suite.defaults, restoresMode: false)
            state = FileBrowserState(defaults: suite.defaults)
            state.preferences = preferences
            state.isPrivate = isPrivate
            state.operations.presenter = presenter
            appState = AppState(isPrivateWindow: isPrivate, usesPageListCache: false)
            appState.preferences = preferences
            appState.fileBrowser = state
            appState.welcomeLibrary = welcome
            actions.state = state
            actions.appState = appState
            actions.preferences = preferences
            actions.collectionStore = library.collections
            actions.bookmarkStore = library.bookmarks
            actions.layoutStore = library.layouts
            actions.metadataStore = library.metadata
        }

        func close() {
            state.releaseResources()
            library.close()
        }

        func entry(_ url: URL) -> FileBrowserEntry {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            return FileBrowserEntry(
                url: url, displayName: url.lastPathComponent, isDirectory: isDirectory, isPackage: false,
                isSymbolicLink: false, isVolume: false, fileSize: nil, typeDescription: nil, creationDate: nil,
                modificationDate: nil
            )
        }

        func archive(_ relativePath: String, number: UInt8 = 1) throws -> URL {
            let url = temporary.file(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var builder = ZipFixtureBuilder()
            builder.add("001.png", PageImageFactory.png(number: number))
            try builder.write(to: url)
            return url
        }

        func imageFolder(_ relativePath: String) throws -> URL {
            let url = temporary.file(relativePath)
            try FixtureFolder.make(at: url, pages: [.init("p01.png", number: 1), .init("p02.png", number: 2)])
            return url
        }
    }

    // MARK: - ファイルブラウザで開く

    @Test("本を開いていないウインドウはそのウインドウで、開いているウインドウは環境設定の行き先で開く")
    func revealPlacementFollowsOpenBookAndPreference() {
        #expect(FileBrowserReveal.placement(hasOpenBook: false, preference: .newPrivateWindow) == .thisWindow)
        #expect(FileBrowserReveal.placement(hasOpenBook: true, preference: .newTab) == .newWindow(.newTab))
        #expect(FileBrowserReveal.placement(hasOpenBook: true, preference: .newNormalWindow) == .newWindow(.newNormalWindow))
        #expect(FileBrowserReveal.placement(hasOpenBook: true, preference: .newPrivateWindow) == .newWindow(.newPrivateWindow))
        // 既定は新規タブ(決定事項 Q6)。
        let suite = PreferencesSuite(label: "fb-reveal-default")
        #expect(suite.makePreferences().fileBrowserRevealDestination == .newTab)
    }

    @Test("フォルダはその中を、ファイルは入っているフォルダでその項目を選ぶ(Finder で開くと同じ)")
    func revealTargetMatchesFinderReveal() {
        let folder = URL(fileURLWithPath: "/tmp/qoo-reveal/shelf", isDirectory: true)
        let file = URL(fileURLWithPath: "/tmp/qoo-reveal/shelf/book.cbz")
        #expect(FileBrowserReveal.target(for: folder, isDirectory: true)
                == .init(folder: FileBrowserState.folderURL(folder), selecting: nil))
        let fileTarget = FileBrowserReveal.target(for: file, isDirectory: false)
        #expect(fileTarget.folder?.path == folder.path)
        #expect(fileTarget.selecting == file)
    }

    @Test("新しいウインドウへは、フォルダと選ぶ項目を一緒に渡す(Codable で往復する)")
    func browseRequestCarriesSelection() throws {
        let folder = URL(fileURLWithPath: "/tmp/qoo-reveal", isDirectory: true)
        let item = URL(fileURLWithPath: "/tmp/qoo-reveal/book.cbz")
        let request = WindowContentRequest.browse(folder, selecting: item)
        let decoded = try JSONDecoder().decode(WindowContentRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
        #expect(decoded.browsedFolder?.path == folder.path)
        #expect(decoded.browsedSelection == item)
        #expect(WindowContentRequest.browse(folder).browsedSelection == nil)
    }

    @Test("出ていないときに頼まれた項目は、次に出たときにそのフォルダで選ばれる。出ていればその場で移る")
    func showWaitsUntilVisibleThenRevealsTheItem() async throws {
        let fixture = try Fixture("fb-reveal-show")
        defer { fixture.close() }
        let book = try fixture.archive("shelf/book.cbz")
        let shelf = book.deletingLastPathComponent()
        let other = try fixture.temporary.directory("other")

        fixture.state.show(book, isDirectory: false)
        #expect(fixture.state.currentFolder == nil)
        fixture.state.activate()
        await fixture.state.settle()
        #expect(FileBrowserState.id(of: fixture.state.currentFolder) == FileBrowserState.id(for: shelf))
        #expect(fixture.state.selection == [FileBrowserState.id(for: book)])

        // 出ている間はその場で(フォルダはその中へ)。
        fixture.state.show(other, isDirectory: true)
        await fixture.state.settle()
        #expect(FileBrowserState.id(of: fixture.state.currentFolder) == FileBrowserState.id(for: other))
        #expect(fixture.state.selection.isEmpty)
        #expect(fixture.state.canGoBack)
    }

    @Test("新しいウインドウで受け取った「選ぶ項目」も、出たときに選ばれる")
    func preparedSelectionIsRevealedOnActivate() async throws {
        let fixture = try Fixture("fb-reveal-prepare")
        defer { fixture.close() }
        let book = try fixture.archive("shelf/book.cbz")
        let shelf = book.deletingLastPathComponent()
        fixture.state.prepare(showing: shelf, selecting: book)
        fixture.state.activate()
        await fixture.state.settle()
        #expect(FileBrowserState.id(of: fixture.state.currentFolder) == FileBrowserState.id(for: shelf))
        #expect(fixture.state.selection == [FileBrowserState.id(for: book)])
    }

    @Test("本を開いていないウインドウでは、ウェルカム画面がファイルブラウザに切り替わり、編集モードは畳まれる")
    func revealInThisWindowSwitchesTheWelcomeMode() async throws {
        let fixture = try Fixture("fb-reveal-this-window")
        defer { fixture.close() }
        let book = try fixture.archive("shelf/book.cbz")
        fixture.welcome.isEditing = true
        #expect(fixture.welcome.mode == .shelf)

        fixture.appState.showInFileBrowser(book, isDirectory: false, openWindow: nil)
        #expect(fixture.welcome.mode == .browser)
        #expect(!fixture.welcome.isEditing)
        fixture.state.activate()
        await fixture.state.settle()
        #expect(fixture.state.selection == [FileBrowserState.id(for: book)])
    }

    // MARK: - 右クリックの判定

    @Test("コレクション・メタデータはシークレットウインドウで淡色、書き出しは使える。画像1枚・複数選択は1冊用の項目が淡色")
    func libraryMenuAvailability() throws {
        let normal = try Fixture("fb-menu-normal")
        defer { normal.close() }
        let secret = try Fixture("fb-menu-private", isPrivate: true)
        defer { secret.close() }
        let book = normal.entry(try normal.archive("book.cbz"))
        let folder = normal.entry(try normal.temporary.directory("folder"))
        let image = normal.temporary.file("page.png")
        try PageImageFactory.png(number: 1).write(to: image)
        let imageEntry = normal.entry(image)

        func enabled(_ command: FileBrowserMenuCommand, _ entries: [FileBrowserEntry], in fixture: Fixture) -> Bool {
            command.isEnabled(
                in: FileBrowserMenuContext(kind: .of(entries[0]), entries: entries, folder: nil), actions: fixture.actions
            )
        }

        for command in [FileBrowserMenuCommand.createCollection, .addToCollection, .editMetadata, .exportBook, .openWith] {
            #expect(enabled(command, [book], in: normal), "\(command)")
        }
        // フォルダは選ぶまで本かどうか分からないので淡色にしない。
        #expect(enabled(.createCollection, [folder], in: normal))
        #expect(enabled(.editMetadata, [folder], in: normal))
        // 画像ファイル 1 枚は本にしない。
        #expect(!enabled(.createCollection, [imageEntry], in: normal))
        #expect(!enabled(.exportBook, [imageEntry], in: normal))
        #expect(enabled(.openWith, [imageEntry], in: normal))
        // 1 冊用の項目は複数選択で淡色、コレクションはまとめて扱える。
        #expect(!enabled(.editMetadata, [book, folder], in: normal))
        #expect(!enabled(.exportBook, [book, folder], in: normal))
        #expect(enabled(.addToCollection, [book, folder], in: normal))
        // シークレットウインドウ。
        #expect(!enabled(.createCollection, [book], in: secret))
        #expect(!enabled(.addToCollection, [book], in: secret))
        #expect(!enabled(.editMetadata, [book], in: secret))
        #expect(enabled(.exportBook, [book], in: secret))
    }

    @Test("「コレクションに登録」はライブラリが1つなら1段、「本の書き出し」は3形式。コレクションが増えると並びも変わる")
    func dynamicSubmenus() throws {
        let fixture = try Fixture("fb-menu-dynamic")
        defer { fixture.close() }
        let book = try fixture.archive("book.cbz")
        let target = try #require(fixture.library.collections.libraries.first)
        let context = FileBrowserMenuContext(kind: .file, entries: [fixture.entry(book)], folder: nil)
        let english = Locale(identifier: "en")

        func titles(_ command: FileBrowserMenuCommand) -> [String] {
            (command.dynamicChildren(in: context, actions: fixture.actions, locale: english) ?? []).compactMap {
                if case .item(let title, _, _, _) = $0 { return title }
                if case .submenu(let title, _, _) = $0 { return title }
                return nil
            }
        }

        #expect(titles(.addToCollection) == ["No Collections"])
        let pending = CollectionStore.makePendingItem(for: book).map { [$0] } ?? []
        #expect(fixture.library.collections.createCollection(name: "Shelf B", in: target, items: pending) != nil)
        #expect(fixture.library.collections.createCollection(name: "Shelf A", in: target, items: pending) != nil)
        #expect(titles(.addToCollection) == ["Shelf A", "Shelf B"])
        #expect(titles(.exportBook) == ["Export This Book as EPUB", "Export This Book as PDF", "Export This Book as CBZ"])
        #expect(FileBrowserMenuCommand.copy.dynamicChildren(in: context, actions: fixture.actions, locale: english) == nil)
        // 「このアプリケーションで開く」の末尾は必ず「その他…」。
        #expect(titles(.openWith).last == "Other…")
    }

    // MARK: - 選んだとき

    @Test("「コレクションを作成」はドロップと同じ振り分けで名前の入力待ちを積む。本にならないものだけなら伝える")
    func createCollectionQueuesPendingCreations() async throws {
        let fixture = try Fixture("fb-create-collection")
        defer { fixture.close() }
        let loose = try fixture.archive("loose.cbz", number: 1)
        let shelfBook = try fixture.archive("Shelf/01.cbz", number: 2)
        let shelf = shelfBook.deletingLastPathComponent()

        await fixture.actions.createCollection(from: [fixture.entry(loose), fixture.entry(shelf)])?.value
        #expect(fixture.welcome.pendingCreations.count == 2)
        #expect(fixture.welcome.pendingCreations.first?.books == [loose])
        #expect(fixture.welcome.pendingCreations.last?.defaultName == "Shelf")
        #expect(fixture.welcome.pendingCreations.map(\.fromDrop) == [true, true])
        #expect(fixture.presenter.problems.isEmpty)

        fixture.welcome.pendingCreations = []
        let empty = try fixture.temporary.directory("empty")
        await fixture.actions.createCollection(from: [fixture.entry(empty)])?.value
        #expect(fixture.welcome.pendingCreations.isEmpty)
        #expect(fixture.presenter.problems.count == 1)
    }

    @Test("「コレクションに登録」は棚を中の本へ展開して足し、同じ本は二重に入れない")
    func addToCollectionExpandsShelves() async throws {
        let fixture = try Fixture("fb-add-to-collection")
        defer { fixture.close() }
        let first = try fixture.archive("Shelf/01.cbz", number: 1)
        let second = try fixture.archive("Shelf/02.cbz", number: 2)
        let shelf = first.deletingLastPathComponent()
        let target = try #require(fixture.library.collections.libraries.first)
        let firstItem = try #require(CollectionStore.makePendingItem(for: first))
        let collection = try #require(fixture.library.collections.createCollection(
            name: "Shelf", in: target, items: [firstItem]
        ))

        await fixture.actions.addToCollection([fixture.entry(shelf)], collectionID: collection.id)?.value
        #expect(fixture.presenter.problems.isEmpty)
        let items = { fixture.library.collections.items(in: collection, sort: .nameAscending) }
        #expect(Set(items().map(\.bookID)) == [first.path, second.path])
        await fixture.actions.addToCollection([fixture.entry(second)], collectionID: collection.id)?.value
        #expect(items().count == 2)
    }

    @Test("シークレットウインドウでは、コレクションにもメタデータにも手を付けない")
    func privateWindowDoesNotWriteLibraryData() async throws {
        let fixture = try Fixture("fb-private-library", isPrivate: true)
        defer { fixture.close() }
        let book = try fixture.archive("book.cbz")
        #expect(fixture.actions.createCollection(from: [fixture.entry(book)]) == nil)
        #expect(fixture.actions.editMetadata([fixture.entry(book)]) == nil)
        #expect(fixture.welcome.pendingCreations.isEmpty)
        #expect(fixture.state.bookSheet == nil)
    }

    @Test("「メタデータの編集…」は書庫ならその場で、画像フォルダは調べてからシートを出す。棚のフォルダは本ではないと伝える")
    func editMetadataResolvesImageFolders() async throws {
        let fixture = try Fixture("fb-edit-metadata")
        defer { fixture.close() }
        let book = try fixture.archive("book.cbz")
        #expect(fixture.actions.editMetadata([fixture.entry(book)]) == nil)
        guard case .metadata(let url)? = fixture.state.bookSheet?.kind else {
            Issue.record("メタデータのシートが出ていない")
            return
        }
        #expect(url == book)

        fixture.state.bookSheet = nil
        let folder = try fixture.imageFolder("pictures")
        await fixture.actions.editMetadata([fixture.entry(folder)])?.value
        guard case .metadata(let folderURL)? = fixture.state.bookSheet?.kind else {
            Issue.record("画像フォルダでシートが出ていない")
            return
        }
        #expect(folderURL.path == folder.path)

        fixture.state.bookSheet = nil
        let shelf = try fixture.archive("Shelf/01.cbz").deletingLastPathComponent()
        await fixture.actions.editMetadata([fixture.entry(shelf)])?.value
        #expect(fixture.state.bookSheet == nil)
        #expect(fixture.presenter.problems.count == 1)
    }

    // MARK: - このアプリケーションで開く

    @Test("候補は既定のアプリが先頭、残りは名前順。同じアプリの複製と qooViewer 自身は除く")
    func openWithCandidatesAreArranged() {
        func app(_ path: String, _ name: String, _ id: String?) -> OpenWithApplications.Candidate {
            .init(url: URL(fileURLWithPath: path), name: name, bundleIdentifier: id)
        }
        let preview = app("/System/Applications/Preview.app", "Preview", "com.apple.Preview")
        let copy = app("/opt/copies/Preview.app", "Preview", "com.apple.Preview")
        let zeta = app("/Applications/Zeta.app", "Zeta", "example.zeta")
        let alpha = app("/Applications/alpha.app", "alpha", "example.alpha")
        let me = app("/Applications/qooViewer.app", "qooViewer", "example.me")
        let noID = app("/Applications/Old.app", "Old", nil)

        let arranged = OpenWithApplications.arrange(
            [zeta, copy, preview, me, alpha, noID], default: preview, excludingBundleIdentifier: "example.me"
        )
        #expect(arranged.map(\.name) == ["Preview", "alpha", "Old", "Zeta"])
        #expect(arranged.map(\.isDefault) == [true, false, false, false])
        #expect(arranged.first?.url == preview.url)

        // 既定のアプリが qooViewer 自身なら、先頭に既定は来ない。
        let withoutDefault = OpenWithApplications.arrange([alpha, me], default: me, excludingBundleIdentifier: "example.me")
        #expect(withoutDefault.map(\.name) == ["alpha"])
        #expect(withoutDefault.allSatisfy { !$0.isDefault })
    }

    @Test("候補は拡張子ごとに覚える(拡張子の無いファイルはパスごと)")
    func openWithCacheKeys() {
        let a = OpenWithApplications.cacheKey(for: URL(fileURLWithPath: "/x/a.CBZ"), isDirectory: false)
        let b = OpenWithApplications.cacheKey(for: URL(fileURLWithPath: "/y/b.cbz"), isDirectory: false)
        #expect(a == b)
        #expect(OpenWithApplications.cacheKey(for: URL(fileURLWithPath: "/x/README"), isDirectory: false)
                != OpenWithApplications.cacheKey(for: URL(fileURLWithPath: "/y/README"), isDirectory: false))
        #expect(OpenWithApplications.cacheKey(for: URL(fileURLWithPath: "/x/folder"), isDirectory: true)
                != OpenWithApplications.cacheKey(for: URL(fileURLWithPath: "/x/folder"), isDirectory: false))
    }
}

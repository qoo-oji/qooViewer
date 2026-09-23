import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

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
            // 読み取り専用モードは切っておく(既定は ON。ON のときは readOnlyMenuAvailability)。
            preferences.fileBrowserReadOnly = false
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

    // MARK: - 画像フォルダをダブルクリックで開く

    @Test("画像フォルダを本として開くのは、ダブルクリックなら「ビューアで開く」のとき、右クリックの「開く」ならその反対。既定はフォルダを開く")
    func imageFolderOpenActionDecidesDoubleClickAndMenu() {
        #expect(!FileBrowserImageFolderOpenAction.openFolder.opensAsBook(fromMenu: false))
        #expect(FileBrowserImageFolderOpenAction.openFolder.opensAsBook(fromMenu: true))
        #expect(FileBrowserImageFolderOpenAction.openInViewer.opensAsBook(fromMenu: false))
        #expect(!FileBrowserImageFolderOpenAction.openInViewer.opensAsBook(fromMenu: true))
        let suite = PreferencesSuite(label: "fb-image-folder-open-default")
        #expect(suite.makePreferences().fileBrowserImageFolderOpenAction == .openFolder)
    }

    /// 本として開く側(`appState.open`)はテストでは通さない(本を読み込むと共有の履歴に触れうる)。ここで確かめるのは
    /// 「中へ移動する側は調べずにすぐ移動する」「本として開く側でも、本でないフォルダは中へ移動する」の 2 つ。
    @Test("中へ移動する側は画像フォルダでもすぐ移動し、本として開く側でも本でないフォルダは調べた後に中へ移動する")
    func openingFoldersFollowsImageFolderOpenAction() async throws {
        let fixture = try Fixture("fb-image-folder-open")
        defer { fixture.close() }
        let imageFolder = try fixture.imageFolder("root/Pictures")
        let shelf = fixture.temporary.file("root/Shelf")
        _ = try fixture.archive("root/Shelf/book.cbz")

        // 既定(フォルダを開く): ダブルクリックは画像フォルダでも調べずに移動する。
        #expect(fixture.actions.open([fixture.entry(imageFolder)]) == nil)
        #expect(FileBrowserState.id(of: fixture.state.currentFolder) == FileBrowserState.id(for: imageFolder))

        // 既定: 右クリックの「開く」は調べる側。本でないフォルダ(棚)なら中へ移動する。
        let menuTask = fixture.actions.openFromMenu([fixture.entry(shelf)])
        #expect(menuTask != nil)
        await menuTask?.value
        #expect(FileBrowserState.id(of: fixture.state.currentFolder) == FileBrowserState.id(for: shelf))

        // ビューアで開く: 右クリックの「開く」は画像フォルダでも調べずに移動する。
        fixture.preferences.fileBrowserImageFolderOpenAction = .openInViewer
        #expect(fixture.actions.openFromMenu([fixture.entry(imageFolder)]) == nil)
        #expect(FileBrowserState.id(of: fixture.state.currentFolder) == FileBrowserState.id(for: imageFolder))

        // ビューアで開く: ダブルクリックは調べる側。本でないフォルダなら中へ移動する。
        let doubleClickTask = fixture.actions.open([fixture.entry(shelf)])
        #expect(doubleClickTask != nil)
        await doubleClickTask?.value
        #expect(FileBrowserState.id(of: fixture.state.currentFolder) == FileBrowserState.id(for: shelf))
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

    @Test("環境設定「ファイルブラウザを有効にする」がOFFなら、「ファイルブラウザで開く」は何もしない(ホームは本棚のまま)")
    func revealDoesNothingWhileTheFileBrowserIsOff() throws {
        let fixture = try Fixture("fb-reveal-feature-off")
        defer { fixture.close() }
        let book = try fixture.archive("shelf/book.cbz")
        fixture.preferences.fileBrowserFeatureEnabled = false
        fixture.welcome.isFileBrowserFeatureEnabled = false
        fixture.welcome.isEditing = true

        fixture.appState.showInFileBrowser(book, isDirectory: false, openWindow: nil)
        #expect(fixture.welcome.mode == .shelf)
        #expect(fixture.welcome.isEditing)
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

    @Test("読み取り専用モードでは、ファイルを変える右クリックの項目とキーの操作が淡色。開く・コピー・コレクション・メタデータ・書き出しは使える")
    func readOnlyMenuAvailability() throws {
        let fixture = try Fixture("fb-menu-readonly")
        defer { fixture.close() }
        let book = fixture.entry(try fixture.archive("book.cbz"))
        let folder = try fixture.temporary.directory("dest")
        let pasteboard = NSPasteboard.withUniqueName()
        fixture.state.operations.pasteboard = pasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects([book.url as NSURL])

        func enabled(_ command: FileBrowserMenuCommand, kind: FileBrowserMenuKind = .file) -> Bool {
            command.isEnabled(
                in: FileBrowserMenuContext(kind: kind, entries: kind == .background ? [] : [book], folder: folder),
                actions: fixture.actions
            )
        }
        let changing: [FileBrowserMenuCommand] = [
            .rename, .cut, .paste, .moveToTrash, .compress, .compressHere, .compressTo,
            .extract, .extractHere, .extractToFolder, .extractTo, .alwaysOpenWith,
        ]
        let keeping: [FileBrowserMenuCommand] = [
            .open, .openInNewTab, .createCollection, .addToCollection, .openWith, .copy, .copyPathname,
            .editMetadata, .exportBook, .showInFinder, .getInfo,
        ]
        for command in changing + keeping { #expect(enabled(command), "OFF: \(command)") }
        #expect(enabled(.newFolder, kind: .background))
        #expect(fixture.actions.allowsFileChanges)

        fixture.preferences.fileBrowserReadOnly = true
        for command in changing { #expect(!enabled(command), "ON: \(command)") }
        for command in keeping { #expect(enabled(command), "ON: \(command)") }
        #expect(!enabled(.newFolder, kind: .background))
        #expect(!enabled(.paste, kind: .background))
        #expect(!fixture.actions.allowsFileChanges)
        // 項目の数は変えない(淡色にするだけ)。
        #expect(FileBrowserMenuCommand.groups(for: .file).flatMap { $0 }.contains(.moveToTrash))

        // キー・編集メニューの口(選択・表示中のフォルダによらず、読み取り専用なら断る)。
        #expect(!fixture.actions.canPerform(.cut))
        #expect(!fixture.actions.canPerform(.paste))
        #expect(!fixture.actions.canPerform(.moveItemHere))
        #expect(!fixture.actions.canPerform(.moveToTrash))
    }

    @Test("「開く」は開いて何かが起きるときだけ押せる: 1 件なら何でも、複数ならフォルダ・リンクを含まないときだけ(2026-09-19)")
    func openAvailabilityMatchesOpen() throws {
        let fixture = try Fixture("fb-menu-open")
        defer { fixture.close() }
        let folderA = fixture.entry(try fixture.temporary.directory("a"))
        let folderB = fixture.entry(try fixture.temporary.directory("b"))
        let book = fixture.entry(try fixture.archive("book.cbz"))
        let other = fixture.entry(try fixture.archive("other.cbz", number: 2))
        let textURL = fixture.temporary.file("notes.txt")
        try Data("x".utf8).write(to: textURL)
        let text = fixture.entry(textURL)
        let link = FileBrowserEntry(
            url: fixture.temporary.file("link"), displayName: "link", isDirectory: false, isPackage: false,
            isSymbolicLink: true, isVolume: false, fileSize: nil, typeDescription: nil, creationDate: nil, modificationDate: nil
        )

        func enabled(_ entries: [FileBrowserEntry]) -> Bool {
            FileBrowserMenuCommand.open.isEnabled(
                in: FileBrowserMenuContext(kind: .file, entries: entries, folder: nil), actions: fixture.actions
            )
        }
        // 1 件: フォルダ・本・ふつうのファイル(既定のアプリ)・リンク(中へ)のどれでも開ける。
        #expect(enabled([folderA]))
        #expect(enabled([book]))
        #expect(enabled([text]))
        #expect(enabled([link]))
        // 複数: 本とファイルはまとめて開ける。フォルダ・リンクを含むと中へ入れないので淡色(以前は押せて何も起きなかった)。
        #expect(enabled([book, other]))
        #expect(enabled([book, text]))
        #expect(!enabled([folderA, folderB]))
        #expect(!enabled([folderA, book]))
        #expect(!enabled([link, book]))
        #expect(!enabled([]))
        // 淡色の条件と開く側の場合分けは同じもの。
        #expect(fixture.actions.canOpen([folderA, folderB]) == enabled([folderA, folderB]))
    }

    @Test("ビューアで開いている本(とそれを含むフォルダ)は、名前の変更・カット・ゴミ箱が淡色。コピー・圧縮は押せる(2026-09-19)")
    func openBookDisablesChanges() throws {
        let fixture = try Fixture("fb-menu-open-book")
        defer { fixture.close() }
        let shelf = try fixture.temporary.directory("shelf")
        let bookURL = try fixture.archive("shelf/book.cbz")
        let book = fixture.entry(bookURL)
        let folder = fixture.entry(shelf)
        let other = fixture.entry(try fixture.archive("other.cbz", number: 2))
        fixture.state.operations.openBookPaths = { [bookURL.path] }

        func enabled(_ command: FileBrowserMenuCommand, _ entries: [FileBrowserEntry]) -> Bool {
            command.isEnabled(in: FileBrowserMenuContext(kind: .file, entries: entries, folder: nil), actions: fixture.actions)
        }
        for command in [FileBrowserMenuCommand.rename, .cut, .moveToTrash] {
            #expect(!enabled(command, [book]), "\(command)")
            #expect(!enabled(command, [folder]), "含むフォルダ: \(command)")
            #expect(enabled(command, [other]), "ほかの本: \(command)")
        }
        #expect(enabled(.copy, [book]))
        #expect(enabled(.compress, [book]))
        // 名前の編集も始めない(打ち終えてから断られていた)。
        #expect(!fixture.actions.canChange([book]))
    }

    @Test("読めないフォルダを表示している間は、ペースト・新規フォルダが淡色(2026-09-19)")
    func unreadableFolderDisablesWrites() async throws {
        let fixture = try Fixture("fb-menu-unreadable")
        defer { fixture.close() }
        let book = fixture.entry(try fixture.archive("book.cbz"))
        let pasteboard = NSPasteboard.withUniqueName()
        fixture.state.operations.pasteboard = pasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects([book.url as NSURL])
        let readable = try fixture.temporary.directory("readable")
        fixture.state.navigate(to: readable)
        await fixture.state.settle()
        #expect(fixture.actions.canCreateFolder(in: readable))
        #expect(fixture.actions.canPaste(into: readable))

        // 読めないフォルダ(権限が無い)。見つからないフォルダは祖先へ移るので読み込みの失敗にならない。
        let locked = try fixture.temporary.directory("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        fixture.state.navigate(to: locked)
        await fixture.state.settle()
        try #require(fixture.state.loadError != nil)
        #expect(!fixture.actions.canCreateFolder(in: locked))
        #expect(!fixture.actions.canPaste(into: locked))
        #expect(!fixture.actions.canPerform(.moveItemHere))
        // ツリーの行のフォルダ(右ペインと関係しない)には書ける。
        #expect(fixture.actions.canCreateFolder(in: readable))
    }

    @Test("ペーストボードの写しは、このアプリがファイルを書いたときと確かめ直したときに変わる(2026-09-19)")
    func pasteboardSnapshotFollowsWrites() throws {
        let fixture = try Fixture("fb-pasteboard-snapshot")
        defer { fixture.close() }
        let pasteboard = NSPasteboard.withUniqueName()
        fixture.state.operations.pasteboard = pasteboard
        pasteboard.clearContents()
        fixture.state.refreshPasteboardState()
        #expect(!fixture.state.pasteboardHasFiles)
        let book = fixture.entry(try fixture.archive("book.cbz"))
        fixture.actions.copy([book])
        #expect(fixture.state.pasteboardHasFiles)
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)
        fixture.state.refreshPasteboardState()
        #expect(!fixture.state.pasteboardHasFiles)
    }

    @Test("「よく使う項目に登録」はフォルダだけ。登録済みなら淡色、シークレットウインドウでも淡色。読み取り専用モードでは押せる")
    func addToFavoriteLocations() throws {
        let fixture = try Fixture("fb-menu-favorite")
        defer { fixture.close() }
        let favorites = FavoriteLocationStore(defaults: fixture.suite.defaults)
        fixture.actions.favoriteLocations = favorites
        let folder = fixture.entry(try fixture.temporary.directory("shelf"))
        let other = fixture.entry(try fixture.temporary.directory("other"))
        let book = fixture.entry(try fixture.archive("book.cbz"))

        func enabled(_ entries: [FileBrowserEntry], kind: FileBrowserMenuKind = .folder) -> Bool {
            FileBrowserMenuCommand.addToFavoriteLocations.isEnabled(
                in: FileBrowserMenuContext(kind: kind, entries: entries, folder: nil), actions: fixture.actions
            )
        }

        #expect(FileBrowserMenuCommand.groups(for: .folder).flatMap { $0 }.contains(.addToFavoriteLocations))
        #expect(FileBrowserMenuCommand.groups(for: .tree).flatMap { $0 }.contains(.addToFavoriteLocations))
        #expect(!FileBrowserMenuCommand.groups(for: .file).flatMap { $0 }.contains(.addToFavoriteLocations))

        fixture.preferences.fileBrowserReadOnly = true
        #expect(enabled([folder]))
        #expect(enabled([folder], kind: .tree))
        #expect(!enabled([folder, book]))

        FileBrowserMenuCommand.addToFavoriteLocations.perform(
            in: FileBrowserMenuContext(kind: .folder, entries: [folder], folder: nil), actions: fixture.actions
        )
        #expect(favorites.contains(folder.url))
        #expect(favorites.items.count == 1)
        // 登録済みなら淡色。まだのものが混ざっていれば押せて、足すのはそのぶんだけ。
        #expect(!enabled([folder]))
        #expect(enabled([folder, other]))
        fixture.actions.addToFavoriteLocations([folder, other])
        #expect(favorites.items.count == 2)
        #expect(!enabled([folder, other]))
    }

    @Test("シークレットウインドウでは「よく使う項目に登録」は淡色")
    func addToFavoriteLocationsInPrivateWindow() throws {
        let fixture = try Fixture("fb-menu-favorite-private", isPrivate: true)
        defer { fixture.close() }
        let favorites = FavoriteLocationStore(defaults: fixture.suite.defaults)
        fixture.actions.favoriteLocations = favorites
        let folder = fixture.entry(try fixture.temporary.directory("shelf"))
        #expect(!fixture.actions.canAddToFavoriteLocations([folder]))
        fixture.actions.addToFavoriteLocations([folder])
        #expect(favorites.items.isEmpty)
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
        // ライブラリが 1 つの間、「コレクションを作成」はサブメニューにしない(選ぶものが無い)。
        #expect(FileBrowserMenuCommand.createCollection.dynamicChildren(in: context, actions: fixture.actions, locale: english) == nil)
        let pending = CollectionStore.makePendingItem(for: book).map { [$0] } ?? []
        #expect(fixture.library.collections.createCollection(name: "Shelf B", in: target, items: pending) != nil)
        #expect(fixture.library.collections.createCollection(name: "Shelf A", in: target, items: pending) != nil)
        #expect(titles(.addToCollection) == ["Shelf A", "Shelf B"])
        #expect(titles(.exportBook) == ["Export This Book as EPUB", "Export This Book as PDF", "Export This Book as CBZ"])
        #expect(FileBrowserMenuCommand.copy.dynamicChildren(in: context, actions: fixture.actions, locale: english) == nil)
        // 「このアプリケーションで開く」の末尾は必ず「その他…」。
        #expect(titles(.openWith).last == "Other…")

        // ライブラリが増えると、「コレクションを作成」は作る先のライブラリを選ぶサブメニューになる(名前は本棚の帯と同じ。
        // 既定のライブラリは表示言語の訳)。「コレクションに登録」もライブラリごとの 2 段になる。
        #expect(fixture.library.collections.createLibrary(name: "Second") != nil)
        #expect(titles(.createCollection) == ["Library", "Second"])
        #expect(titles(.addToCollection) == ["Library", "Second"])
        let menu = NSMenu()
        FileBrowserMenuBuilder().rebuild(menu, for: context, actions: fixture.actions, locale: english)
        let createItem = try #require(menu.items.first { $0.title == "Create Collection" })
        #expect(createItem.submenu?.items.map(\.title) == ["Library", "Second"])
    }

    @Test("AppKit のメニューに組んだ場面で変わる項目は、押すと自分の閉包へ届く(NSObject のメソッドを指さない)")
    func appKitDynamicMenuItemsReachTheirActions() throws {
        // 2026-09-14 の実機検証: 項目の action を `perform(_:)` と名付けていたため NSObject の `performSelector:` と
        // ぶつかり、押しても何も起きなかった。
        let fixture = try Fixture("fb-menu-appkit-selector")
        defer { fixture.close() }
        let book = try fixture.archive("book.cbz")
        let context = FileBrowserMenuContext(kind: .file, entries: [fixture.entry(book)], folder: nil)
        let menu = NSMenu()
        let builder = FileBrowserMenuBuilder()
        builder.rebuild(menu, for: context, actions: fixture.actions, locale: Locale(identifier: "en"))

        let exportItem = try #require(menu.items.first { $0.title == "Export Book" })
        let formats = try #require(exportItem.submenu?.items)
        #expect(formats.count == 3)
        for item in formats {
            let action = try #require(item.action)
            let target = try #require(item.target as? NSObject)
            #expect(!NSObject.instancesRespond(to: action), "\(NSStringFromSelector(action))")
            #expect(target.responds(to: action))
        }
    }

    @Test("右クリックの「コピー」「このアプリケーションで開く」のすぐ後ろに、⌥ で入れ替わる項目が付く(見えている項目の数は変わらない)")
    func optionAlternatesFollowTheirPrimaryItems() throws {
        let fixture = try Fixture("fb-menu-alternates")
        defer { fixture.close() }
        let book = try fixture.archive("book.cbz")
        let english = Locale(identifier: "en")
        let builder = FileBrowserMenuBuilder()

        func alternates(_ kind: FileBrowserMenuKind) -> [String: String] {
            let menu = NSMenu()
            let entries = kind == .background ? [] : [fixture.entry(book)]
            builder.rebuild(
                menu, for: FileBrowserMenuContext(kind: kind, entries: entries, folder: nil),
                actions: fixture.actions, locale: english
            )
            var result: [String: String] = [:]
            for (index, item) in menu.items.enumerated() where item.isAlternate {
                #expect(item.keyEquivalentModifierMask == [.option])
                #expect(item.keyEquivalent == menu.items[index - 1].keyEquivalent)
                #expect(!menu.items[index - 1].isAlternate)
                result[menu.items[index - 1].title] = item.title
            }
            // 並びの定義には載せない(⌥ を押していないときの項目の数を変えない)。
            let listed = FileBrowserMenuCommand.groups(for: kind).flatMap { $0 }
            #expect(!listed.contains(.copyPathname) && !listed.contains(.alwaysOpenWith))
            return result
        }
        #expect(alternates(.file) == ["Copy": "Copy as Pathname", "Open With": "Always Open With"])
        #expect(alternates(.folder) == ["Copy": "Copy as Pathname", "Open With": "Always Open With"])
        #expect(alternates(.tree) == ["Open With": "Always Open With"])
        #expect(alternates(.background).isEmpty)

        // 入れ替わる側もサブメニューを持ち、末尾は「その他…」。
        let menu = NSMenu()
        builder.rebuild(
            menu, for: FileBrowserMenuContext(kind: .file, entries: [fixture.entry(book)], folder: nil),
            actions: fixture.actions, locale: english
        )
        let always = try #require(menu.items.first { $0.title == "Always Open With" })
        #expect(always.submenu?.items.last?.title == "Other…")
    }

    @Test("環境設定「ライブラリを有効にする」がOFFなら、右クリックにコレクションの項目が無く、操作の入り口でも断る")
    func libraryFeatureOffRemovesCollectionItems() async throws {
        let fixture = try Fixture("fb-menu-library-off")
        defer { fixture.close() }
        let book = fixture.entry(try fixture.archive("book.cbz"))
        let context = FileBrowserMenuContext(kind: .file, entries: [book], folder: nil)
        let english = Locale(identifier: "en")
        func titles() -> [String] {
            let menu = NSMenu()
            FileBrowserMenuBuilder().rebuild(menu, for: context, actions: fixture.actions, locale: english)
            return menu.items.map(\.title)
        }
        #expect(titles().contains("Create Collection") && titles().contains("Add to Collection"))

        fixture.preferences.libraryFeatureEnabled = false
        #expect(!titles().contains("Create Collection") && !titles().contains("Add to Collection"))
        // 区切り線が 2 本続かない(空になった群を残さない)。
        let menu = NSMenu()
        FileBrowserMenuBuilder().rebuild(menu, for: context, actions: fixture.actions, locale: english)
        for (index, item) in menu.items.enumerated() where item.isSeparatorItem {
            #expect(index > 0 && !menu.items[index - 1].isSeparatorItem)
        }
        #expect(!FileBrowserMenuCommand.createCollection.isEnabled(in: context, actions: fixture.actions))
        #expect(fixture.actions.createCollection(from: [book]) == nil)
        let shelf = try #require(fixture.library.collections.libraries.first)
        #expect(fixture.actions.addToCollection([book], collectionID: shelf.id) == nil)
        #expect(fixture.welcome.pendingCreations.isEmpty)
    }

    @Test("「スマートライブラリの対象に追加」はフォルダだけ。登録済み・シークレットウインドウでは淡色、機能がOFFなら項目ごと出ず入り口でも断る")
    func addToSmartLibraryAvailability() throws {
        let fixture = try Fixture("fb-menu-smart-availability")
        defer { fixture.close() }
        let store = SmartLibraryStore(defaults: fixture.suite.defaults)
        fixture.actions.smartLibraryStore = store
        let folder = fixture.entry(try fixture.temporary.directory("shelf"))
        let book = fixture.entry(try fixture.archive("book.cbz"))
        let english = Locale(identifier: "en")
        func enabled(_ entries: [FileBrowserEntry], kind: FileBrowserMenuKind = .folder) -> Bool {
            FileBrowserMenuCommand.addToSmartLibrary.isEnabled(
                in: FileBrowserMenuContext(kind: kind, entries: entries, folder: nil), actions: fixture.actions
            )
        }
        func titles(_ kind: FileBrowserMenuKind, _ entries: [FileBrowserEntry]) -> [String] {
            let menu = NSMenu()
            FileBrowserMenuBuilder().rebuild(
                menu, for: FileBrowserMenuContext(kind: kind, entries: entries, folder: nil), actions: fixture.actions,
                locale: english
            )
            return menu.items.map(\.title)
        }

        #expect(titles(.folder, [folder]).contains("Add to Smart Library Targets"))
        #expect(titles(.tree, [folder]).contains("Add to Smart Library Targets"))
        #expect(!titles(.file, [book]).contains("Add to Smart Library Targets"))
        // 読み取り専用モードでも押せる(ファイルは変わらない)。ファイルが混ざったら・登録済みなら淡色。
        fixture.preferences.fileBrowserReadOnly = true
        #expect(enabled([folder]))
        #expect(!enabled([folder, book]))
        store.addFolder(folder.url)
        #expect(!enabled([folder]))
        store.removeFolder(id: try #require(store.folders.first).id)

        fixture.preferences.smartLibraryFeatureEnabled = false
        #expect(!titles(.folder, [folder]).contains("Add to Smart Library Targets"))
        #expect(!titles(.tree, [folder]).contains("Add to Smart Library Targets"))
        #expect(!enabled([folder]))
        #expect(fixture.actions.addToSmartLibrary([folder]) == nil)
        // 区切り線が 2 本続かない(空になった群を残さない)。
        let menu = NSMenu()
        FileBrowserMenuBuilder().rebuild(
            menu, for: FileBrowserMenuContext(kind: .folder, entries: [folder], folder: nil), actions: fixture.actions,
            locale: english
        )
        for (index, item) in menu.items.enumerated() where item.isSeparatorItem {
            #expect(index > 0 && !menu.items[index - 1].isSeparatorItem)
        }
        #expect(store.folders.isEmpty)

        let privateFixture = try Fixture("fb-menu-smart-private", isPrivate: true)
        defer { privateFixture.close() }
        privateFixture.actions.smartLibraryStore = SmartLibraryStore(defaults: privateFixture.suite.defaults)
        let privateFolder = privateFixture.entry(try privateFixture.temporary.directory("shelf"))
        #expect(!FileBrowserMenuCommand.addToSmartLibrary.isEnabled(
            in: FileBrowserMenuContext(kind: .folder, entries: [privateFolder], folder: nil), actions: privateFixture.actions
        ))
        #expect(privateFixture.actions.addToSmartLibrary([privateFolder]) == nil)
    }

    @Test("「スマートライブラリの対象に追加」は本が並ぶフォルダを足して知らせ、画像フォルダ(1 冊の本)は足さずに伝える")
    func addToSmartLibraryAddsOnlyNonBookFolders() async throws {
        let fixture = try Fixture("fb-menu-smart-add")
        defer { fixture.close() }
        let store = SmartLibraryStore(defaults: fixture.suite.defaults)
        fixture.actions.smartLibraryStore = store
        let shelfURL = try fixture.temporary.directory("shelf")
        _ = try fixture.archive("shelf/book.cbz")
        let shelf = fixture.entry(shelfURL)
        let imageFolder = fixture.entry(try fixture.imageFolder("pages"))

        await fixture.actions.addToSmartLibrary([imageFolder])?.value
        #expect(store.folders.isEmpty)
        #expect(fixture.presenter.problems.count == 1)

        await fixture.actions.addToSmartLibrary([shelf, imageFolder])?.value
        #expect(store.folders.map(\.path) == [MountTable.normalized(shelfURL.standardizedFileURL.path)])
        #expect(fixture.presenter.problems.count == 1)
        #expect(fixture.state.toastMessage != nil)
        // 足したフォルダは登録済み ―― 画像フォルダは残っているので、2 つを選べばまだ押せる。
        #expect(!fixture.actions.canAddToSmartLibrary([shelf]))
    }

    @Test("「パス名をコピー」はパスを文字列で載せる(複数なら 1 行に 1 つ)。読み取り専用でも使え、ペーストは淡色になる")
    func copyPathnames() throws {
        let fixture = try Fixture("fb-copy-pathname")
        defer { fixture.close() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        fixture.state.operations.pasteboard = pasteboard
        let book = fixture.entry(try fixture.archive("book.cbz"))
        let folder = fixture.entry(try fixture.temporary.directory("folder"))
        fixture.preferences.fileBrowserReadOnly = true

        fixture.actions.copy([book])
        #expect(fixture.state.operations.canPaste)
        fixture.actions.copyPathnames([book, folder])
        #expect(pasteboard.string(forType: .string) == book.url.path + "\n" + folder.url.path)
        #expect(!fixture.state.operations.canPaste)

        #expect(FileBrowserOperations.pathnames(of: [URL(fileURLWithPath: "/tmp/qoo-sample/dir", isDirectory: true)])
                == "/tmp/qoo-sample/dir")
        #expect(FileBrowserOperations.pathnames(of: [URL(fileURLWithPath: "/", isDirectory: true)]) == "/")
        #expect(FileBrowserEditCommand.forKey(keyCode: 8, flags: [.command, .option]) == .copyPathname)
        #expect(FileBrowserEditCommand.forKey(keyCode: 8, flags: [.command]) == nil)
    }

    @Test("「常にこのアプリケーションで開く」は書けた項目だけ開き、書けなかったことは知らせる。読み取り専用では何もしない")
    func alwaysOpenWith() async throws {
        let fixture = try Fixture("fb-always-open-with")
        defer { fixture.close() }
        let first = fixture.entry(try fixture.archive("first.cbz"))
        let second = fixture.entry(try fixture.archive("second.cbz"))
        let application = URL(fileURLWithPath: "/System/Applications/Preview.app", isDirectory: true)
        struct Refused: Error {}
        // 閉包が書き換える値は箱に入れる(`@MainActor` の閉包は Sendable。捕まえた変数の書き換えは CI のコンパイラが断る)。
        @MainActor final class Record {
            var asked: [URL] = []
            var opened: [FileBrowserEntry] = []
        }
        let record = Record()

        let task = fixture.actions.alwaysOpen(
            [first, second], withApplicationAt: application,
            setDefault: { app, file in
                #expect(app == application)
                record.asked.append(file)
                if file == second.url { throw Refused() }
            },
            thenOpen: { record.opened = $0 }
        )
        await task?.value
        #expect(record.asked == [first.url, second.url])
        #expect(record.opened.map(\.url) == [first.url])
        #expect(fixture.presenter.problems.count == 1)

        fixture.preferences.fileBrowserReadOnly = true
        #expect(!fixture.actions.canAlwaysOpenWith([first]))
        #expect(fixture.actions.alwaysOpen(
            [first], withApplicationAt: application, setDefault: { _, _ in Issue.record("read-only") }, thenOpen: { _ in }
        ) == nil)
    }

    @Test("「本ではありません」の説明は、コレクションのときだけ棚のフォルダの一文を添える")
    func noBooksMessageDependsOnTheOperation() {
        let english = Locale(identifier: "en")
        let collection = FileBrowserActions.noBooksProblem(names: ["Folder"], forCollection: true, locale: english)
        let single = FileBrowserActions.noBooksProblem(names: ["Folder"], forCollection: false, locale: english)
        #expect(collection.title == "“Folder” isn’t a book.")
        #expect(collection.message.contains("A folder of books"))
        #expect(!single.message.contains("A folder of books"))
        #expect(FileBrowserActions.noBooksProblem(names: ["a", "b"], forCollection: false, locale: english).title
                == "The selected items aren’t books.")
    }

    // MARK: - ウインドウのタイトル

    @Test("本を開いていないウインドウのタイトルは、ファイルブラウザならフォルダ、本棚ならコレクションかライブラリの名前")
    func welcomeWindowTitles() {
        let folder = URL(fileURLWithPath: "/tmp/qoo-title/Sample Shelf", isDirectory: true)
        let name = WindowTitle.folderName(folder, computerTitle: "Computer", startupVolumeName: "Startup")
        #expect(name == "Sample Shelf")
        #expect(WindowTitle.folderName(nil, computerTitle: "Computer") == "Computer")
        #expect(WindowTitle.folderName(URL(fileURLWithPath: "/"), computerTitle: "Computer", startupVolumeName: "Startup") == "Startup")
        #expect(WindowTitle.welcome(mode: .browser, folderName: name, libraryName: "Library", collectionName: "Shelf") == name)
        #expect(WindowTitle.welcome(mode: .shelf, folderName: name, libraryName: "Library", collectionName: "Shelf") == "Shelf")
        #expect(WindowTitle.welcome(mode: .shelf, folderName: name, libraryName: "Library", collectionName: nil) == "Library")
        #expect(WindowTitle.welcome(mode: .shelf, folderName: name, libraryName: nil, collectionName: nil) == "qooViewer")
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
        // 作る先を選ばなければ、本棚で選んでいるライブラリ(nil)。
        #expect(fixture.welcome.pendingCreations.map(\.libraryID) == [nil, nil])
        #expect(fixture.presenter.problems.isEmpty)

        // サブメニューでライブラリを選んだときは、積んだ全部がそのライブラリ宛てになる。
        fixture.welcome.pendingCreations = []
        let second = try #require(fixture.library.collections.createLibrary(name: "Second"))
        await fixture.actions.createCollection(from: [fixture.entry(loose), fixture.entry(shelf)], libraryID: second.id)?.value
        #expect(fixture.welcome.pendingCreations.map(\.libraryID) == [second.id, second.id])

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

        let locale = fixture.preferences.effectiveLocale
        await fixture.actions.addToCollection([fixture.entry(shelf)], collectionID: collection.id)?.value
        #expect(fixture.presenter.problems.isEmpty)
        let items = { fixture.library.collections.items(in: collection, sort: .nameAscending) }
        #expect(Set(items().map(\.bookID)) == [first.path, second.path])
        // 登録の後に知らせが出る(棚の 2 冊のうち 1 冊は入っていた)。
        #expect(fixture.state.toastMessage == FileBrowserActions.addedToCollectionMessage(
            addedTitles: ["02"], requestedCount: 2, collectionName: "Shelf", locale: locale
        ))
        await fixture.actions.addToCollection([fixture.entry(second)], collectionID: collection.id)?.value
        #expect(items().count == 2)
        #expect(fixture.state.toastMessage == FileBrowserActions.addedToCollectionMessage(
            addedTitles: [], requestedCount: 1, collectionName: "Shelf", locale: locale
        ))
    }

    @Test("「コレクションに登録」の知らせは、1 冊なら名前・複数なら冊数・入っていた本があればそれも伝える")
    func addedToCollectionMessageWording() {
        let ja = Locale(identifier: "ja")
        func message(_ titles: [String], of requested: Int) -> String {
            FileBrowserActions.addedToCollectionMessage(
                addedTitles: titles, requestedCount: requested, collectionName: "Shelf", locale: ja
            )
        }
        #expect(message(["Book"], of: 1) == "「Book」をコレクション「Shelf」に登録しました")
        #expect(message(["A", "B", "C"], of: 3) == "3 冊をコレクション「Shelf」に登録しました")
        #expect(message(["A"], of: 3) == "3 冊のうち 1 冊をコレクション「Shelf」に登録しました(残りは登録済みです)")
        #expect(message([], of: 2) == "すでにコレクション「Shelf」に登録されています")
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
        guard case .metadata(let bookEntry)? = fixture.state.bookSheet?.kind else {
            Issue.record("メタデータのシートが出ていない")
            return
        }
        #expect(bookEntry.url == book)

        fixture.state.bookSheet = nil
        let folder = try fixture.imageFolder("pictures")
        await fixture.actions.editMetadata([fixture.entry(folder)])?.value
        guard case .metadata(let folderEntry)? = fixture.state.bookSheet?.kind else {
            Issue.record("画像フォルダでシートが出ていない")
            return
        }
        #expect(folderEntry.url.path == folder.path)

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

    @Test("候補は種類の決まる単位で覚え、種類は名前だけで決める(ファイルに触らない。監査 11)")
    func openWithCacheKeys() {
        func key(_ path: String, directory: Bool = false, package: Bool = false) -> String {
            OpenWithApplications.cacheKey(for: URL(fileURLWithPath: path), isDirectory: directory, isPackage: package)
        }
        func type(_ path: String, directory: Bool = false, package: Bool = false) -> UTType {
            OpenWithApplications.contentType(for: URL(fileURLWithPath: path), isDirectory: directory, isPackage: package)
        }
        #expect(key("/x/a.CBZ") == key("/y/b.cbz"))
        // 拡張子の無いファイルはどれも同じ種類(.data)で引くので、パスごとには覚えない。
        #expect(key("/x/README") == key("/y/README"))
        #expect(type("/x/README") == .data)
        #expect(key("/x/folder", directory: true) != key("/x/folder"))
        // 中へ入れるフォルダは名前に . があってもフォルダ。パッケージは拡張子の種類。
        #expect(key("/x/vol.1", directory: true) == key("/x/folder", directory: true))
        #expect(type("/x/vol.1", directory: true) == .folder)
        #expect(type("/Applications/Safari.app", directory: true, package: true).conforms(to: .application))
        // どれも存在しないパス。種類を決めるのにファイルは要らない。
        #expect(type("/x/a.pdf") == .pdf)
    }
}

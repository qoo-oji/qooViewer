import AppKit
import SwiftUI

// ある機能の画面から別の機能を操作する項目の共通部品(2026-09-23、利用者の指示「機能間の横串」)。
//
// ■ 相手の機能が OFF のとき
// 項目は**出さない**(淡色で残さない ―― 機能そのものが無い。ファイルブラウザの右クリックのコレクションの群と同じ)。出すかどうかは
// 呼び出し側が環境設定で決め、ここの入り口も同じ設定を見て断る。await を挟むものは、戻ってからもう一度見る
// (待っている間に OFF にされたら何もしない。docs/plans/feature-toggle-audit.md の 2026-09-23 の表)。

// MARK: - 知らせ(ウインドウごと)

/// ビューアの外(サイドパネル・メニューバー)からの操作の結果を、そのウインドウのビューアのトーストに出す口。ContentView が入れる。
/// **AppState は weak で持つ**(RevealInFileBrowserAction と同じ理由)。
struct WindowNoticeAction {
    weak var appState: AppState?

    @MainActor
    func callAsFunction(_ message: String) {
        appState?.postViewerNotice(message)
    }
}

extension EnvironmentValues {
    @Entry var windowNotice = WindowNoticeAction()
}

/// ビューアのトーストに出す知らせ(AppState.viewerNotice)。同じ文を続けて出しても変化として届くよう、id を持つ。
struct ViewerNotice: Equatable {
    let id = UUID()
    let message: String
}

// MARK: - 「コレクションに登録」をホームの外から(ビューア・サイドパネル・メニューバー・メタデータの編集)

/// 登録に要るもの。アプリで 1 つのストアを**購読せずに**持つ(CollectionStore は表紙の抽出のたびに知らせるので、
/// `@EnvironmentObject` で持つと、サイドパネルの行やビューアがそのたびに組み直される)。QooViewerApp がシーンに入れる。
struct CollectionAddingContext {
    weak var collectionStore: CollectionStore?
    weak var coverExtractor: CollectionCoverExtractor?
    weak var preferences: AppPreferences?

    /// ライブラリ機能が ON か。
    @MainActor
    var isLibraryFeatureEnabled: Bool { preferences?.libraryFeatureEnabled ?? false }

    /// 本(1 冊ずつの本の URL)をコレクションへ登録し、結果の文を `report` へ渡す。
    ///
    /// - Returns: 登録の Task(テストのための口)。ライブラリ機能が OFF なら nil。
    @MainActor
    @discardableResult
    func add(_ books: [URL], to collectionID: UUID, report: @escaping @MainActor @Sendable (String) -> Void) -> Task<Void, Never>? {
        guard isLibraryFeatureEnabled, !books.isEmpty else { return nil }
        let locale = preferences?.effectiveLocale ?? .autoupdatingCurrent
        let context = self
        return Task { @MainActor in
            guard let result = await CollectionBookAdding.add(
                books, to: collectionID, collectionStore: context.collectionStore, coverExtractor: context.coverExtractor,
                isStillEnabled: { context.isLibraryFeatureEnabled }
            ) else { return }
            report(FileBrowserActions.addedToCollectionMessage(
                addedTitles: result.addedTitles, requestedCount: result.requestedCount,
                collectionName: result.collectionName, locale: locale
            ))
        }
    }
}

extension EnvironmentValues {
    @Entry var collectionAdding = CollectionAddingContext()
}

extension CollectionMenuLibrary {
    /// 「ホーム」メニューの名前の写し(HomeMenuDirectoryStore。名前・並び・中身が変わったときだけ知らせる)から。
    /// ライブラリ機能が OFF の間は空。
    static func libraries(from directory: HomeMenuDirectory, locale: Locale) -> [CollectionMenuLibrary] {
        directory.libraries.map { library in
            CollectionMenuLibrary(
                id: library.id, name: library.displayName(language: locale),
                collections: library.collections.map { ($0.id, $0.name) }
            )
        }
    }
}

/// 「コレクションに登録」のサブメニュー(SwiftUI の右クリック用)。名前は `HomeMenuDirectoryStore` から引き、CollectionStore は
/// 購読しない(CollectionAddingContext の型コメント)。出すかどうか(ライブラリ機能・シークレットウインドウ)は呼び出し側が決める。
///
/// **閉包は本の URL と `report` だけを持つ**(ビューアの右クリックでも ViewerView を捕まえない。CLAUDE.md の ViewerActionRelay の件)。
struct AddToCollectionMenu: View {
    let books: [URL]
    var isEnabled = true
    let report: @MainActor @Sendable (String) -> Void

    @EnvironmentObject private var directory: HomeMenuDirectoryStore
    @Environment(\.collectionAdding) private var adding
    @Environment(\.locale) private var locale

    var body: some View {
        let title = String(localized: "Add to Collection", language: locale)
        if isEnabled, !books.isEmpty {
            let adding = adding
            let books = books
            let report: @MainActor @Sendable (String) -> Void = report
            Menu(title) {
                FileBrowserMenuNodeItems(nodes: CollectionMenuLibrary.addMenuNodes(
                    for: CollectionMenuLibrary.libraries(from: directory.directory, locale: locale), locale: locale
                ) { collectionID in
                    adding.add(books, to: collectionID, report: report)
                })
            }
        } else {
            // `.contextMenu` の中の `Menu` には `.disabled` が効かない(FileBrowserDisabledSubmenu の型コメント)。
            FileBrowserDisabledSubmenu(title: title)
        }
    }
}

// MARK: - 「スマートライブラリの対象に追加」(ファイルブラウザ・サイドパネル・スマートライブラリへのドロップ)

@MainActor
enum SmartLibraryTargetAdding {
    struct Result {
        /// 足したフォルダ。
        let added: [URL]
        /// 1 冊の本になるフォルダだったので足さなかったもの。
        let refusedBooks: [URL]
    }

    /// 本(画像フォルダ・章のフォルダ)でないフォルダだけを対象フォルダに足す。本かどうかは `FileIO` の上で調べる
    /// (ShelfFolderResolver.isSingleBookFolder)。調べている間にスマートライブラリ機能を OFF にされたら足さない(nil)。
    /// 読む権限は FolderAccessStore に一本化(スマートライブラリの「フォルダを追加…」と同じ)。
    static func add(
        _ folders: [URL], store: SmartLibraryStore, folderAccess: FolderAccessStore?,
        isFeatureEnabled: @escaping @MainActor () -> Bool
    ) async -> Result? {
        let candidates = folders.filter { !store.containsFolder($0) }
        let isBook = await FileIO.perform { candidates.map { ShelfFolderResolver.isSingleBookFolder($0) } }
        guard isFeatureEnabled() else { return nil }
        var added: [URL] = []
        var refused: [URL] = []
        for (url, book) in zip(candidates, isBook) {
            if book {
                refused.append(url)
            } else {
                folderAccess?.add(url: url)
                store.addFolder(url)
                added.append(url)
            }
        }
        return Result(added: added, refusedBooks: refused)
    }

    /// 足したときの知らせの文。
    static func addedMessage(_ added: [URL], locale: Locale) -> String {
        added.count == 1
            ? String(format: String(localized: "Added “%@” to the smart library’s target folders", language: locale),
                     FileManager.default.displayName(atPath: added[0].path))
            : String(format: String(localized: "Added %lld folders to the smart library’s target folders", language: locale),
                     added.count)
    }
}

// MARK: - このアプリケーションで開く(ホームの本)

@MainActor
enum HomeBookOpenWith {
    /// 選んだアプリで本を開く。`scoped` なら(コレクションの本はブックマークで許可を持つ)スコープを開けたまま渡し、
    /// アプリが受け取り終えてから閉じる。失敗はアラートで知らせる(アプリの起動を待つ間に画面が消えていてもよいように、
    /// ビューの状態は使わない)。
    static func open(_ url: URL, withApplicationAt application: URL, scoped: Bool, locale: Locale) {
        let didStartAccessing = scoped && url.startAccessingSecurityScopedResource()
        Task { @MainActor in
            defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = OpenWithApplications.failureTitle(application: application, locale: locale)
                alert.informativeText = error.localizedDescription
                if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                    alert.beginSheetModal(for: window) { _ in }
                } else {
                    alert.runModal()
                }
            }
        }
    }

    /// 本のパスの名前だけで候補を引く(ディスクに触らない。本は書庫・PDF・EPUB のファイルか、画像のフォルダ)。
    static func applications(forBookAt path: String) -> [OpenWithApplications.Application] {
        let name = (path as NSString).lastPathComponent
        let isFile = isArchiveFile(name) || isPDFFile(name) || isEpubFile(name)
        return OpenWithApplications.shared.applications(
            for: URL(fileURLWithPath: path), isDirectory: !isFile, isPackage: false
        )
    }
}

// MARK: - 本の書き出し(ホームの本)

/// ホームの本の「本の書き出し」のシートの頼み(ファイルブラウザの FileBrowserBookSheet.Export と同じ材料)。
struct HomeBookExportRequest: Identifiable {
    let id = UUID()
    let export: FileBrowserBookSheet.Export
}

extension FileBrowserBookSheet.Export {
    /// 本を開かずに書き出すシートの材料。保存先の決め方はビューアの右クリックと同じ(ViewerView.startOpenBookExport):
    /// 環境設定「レイアウト」で決めてあれば何も尋ねず、決めていなければ先にフォルダを選んでもらう(やめたら nil)。
    ///
    /// - Parameters:
    ///   - url: 本の実体(コレクションの本ならブックマークから解決した URL ―― 書き出しがスコープを開けて読む)。
    ///   - bookID: 保存データの鍵(本のパス)。
    @MainActor
    static func make(
        url: URL, bookID: String, isDirectory: Bool, format: BookExportFormat, preferences: AppPreferences,
        bookmarkStore: BookmarkStore, layoutStore: LayoutStore, metadataStore: BookMetadataStore,
        collectionStore: CollectionStore? = nil
    ) -> FileBrowserBookSheet.Export? {
        let destination: OpenBookExportSheet.Destination
        let asks: Bool
        if preferences.bookExportDestinationMode(for: format) == .fixedFolder, let fixed = format.fixedFolder.lastFolder() {
            destination = .init(url: fixed, isSecurityScoped: true)
            asks = false
        } else {
            guard let chosen = ExportDestinationPanel.present(
                for: format, startingAt: nil, locale: preferences.effectiveLocale
            ) else { return nil }
            destination = .init(url: chosen, isSecurityScoped: false)
            asks = true
        }
        let viewModel = format.makeExportViewModel(
            bookmarkStore: bookmarkStore, layoutStore: layoutStore, metadataStore: metadataStore,
            preferences: preferences, collectionStore: collectionStore, loadsEligibleRows: false
        )
        let book = MangaBook(
            id: bookID, title: CollectionStore.itemTitle(for: url, isDirectory: isDirectory), sourceURL: url, pages: []
        )
        return .init(format: format, viewModel: viewModel, book: book, destination: destination, asksBeforeExporting: asks)
    }
}

extension View {
    /// 「本の書き出し」のシート(ファイルブラウザの右クリックと同じ OpenBookExportSheet)。
    func homeBookExportSheet(_ request: Binding<HomeBookExportRequest?>, allowsCoverSelection: Bool) -> some View {
        sheet(item: request) { shown in
            let export = shown.export
            OpenBookExportSheet(
                viewModel: export.viewModel,
                format: export.format,
                book: export.book,
                // 本を開いていない。DBに無い項目は3つの書き出しウインドウと同じく既定値。
                displayState: nil,
                initialDestination: export.destination,
                asksBeforeExporting: export.asksBeforeExporting,
                // カバーの指定はDBに残るので、シークレットウインドウでは選ばせない(ビューアの右クリックと同じ)。
                allowsCoverSelection: allowsCoverSelection
            ) { _ in
                request.wrappedValue = nil
            }
        }
    }
}

/// 「本の書き出し」のサブメニュー(SwiftUI の右クリック用。ファイルブラウザ・ビューアの右クリックと同じ 3 形式)。
struct BookExportMenu: View {
    var isEnabled = true
    let start: @MainActor (BookExportFormat) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        let title = String(localized: "Export Book", language: locale)
        if isEnabled {
            Menu(title) {
                ForEach(BookExportFormat.allCases) { format in
                    Button(format.menuTitleKey) { start(format) }
                }
            }
        } else {
            FileBrowserDisabledSubmenu(title: title)
        }
    }
}

extension BookExportFormat {
    /// 「本の書き出し」のサブメニューの中身(AppKit の右クリック用)。
    @MainActor
    static func menuNodes(locale: Locale, start: @escaping @MainActor (BookExportFormat) -> Void) -> [FileBrowserMenuNode] {
        allCases.map { format in
            .item(
                title: String(localized: format.menuTitleResource, language: locale), image: nil, isEnabled: true,
                action: { start(format) }
            )
        }
    }
}

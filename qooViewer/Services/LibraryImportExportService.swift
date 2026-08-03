import Foundation
import SwiftUI

/// JSON入出力(設計コンセプト6節)。お気に入り・ブックマーク・ページレイアウト設定を1つの
/// JSONファイルにまとめて書き出し/読み込みする。
///
/// ブックマーク(Bookmark.pageIndex: 実際の読書順インデックス)・レイアウト設定
/// (PageLayoutOverride.pageKey: ファイル名相当の文字列)はそれぞれ異なる単位で保存されているため、
/// 書き出し・読み込みのどちらでも対象の本を実際にBookLoaderで読み込み、EffectivePageOrderで
/// 変換する必要がある(ComicInfo.xmlは対象外)。
///
/// お気に入りはFavoritesStoreの公開API(subfolders(of:)/books(in:)/createFolder/
/// forceAddFavorite等)だけを経由して読み書きし、SwiftDataのModelContextへ直接アクセスしない
/// (FavoritesStore自身がお気に入りの唯一の窓口であるという既存の設計を踏襲する)。
@MainActor
enum LibraryImportExportService {

    // MARK: - エクスポート: 選択・結果

    struct ExportSelection {
        var includeFavorites: Bool
        var includeBookmarks: Bool
        var includeLayouts: Bool
    }

    struct ExportResult {
        /// ブックマークはあるがファイルが見つからずページキーへ変換できなかった本のbookID一覧。
        var skippedBookmarkBookIDs: [String] = []
    }

    static func buildExportFile(
        selection: ExportSelection,
        favoritesStore: FavoritesStore,
        bookmarkStore: BookmarkStore,
        layoutStore: LayoutStore
    ) async -> (QooLibraryExportFile, ExportResult) {
        var file = QooLibraryExportFile()
        var result = ExportResult()

        if selection.includeFavorites {
            file.favorites = exportFavorites(favoritesStore: favoritesStore)
        }
        if selection.includeBookmarks {
            let (bookmarks, skipped) = await exportBookmarks(bookmarkStore: bookmarkStore, layoutStore: layoutStore)
            file.bookmarks = bookmarks
            result.skippedBookmarkBookIDs = skipped
        }
        if selection.includeLayouts {
            file.layouts = exportLayouts(layoutStore: layoutStore)
        }
        return (file, result)
    }

    /// フォルダ階層をルートから再帰的にたどり、フラットな配列2つ(folders/books)に展開する。
    private static func exportFavorites(favoritesStore: FavoritesStore) -> ExportedFavorites {
        var folders: [ExportedFavoriteFolder] = []
        var books: [ExportedFavoriteBook] = []

        func walk(_ folder: FavoriteFolder?, folderID: String?) {
            for sub in favoritesStore.subfolders(of: folder) {
                let subID = sub.id.uuidString
                folders.append(ExportedFavoriteFolder(id: subID, name: sub.name, parentId: folderID))
                walk(sub, folderID: subID)
            }
            for book in favoritesStore.books(in: folder) {
                books.append(ExportedFavoriteBook(bookID: book.bookID, title: book.title, folderId: folderID))
            }
        }
        walk(nil, folderID: nil)
        return ExportedFavorites(folders: folders, books: books)
    }

    /// bookIDからこの本のURLを解決する。ブックマーク由来・レイアウト由来のどちらかの
    /// セキュリティスコープ付きブックマークが見つかればそれを使い、どちらもダメなら
    /// (LayoutStore.resolvedURL(forBookID:)自身が持つ)生パスへのフォールバックに任せる。
    private static func resolveURL(
        bookID: String, bookmarkStore: BookmarkStore, layoutStore: LayoutStore
    ) -> URL? {
        bookmarkStore.resolvedURLFromBookmarkData(forBookID: bookID) ?? layoutStore.resolvedURL(forBookID: bookID)
    }

    /// bookIDの本を実際に読み込む(URL解決 + セキュリティスコープの開始/終了 + BookLoader)。
    /// 失敗した場合(URLが解決できない/ファイルが見つからない/読み込みエラー)はnilを返す。
    private static func loadBook(
        bookID: String, bookmarkStore: BookmarkStore, layoutStore: LayoutStore
    ) async -> MangaBook? {
        guard let url = resolveURL(bookID: bookID, bookmarkStore: bookmarkStore, layoutStore: layoutStore) else {
            return nil
        }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return try? await BookLoader.load(from: url)
    }

    private static func exportBookmarks(
        bookmarkStore: BookmarkStore, layoutStore: LayoutStore
    ) async -> ([String: [ExportedBookmark]], [String]) {
        var result: [String: [ExportedBookmark]] = [:]
        var skipped: [String] = []

        for group in bookmarkStore.groups {
            let bookmarks = bookmarkStore.bookmarks(forBookID: group.bookID).sorted { $0.pageIndex < $1.pageIndex }
            guard !bookmarks.isEmpty else { continue }
            guard let book = await loadBook(bookID: group.bookID, bookmarkStore: bookmarkStore, layoutStore: layoutStore) else {
                skipped.append(group.bookID)
                continue
            }
            let settings = layoutStore.bookLayoutSettings(forBookID: group.bookID)
            let excludedKeys = Set(
                layoutStore.pageOverrides(forBookID: group.bookID)
                    .filter { $0.state == .excluded }
                    .map(\.pageKey)
            )
            let orderedKeys = EffectivePageOrder.pageKeys(
                for: book, pageOrderOverride: settings?.pageOrderOverride, excludedKeys: excludedKeys
            )
            var entries: [ExportedBookmark] = []
            for bookmark in bookmarks {
                guard orderedKeys.indices.contains(bookmark.pageIndex) else { continue }
                entries.append(ExportedBookmark(page: orderedKeys[bookmark.pageIndex], name: bookmark.name))
            }
            guard !entries.isEmpty else { continue }
            result[group.bookID] = entries
        }
        return (result, skipped)
    }

    /// レイアウト設定はpageKeyをそのまま使うため、本を読み込み直す必要が無く軽量に書き出せる。
    private static func exportLayouts(layoutStore: LayoutStore) -> [String: ExportedBookLayout] {
        var result: [String: ExportedBookLayout] = [:]
        for bookID in layoutStore.layoutBookIDs {
            let settings = layoutStore.bookLayoutSettings(forBookID: bookID)
            let overrides = layoutStore.pageOverrides(forBookID: bookID)
            guard settings != nil || !overrides.isEmpty else { continue }

            var pages: [String: ExportedPageState] = [:]
            for override in overrides {
                pages[override.pageKey] = ExportedPageState(state: override.state.rawValue)
            }
            result[bookID] = ExportedBookLayout(
                readingDirection: settings?.readingDirectionOverride?.stableID,
                forcedDisplayMode: settings?.forcedDisplayMode?.stableID,
                pageOrder: settings?.pageOrderOverride,
                pages: pages.isEmpty ? nil : pages
            )
        }
        return result
    }

    // MARK: - JSONの読み書き

    static func write(_ file: QooLibraryExportFile, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> QooLibraryExportFile {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(QooLibraryExportFile.self, from: data)
    }

    // MARK: - インポート: 方針・結果

    /// カテゴリごとに選べる取り込み方針。ファイルにそのカテゴリのキー自体が無い場合は、
    /// この値に関わらず何も変更しない(呼び出し側のUIも、キーが存在するカテゴリだけ
    /// ピッカーを表示する)。
    enum ImportPolicy: String, CaseIterable, Identifiable {
        /// 対象の本の既存データを削除してから、ファイルの内容に置き換える。
        case overwrite
        /// 既存データは変更せず、まだ無いものだけを追加する。
        case merge
        /// このカテゴリは取り込まない。
        case ignore

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .overwrite: return "Overwrite"
            case .merge: return "Merge"
            case .ignore: return "Ignore"
            }
        }
    }

    struct ImportPolicies {
        var favorites: ImportPolicy = .merge
        var bookmarks: ImportPolicy = .merge
        var layouts: ImportPolicy = .merge
    }

    struct ImportSummary {
        var favoritesImportedFolders = 0
        var favoritesImportedBooks = 0
        var favoritesSkippedForLimit = 0
        var bookmarksImportedBooks = 0
        var bookmarksImportedEntries = 0
        var bookmarksSkippedBookIDs: [String] = []
        var layoutsImportedBooks = 0
        var layoutsSkippedBookIDs: [String] = []
    }

    static func apply(
        _ file: QooLibraryExportFile,
        policies: ImportPolicies,
        favoritesStore: FavoritesStore,
        bookmarkStore: BookmarkStore,
        layoutStore: LayoutStore
    ) async -> ImportSummary {
        var summary = ImportSummary()

        if let favorites = file.favorites, policies.favorites != .ignore {
            applyFavorites(favorites, policy: policies.favorites, favoritesStore: favoritesStore, summary: &summary)
        }
        // レイアウト(除外・並べ替え)を必ずブックマークより先に取り込む。
        //
        // 経緯(ユーザー報告): 同じJSONにブックマークとレイアウト(除外ページの追加など)の
        // 両方が含まれている場合、以前はブックマークを先に取り込んでいたため、
        // applyBookmarks内のpageKey→pageIndex変換(EffectivePageOrder.pageKeys)が、
        // まだこのJSONのレイアウトが反映されていない「古い」除外・並べ替え状態を基準に
        // 計算されていた。その直後にapplyLayoutsが新しい除外・並べ替え状態を書き込むと、
        // 有効なページの並びがずれてしまい、さっき書き込んだBookmark.pageIndexが指すページが
        // 変わってしまう(例: 006.jpgに紐づくはずのブックマークが008.jpgに化ける)。
        // レイアウトを先に確定させてからブックマークのpageKey→pageIndex変換を行うことで、
        // 変換に使う有効なページの並びが最終状態と一致するようにする。
        if let layouts = file.layouts, policies.layouts != .ignore {
            await applyLayouts(
                layouts, policy: policies.layouts,
                layoutStore: layoutStore, bookmarkStore: bookmarkStore, summary: &summary
            )
        }
        if let bookmarks = file.bookmarks, policies.bookmarks != .ignore {
            await applyBookmarks(
                bookmarks, policy: policies.bookmarks,
                bookmarkStore: bookmarkStore, layoutStore: layoutStore, summary: &summary
            )
        }
        return summary
    }

    // MARK: - お気に入りの取り込み

    private static func applyFavorites(
        _ favorites: ExportedFavorites, policy: ImportPolicy,
        favoritesStore: FavoritesStore, summary: inout ImportSummary
    ) {
        if policy == .overwrite {
            favoritesStore.deleteAllFavorites()
        }

        // JSON内のフォルダid(このファイル内だけで通用する一時的な文字列) -> 実際に作成/解決した
        // FavoriteFolder。循環参照(壊れたファイル)に備えて解決中のidも別途記録し、無限再帰を防ぐ。
        var resolvedFolders: [String: FavoriteFolder?] = [:]
        var resolvingStack: Set<String> = []

        func resolveFolder(_ folderId: String?) -> FavoriteFolder? {
            guard let folderId else { return nil }
            if let cached = resolvedFolders[folderId] { return cached }
            guard !resolvingStack.contains(folderId) else { return nil }
            guard let entry = favorites.folders.first(where: { $0.id == folderId }) else { return nil }

            resolvingStack.insert(folderId)
            let parent = resolveFolder(entry.parentId)
            resolvingStack.remove(folderId)

            // マージ時は、同じ親の直下に同名フォルダが既にあればそれを再利用する(取り込むたびに
            // 同名フォルダが増殖するのを避けるため)。上書き時はdeleteAllFavoritesの直後のため、
            // 既存フォルダと衝突することはない。
            if policy == .merge,
               let existing = favoritesStore.subfolders(of: parent).first(where: { $0.name == entry.name }) {
                resolvedFolders[folderId] = existing
                return existing
            }
            switch favoritesStore.createFolder(name: entry.name, parent: parent) {
            case .success(let created):
                summary.favoritesImportedFolders += 1
                resolvedFolders[folderId] = created
                return created
            case .failure:
                resolvedFolders[folderId] = nil
                return nil
            }
        }

        for bookEntry in favorites.books {
            // マージ時、この本がどこか(別のフォルダも含む)に既に登録済みなら追加しない
            // (マージ=まだ無いものだけを足す、という方針。詳細はImportPolicyのコメント参照)。
            if policy == .merge, !favoritesStore.existingFavorites(forBookID: bookEntry.bookID).isEmpty {
                continue
            }
            let folder = resolveFolder(bookEntry.folderId)
            let url = URL(fileURLWithPath: bookEntry.bookID)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // FavoritesStoreの登録APIはすべてMangaBookを要求するが、forceAddFavoriteが実際に
            // 参照するのはbook.id/book.sourceURL/book.titleだけ(セキュリティスコープ付き
            // ブックマークの生成とタイトルの記録)のため、ページ一覧を持たない軽量なMangaBookで
            // 十分間に合う(この本を今開いているわけではないので、実際のページを読み込む
            // 必要が無い)。
            let stubBook = MangaBook(id: bookEntry.bookID, title: bookEntry.title, sourceURL: url, pages: [])
            switch favoritesStore.forceAddFavorite(book: stubBook, to: folder) {
            case .added, .overwritten:
                summary.favoritesImportedBooks += 1
            case .limitReached:
                summary.favoritesSkippedForLimit += 1
            case .needsDuplicateConfirmation, .failed:
                break
            }
        }
    }

    // MARK: - ブックマークの取り込み

    private static func applyBookmarks(
        _ bookmarks: [String: [ExportedBookmark]], policy: ImportPolicy,
        bookmarkStore: BookmarkStore, layoutStore: LayoutStore, summary: inout ImportSummary
    ) async {
        for (bookID, entries) in bookmarks {
            guard !entries.isEmpty else { continue }
            guard let book = await loadBook(bookID: bookID, bookmarkStore: bookmarkStore, layoutStore: layoutStore) else {
                summary.bookmarksSkippedBookIDs.append(bookID)
                continue
            }
            let settings = layoutStore.bookLayoutSettings(forBookID: bookID)
            let excludedKeys = Set(
                layoutStore.pageOverrides(forBookID: bookID).filter { $0.state == .excluded }.map(\.pageKey)
            )
            let orderedKeys = EffectivePageOrder.pageKeys(
                for: book, pageOrderOverride: settings?.pageOrderOverride, excludedKeys: excludedKeys
            )
            var keyToIndex: [String: Int] = [:]
            for (index, key) in orderedKeys.enumerated() { keyToIndex[key] = index }

            if policy == .overwrite {
                bookmarkStore.deleteAllBookmarks(forBookID: bookID)
            }
            var importedAny = false
            for entry in entries {
                guard let pageIndex = keyToIndex[entry.page] else { continue }
                // addBookmarkは同じページに既存のブックマークがあれば何もしない(内部で重複防止
                // 済み)ため、マージ・上書きのどちらでもそのまま呼ぶだけでよい(上書きは直前の
                // deleteAllBookmarksで既に空になっている)。実際に追加できたかどうかは戻り値
                // (Bool)で分かるため、前後でbookmarks(forBookID:)を2回フェッチして件数を
                // 比較する必要はない。
                if bookmarkStore.addBookmark(bookID: bookID, pageIndex: pageIndex, name: entry.name) {
                    importedAny = true
                    summary.bookmarksImportedEntries += 1
                }
            }
            if importedAny { summary.bookmarksImportedBooks += 1 }
        }
    }

    // MARK: - レイアウト設定の取り込み

    private static func applyLayouts(
        _ layouts: [String: ExportedBookLayout], policy: ImportPolicy,
        layoutStore: LayoutStore, bookmarkStore: BookmarkStore, summary: inout ImportSummary
    ) async {
        for (bookID, layout) in layouts {
            guard let book = await loadBook(bookID: bookID, bookmarkStore: bookmarkStore, layoutStore: layoutStore) else {
                summary.layoutsSkippedBookIDs.append(bookID)
                continue
            }
            // 差し替え検知(2.5節)の指紋を正しく記録するため、必ず実ファイルを読み込んだ
            // MangaBook(book)を使う(ページを持たないスタブでは指紋が不正確になり、次に
            // この本を開いたときに誤って「差し替えられた」と判定されてしまう)。
            let existingSettings = layoutStore.bookLayoutSettings(forBookID: bookID)

            if policy == .overwrite {
                layoutStore.discardLayoutData(forBookID: bookID)
            }

            // マージ時、本全体の設定(読み方向・見開き強制・ページ順)は「まだ何も設定されて
            // いない場合にのみ」まとめて適用する(一部の項目だけ穴埋めするのではなく、
            // 「本全体設定」を1つの単位として扱う。既存の一部だけを上書きして中途半端な
            // 組み合わせになるのを避けるため)。
            let hasExistingBookLevelSettings = policy == .merge && existingSettings?.isBookLevelSettingEmpty == false
            if !hasExistingBookLevelSettings {
                if let readingDirection = layout.readingDirection.flatMap(ReadingDirection.init(stableID:)) {
                    layoutStore.setReadingDirectionOverride(for: book, readingDirection)
                }
                if let forcedDisplayMode = layout.forcedDisplayMode.flatMap(DisplayMode.init(stableID:)) {
                    layoutStore.setForcedDisplayMode(for: book, forcedDisplayMode)
                }
                if let pageOrder = layout.pageOrder, !pageOrder.isEmpty {
                    layoutStore.setPageOrderOverride(for: book, pageOrder)
                }
            }

            if let pages = layout.pages {
                let existingKeys = policy == .merge
                    ? Set(layoutStore.pageOverrides(forBookID: bookID).map(\.pageKey))
                    : []
                for (pageKey, pageState) in pages {
                    if policy == .merge, existingKeys.contains(pageKey) { continue }
                    guard let state = PageLayoutState(rawValue: pageState.state) else { continue }
                    layoutStore.setPageLayoutState(for: book, pageKey: pageKey, state: state)
                }
            }
            summary.layoutsImportedBooks += 1
        }
    }
}

/// エクスポート/インポートのファイル選択パネルが最後に開いたフォルダを記憶する。
/// AppPreferencesは既存のUserDefaultsキー(単純なBool/Double/enum rawValueのみ)のパターンに
/// 合わせているため、セキュリティスコープ付きブックマーク(Data)を保存するこの用途では
/// あえて専用の小さな仕組みとして分離している。
enum LibraryIOFolderMemory {
    private static let defaultsKey = "qooViewer.pref.lastLibraryIOFolderBookmark"

    static func lastFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale
        )
    }

    static func remember(_ folderURL: URL) {
        guard let data = try? folderURL.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

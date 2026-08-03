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
            let (bookmarks, skipped) = await exportBookmarks(
                favoritesStore: favoritesStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore
            )
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
                books.append(
                    ExportedFavoriteBook(
                        bookID: book.bookID,
                        inodeNumber: book.inodeNumber,
                        volumeDeviceNumber: book.volumeDeviceNumber,
                        title: book.title,
                        folderId: folderID
                    )
                )
            }
        }
        walk(nil, folderID: nil)
        return ExportedFavorites(folders: folders, books: books)
    }

    /// bookIDからこの本のURLを解決する。
    ///
    /// ユーザー要望: iノード番号による管理に変更したい。ファイルノード識別子(fileNodeIdentifier)が
    /// 分かっている場合は、まずそれを手がかりに(お気に入り/レイアウト/ブックマークいずれかの)
    /// ローカルのセキュリティスコープ付きブックマークから現在の実際のURLを解決できないか試す。
    /// この方法なら、エクスポート後にファイルがリネーム・移動されていても正しく解決できる
    /// (JSONのbookID(パス)は参考情報として残すが、この解決処理では優先して使わない)。
    /// 手がかりが無い/見つからない場合のみ、従来通りbookID(パス)に基づく解決(ブックマーク由来・
    /// レイアウト由来のどちらかのセキュリティスコープ付きブックマーク、それも無ければ
    /// LayoutStore.resolvedURL(forBookID:)自身が持つ生パスへのフォールバック)にフォールバックする。
    private static func resolveURL(
        bookID: String, fileNodeIdentifier: FileNodeIdentifier?,
        favoritesStore: FavoritesStore, bookmarkStore: BookmarkStore, layoutStore: LayoutStore
    ) -> URL? {
        if let fileNodeIdentifier {
            if let url = favoritesStore.resolvedURL(matching: fileNodeIdentifier) { return url }
            if let url = layoutStore.resolvedURL(matching: fileNodeIdentifier) { return url }
            if let url = bookmarkStore.resolvedURL(matching: fileNodeIdentifier) { return url }
        }
        return bookmarkStore.resolvedURLFromBookmarkData(forBookID: bookID) ?? layoutStore.resolvedURL(forBookID: bookID)
    }

    /// bookIDの本を実際に読み込む(URL解決 + セキュリティスコープの開始/終了 + BookLoader)。
    /// 失敗した場合(URLが解決できない/ファイルが見つからない/読み込みエラー)はnilを返す。
    private static func loadBook(
        bookID: String, fileNodeIdentifier: FileNodeIdentifier?,
        favoritesStore: FavoritesStore, bookmarkStore: BookmarkStore, layoutStore: LayoutStore
    ) async -> MangaBook? {
        guard let url = resolveURL(
            bookID: bookID, fileNodeIdentifier: fileNodeIdentifier,
            favoritesStore: favoritesStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore
        ) else { return nil }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return try? await BookLoader.load(from: url)
    }

    private static func exportBookmarks(
        favoritesStore: FavoritesStore, bookmarkStore: BookmarkStore, layoutStore: LayoutStore
    ) async -> ([ExportedBookmarkEntry], [String]) {
        var result: [ExportedBookmarkEntry] = []
        var skipped: [String] = []

        for group in bookmarkStore.groups {
            let bookmarks = bookmarkStore.bookmarks(forBookID: group.bookID).sorted { $0.pageIndex < $1.pageIndex }
            guard !bookmarks.isEmpty else { continue }
            // 同じbookIDのBookmark行はすべて同じファイルノード識別子を記録しているはずのため、
            // 最初に見つかった値をこの本の識別子として使う(1件も記録が無い場合はnilのまま)。
            let fileNodeIdentifier = bookmarks.lazy.compactMap(\.fileNodeIdentifier).first
            guard let book = await loadBook(
                bookID: group.bookID, fileNodeIdentifier: fileNodeIdentifier,
                favoritesStore: favoritesStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore
            ) else {
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
            result.append(
                ExportedBookmarkEntry(
                    bookID: group.bookID,
                    inodeNumber: fileNodeIdentifier?.inodeNumber,
                    volumeDeviceNumber: fileNodeIdentifier?.volumeDeviceNumber,
                    bookmarks: entries
                )
            )
        }
        return (result, skipped)
    }

    /// レイアウト設定はpageKeyをそのまま使うため、本を読み込み直す必要が無く軽量に書き出せる。
    private static func exportLayouts(layoutStore: LayoutStore) -> [ExportedBookLayoutEntry] {
        var result: [ExportedBookLayoutEntry] = []
        for bookID in layoutStore.layoutBookIDs {
            let settings = layoutStore.bookLayoutSettings(forBookID: bookID)
            let overrides = layoutStore.pageOverrides(forBookID: bookID)
            guard settings != nil || !overrides.isEmpty else { continue }

            var pages: [String: ExportedPageState] = [:]
            for override in overrides {
                pages[override.pageKey] = ExportedPageState(state: override.state.rawValue)
            }
            result.append(
                ExportedBookLayoutEntry(
                    bookID: bookID,
                    inodeNumber: settings?.inodeNumber,
                    volumeDeviceNumber: settings?.volumeDeviceNumber,
                    layout: ExportedBookLayout(
                        readingDirection: settings?.readingDirectionOverride?.stableID,
                        forcedDisplayMode: settings?.forcedDisplayMode?.stableID,
                        pageOrder: settings?.pageOrderOverride,
                        pages: pages.isEmpty ? nil : pages
                    )
                )
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
            applyFavorites(
                favorites, policy: policies.favorites,
                favoritesStore: favoritesStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore,
                summary: &summary
            )
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
                favoritesStore: favoritesStore, layoutStore: layoutStore, bookmarkStore: bookmarkStore,
                summary: &summary
            )
        }
        if let bookmarks = file.bookmarks, policies.bookmarks != .ignore {
            await applyBookmarks(
                bookmarks, policy: policies.bookmarks,
                favoritesStore: favoritesStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore,
                summary: &summary
            )
        }
        return summary
    }

    // MARK: - お気に入りの取り込み

    private static func applyFavorites(
        _ favorites: ExportedFavorites, policy: ImportPolicy,
        favoritesStore: FavoritesStore, bookmarkStore: BookmarkStore, layoutStore: LayoutStore,
        summary: inout ImportSummary
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

        // 経緯(ユーザー報告): JSONインポートが非常に遅い。Xcodeのコンソールを見る限りJSONを
        // 1行読むたびにSQLiteへの書き込みが起きているように見える、との指摘。実際、以前はここで
        // favoritesStore.forceAddFavorite(book:to:)を本の件数ぶんループで個別に呼んでおり、
        // そのたびに同期save()+reload()が走っていた。フォルダ解決(resolveFolder。実際に新規
        // フォルダを作る場合だけSQLiteに触れる。作成するフォルダ数は本の冊数よりずっと少ないため
        // 影響は小さい)とURL解決はこれまで通り1件ずつその場で行うが、実際の登録
        // (FavoriteBookの作成)はいったんpendingRequestsに貯めておき、ループの最後に
        // FavoritesStore.forceAddFavorites(_:)へまとめて渡すことで、保存・再フェッチを
        // この一括インポート全体で1回にまとめる。
        var pendingRequests: [FavoritesStore.BulkFavoriteRequest] = []
        // マージ時、同じ本が複数フォルダに登録されていて(=favorites.booksに同じbookIDのbookEntryが
        // 複数)、かつインポート先ライブラリにまだ1件も登録が無い場合、以前は「1件目を登録した
        // 直後にsave()されるため、2件目のexistingFavorites(forBookID:)チェックで1件目がヒットし、
        // 2件目以降はスキップされる」という結果になっていた(=同じ本を複数フォルダへ登録している
        // 状態はインポートで再現されず、最初に見つかったフォルダにだけ登録される)。ここではまだ
        // save()していないため、このバッチ内で既にpendingRequestsへ積んだ解決済みURL(の
        // パス=登録時にFavoriteBook.bookIDとなる値)を別途記録しておき、同じ挙動
        // (最初の1件だけを採用する)を保つ。
        var queuedResolvedPaths: Set<String> = []

        for bookEntry in favorites.books {
            // マージ時、この本がどこか(別のフォルダも含む)に既に登録済みなら追加しない
            // (マージ=まだ無いものだけを足す、という方針。詳細はImportPolicyのコメント参照)。
            //
            // ユーザー要望: iノード番号による管理に変更したい。bookID(パス)が一致するかだけでなく、
            // ファイルノード識別子が一致する登録が既にあるかどうかも確認する(JSONのbookIDは
            // 参考情報として残すが、重複判定の主たる手段にはしない)。
            if policy == .merge {
                var alreadyRegistered = !favoritesStore.existingFavorites(forBookID: bookEntry.bookID).isEmpty
                if !alreadyRegistered, let identifier = bookEntry.fileNodeIdentifier {
                    alreadyRegistered = !favoritesStore.existingFavorites(matching: identifier).isEmpty
                }
                if alreadyRegistered { continue }
            }
            let folder = resolveFolder(bookEntry.folderId)
            // ユーザー要望: JSONのファイルパスは参考情報として残すが、インポート時にはまず
            // ファイルノード識別子(iノード番号)を手がかりに、ローカルに既に保存されている
            // セキュリティスコープ付きブックマークから現在の実際のURLを解決できないか試す
            // (resolveURL参照)。見つからない場合のみ、JSONのbookID(パス)へフォールバックする。
            guard let url = resolveURL(
                bookID: bookEntry.bookID, fileNodeIdentifier: bookEntry.fileNodeIdentifier,
                favoritesStore: favoritesStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore
            ) ?? {
                let fallback = URL(fileURLWithPath: bookEntry.bookID)
                return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
            }() else { continue }
            if policy == .merge, queuedResolvedPaths.contains(url.path) { continue }
            // FavoritesStoreの登録APIはすべてMangaBookを要求するが、forceAddFavorite(s)が実際に
            // 参照するのはbook.id/book.sourceURL/book.titleだけ(セキュリティスコープ付き
            // ブックマークの生成とタイトルの記録)のため、ページ一覧を持たない軽量なMangaBookで
            // 十分間に合う(この本を今開いているわけではないので、実際のページを読み込む
            // 必要が無い)。book.idにはbookEntry.bookID(参考情報のJSON上のパス)ではなく、
            // 実際に解決できたurlのpathを使う(お気に入りの検索キーが実体と一致するようにする)。
            let stubBook = MangaBook(id: url.path, title: bookEntry.title, sourceURL: url, pages: [])
            pendingRequests.append(FavoritesStore.BulkFavoriteRequest(book: stubBook, folder: folder))
            queuedResolvedPaths.insert(url.path)
        }

        for outcome in favoritesStore.forceAddFavorites(pendingRequests) {
            switch outcome {
            case .added:
                summary.favoritesImportedBooks += 1
            case .limitReached:
                summary.favoritesSkippedForLimit += 1
            case .failed:
                break
            }
        }
    }

    // MARK: - ブックマークの取り込み

    private static func applyBookmarks(
        _ bookmarks: [ExportedBookmarkEntry], policy: ImportPolicy,
        favoritesStore: FavoritesStore, bookmarkStore: BookmarkStore, layoutStore: LayoutStore,
        summary: inout ImportSummary
    ) async {
        for entry in bookmarks {
            guard !entry.bookmarks.isEmpty else { continue }
            guard let book = await loadBook(
                bookID: entry.bookID, fileNodeIdentifier: entry.fileNodeIdentifier,
                favoritesStore: favoritesStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore
            ) else {
                summary.bookmarksSkippedBookIDs.append(entry.bookID)
                continue
            }
            // ファイルノード識別子による解決の結果、実際のbookID(book.id)がJSON上のbookIDと
            // 異なることがある(リネーム・移動後)。以降はすべてbook.id(実際の現在のパス)を
            // 使う(JSONのbookIDはここまでの解決処理でのみ参考情報として使う)。
            let bookID = book.id
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
            // 経緯(ユーザー報告): JSONインポートが非常に遅い。Xcodeのコンソールを見る限りJSONを
            // 1行読むたびにSQLiteへの書き込みが起きているように見える、との指摘。実際、以前は
            // ここでbookmarkStore.addBookmark(bookID:pageIndex:name:)をこの本のブックマーク件数
            // ぶんループで個別に呼んでおり、そのたびに同期save()+reload()+通知が走っていた
            // (本1冊で数百件になることも珍しくない)。対象ページが見つかったブックマークを
            // いったんpendingEntriesに貯めておき、addBookmarks(bookID:entries:)へまとめて渡す
            // ことで、この本につき保存・再フェッチ・通知を1回にまとめる(重複防止の意味は
            // addBookmarkのループ呼び出しと変わらない)。
            var pendingEntries: [(pageIndex: Int, name: String)] = []
            for bookmarkEntry in entry.bookmarks {
                guard let pageIndex = keyToIndex[bookmarkEntry.page] else { continue }
                pendingEntries.append((pageIndex: pageIndex, name: bookmarkEntry.name))
            }
            let addedCount = bookmarkStore.addBookmarks(bookID: bookID, entries: pendingEntries)
            if addedCount > 0 {
                summary.bookmarksImportedBooks += 1
                summary.bookmarksImportedEntries += addedCount
            }
        }
    }

    // MARK: - レイアウト設定の取り込み

    private static func applyLayouts(
        _ layouts: [ExportedBookLayoutEntry], policy: ImportPolicy,
        favoritesStore: FavoritesStore, layoutStore: LayoutStore, bookmarkStore: BookmarkStore,
        summary: inout ImportSummary
    ) async {
        for entry in layouts {
            guard let book = await loadBook(
                bookID: entry.bookID, fileNodeIdentifier: entry.fileNodeIdentifier,
                favoritesStore: favoritesStore, bookmarkStore: bookmarkStore, layoutStore: layoutStore
            ) else {
                summary.layoutsSkippedBookIDs.append(entry.bookID)
                continue
            }
            // ファイルノード識別子による解決の結果、実際のbookID(book.id)がJSON上のbookIDと
            // 異なることがある(リネーム・移動後)。以降はすべてbook.id(実際の現在のパス)を使う。
            let bookID = book.id
            let layout = entry.layout
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
            let readingDirection = hasExistingBookLevelSettings
                ? nil : layout.readingDirection.flatMap(ReadingDirection.init(stableID:))
            let forcedDisplayMode = hasExistingBookLevelSettings
                ? nil : layout.forcedDisplayMode.flatMap(DisplayMode.init(stableID:))
            let pageOrder = hasExistingBookLevelSettings
                ? nil : layout.pageOrder.flatMap { $0.isEmpty ? nil : $0 }

            // 経緯(ユーザー報告): JSONインポートが非常に遅い。Xcodeのコンソールを見る限りJSONを
            // 1行読むたびにSQLiteへの書き込みが起きているように見える、との指摘。実際、以前は
            // 本全体設定を最大3回、ページ単位設定をpages.countぶんループしてそれぞれ
            // setReadingDirectionOverride等/setPageLayoutStateを個別に呼んでおり、そのたびに
            // 同期save()+reloadLayoutBookIDs()(全件フェッチ)+通知が走っていた(ページ単位設定は
            // 本によっては数百〜数千件になる)。ここでは反映すべき変更をpageChangesへ集計するに
            // とどめ、実際の書き込みはapplyImportedLayout(_:)へまとめて渡すことで、この本につき
            // 保存・再フェッチ・通知を1回にまとめる。
            var pageChanges: [String: PageLayoutState] = [:]
            if let pages = layout.pages {
                let existingKeys = policy == .merge
                    ? Set(layoutStore.pageOverrides(forBookID: bookID).map(\.pageKey))
                    : []
                for (pageKey, pageState) in pages {
                    if policy == .merge, existingKeys.contains(pageKey) { continue }
                    guard let state = PageLayoutState(rawValue: pageState.state) else { continue }
                    pageChanges[pageKey] = state
                }
            }

            layoutStore.applyImportedLayout(
                for: book,
                readingDirection: readingDirection,
                forcedDisplayMode: forcedDisplayMode,
                pageOrder: pageOrder,
                pageChanges: pageChanges
            )
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

import Foundation
import SwiftUI
import SwiftData

/// JSON入出力(設計コンセプト6節)。ブックマーク・ページレイアウト設定などを1つの
/// JSONファイルにまとめて書き出し/読み込みする。
///
/// ブックマーク(Bookmark.pageIndex: 実際の読書順インデックス)・レイアウト設定
/// (PageLayoutOverride.pageKey: ファイル名相当の文字列)はそれぞれ異なる単位で保存されているため、
/// 書き出し・読み込みのどちらでも対象の本を実際にBookLoaderで読み込み、EffectivePageOrderで
/// 変換する必要がある(ComicInfo.xmlは対象外)。
///
/// お気に入り(`favorites`)は 2026-10-24 に機能ごと削除した。以前のファイルにあっても読み飛ばす(QooLibraryExportFile のコメント)。
@MainActor
enum LibraryImportExportService {

    // MARK: - エクスポート: 選択・結果

    struct ExportSelection {
        var includeBookmarks: Bool
        var includeLayouts: Bool
        var includeMetadata: Bool
        /// ファイル名からメタデータを作る規則(qooMeta。アプリ全体の設定)を含めるかどうか。
        var includeMetadataRules: Bool
        /// ライブラリ・コレクション・その中の本(改善要望5)を含めるかどうか。
        var includeCollections: Bool
        // ここから下は 2026-09-23(利用者の運用: この JSON とコレクション表紙の組をバックアップとして
        // 持ち、フォルダのアクセス権以外は JSON を読めば環境が戻るようにしたい)。
        /// 本ごとの読書位置と表示の状態(`BookReadingState`)。
        var includeReadingStates: Bool = true
        /// スマートライブラリのスマートコレクション・対象フォルダ・ピン留め。
        var includeSmartLibrary: Bool = true
        /// ファイルブラウザのよく使う項目と自動リネームの規則。
        var includeFileBrowser: Bool = true
        /// 環境設定(`AppPreferences` / `AppearanceSettings` / キー・マウスの割り当て)。
        var includeSettings: Bool = false
    }

    /// 本ごとのデータ以外を読み書きするための持ち主(2026-09-23 に足した 4 カテゴリだけが使う)。
    ///
    /// **省略できる**(nil ならその 4 カテゴリは書き出さない・取り込まない)。「ブックマーク・
    /// レイアウトの編集」など、これらに用の無い画面の呼び出しをそのままにしておくため。
    @MainActor
    struct BackupStores {
        /// 読書位置(`BookReadingState`)は専用のストアを持たず、共有の `ModelContext` から直に読む
        /// (`QooViewerApp.modelContainer.mainContext`。CLAUDE.md: 別の `ModelContext` を作らないこと)。
        var modelContext: ModelContext
        var smartLibrary: SmartLibraryStore
        var favoriteLocations: FavoriteLocationStore
        var autoRename: AutoRenameStore
        var preferences: AppPreferences
        var keyBindings: KeyBindingStore
        /// 環境設定の保存先。テストは専用の suite を渡す。
        var defaults: UserDefaults = .standard
        /// シークレットフォルダ(formatVersion 7。「環境設定」のカテゴリと一緒に運ぶ)。nil なら書き出さない・取り込まない。
        var secretFolders: SecretFolderStore? = nil
    }

    struct ExportResult {
        /// ブックマークはあるがファイルが見つからずページキーへ変換できなかった本のbookID(=ファイル
        /// パス)一覧。
        var skippedBookmarkBookIDs: [String] = []
        /// レイアウト設定はあるが、ファイルが見つからなかった本のbookID(=ファイルパス)一覧
        /// (エクスポート自体は行う)。
        var skippedLayoutsBookIDs: [String] = []

        /// ユーザー要望: エクスポート画面下部に、見つからなかったファイルのパスをカテゴリ
        /// (ブックマーク/レイアウト)をまたいで重複なく1つのリストにまとめて
        /// 表示したい。以前は「N冊はファイルが見つからなかったためスキップしました」という
        /// カテゴリごとの件数だけの文言だったが、同じファイルが複数カテゴリで見つからない
        /// 場合に何度も似た文言が出てしまい分かりづらかったため、実際のパスへ差し替える。
        var allSkippedFilePaths: [String] {
            Array(Set(skippedBookmarkBookIDs + skippedLayoutsBookIDs)).sorted()
        }
    }

    /// - Parameter cachesPageList: 取り込み/書き出しの途中で読み直す本を、ページ一覧の
    ///   ディスクキャッシュ(BookPageListCache)へ書き戻すかどうか。単体テストはここをfalseに
    ///   して、実物のアプリと同じ保存先(テストはTEST_HOST=実物のアプリの中で走る)へ
    ///   テスト用の本の痕跡を残さないようにする。通常の経路(取り込み/書き出しウインドウ)は
    ///   既定のtrueのまま ―― 一度読んだ本のページ一覧は、次に開くときの近道として残しておく。
    static func buildExportFile(
        selection: ExportSelection,
        bookmarkStore: BookmarkStore,
        layoutStore: LayoutStore,
        metadataStore: BookMetadataStore,
        metadataRulesStore: MetadataRulesStore,
        collectionStore: CollectionStore,
        backupStores: BackupStores? = nil,
        cachesPageList: Bool = true
    ) async -> (QooLibraryExportFile, ExportResult) {
        var file = QooLibraryExportFile()
        var result = ExportResult()

        if selection.includeBookmarks {
            let (bookmarks, skipped) = await exportBookmarks(
                bookmarkStore: bookmarkStore, layoutStore: layoutStore,
                cachesPageList: cachesPageList
            )
            file.bookmarks = bookmarks
            result.skippedBookmarkBookIDs = skipped
        }
        if selection.includeLayouts {
            let (layouts, skipped) = await exportLayouts(layoutStore: layoutStore)
            file.layouts = layouts
            result.skippedLayoutsBookIDs = skipped
        }
        if selection.includeMetadata {
            file.metadata = exportMetadata(metadataStore: metadataStore)
        }
        if selection.includeMetadataRules {
            file.metadataRules = metadataRulesStore.exportableRulesBundle
        }
        if selection.includeCollections {
            file.libraries = await exportCollections(collectionStore: collectionStore)
        }
        if let backupStores {
            if selection.includeReadingStates {
                file.readingStates = await exportReadingStates(
                    modelContext: backupStores.modelContext,
                    bookmarkStore: bookmarkStore, layoutStore: layoutStore
                )
            }
            if selection.includeSmartLibrary {
                file.smartLibrary = exportSmartLibrary(store: backupStores.smartLibrary)
            }
            if selection.includeFileBrowser {
                file.fileBrowser = ExportedFileBrowser(
                    favoriteLocationPaths: backupStores.favoriteLocations.items.map(\.path),
                    autoRenameRules: backupStores.autoRename.rules.map(ExportedAutoRenameRule.init),
                    startupFavoritePath: backupStores.favoriteLocations
                        .item(idString: backupStores.preferences.fileBrowserStartupFavoriteID)?.path
                )
            }
            if selection.includeSettings {
                file.settings = SettingsBackup.export(from: backupStores.defaults)
                file.secretFolders = backupStores.secretFolders?.folders
            }
        }
        return (file, result)
    }

    // MARK: - 読書位置の書き出し(2026-09-23)

    /// 読書位置をすべて書き出す。`BookReadingState` はファイルノード識別子を持たないので、
    /// 同じ本のレイアウト設定が覚えているものを使い、無ければその場で実ファイルから取る
    /// (`exportLayouts` と同じ手順)。識別子が取れなくても bookID(パス)で書き出す ――
    /// メタデータと同じで、実ファイルが今そこに無くても書き出せることに意味がある。
    private static func exportReadingStates(
        modelContext: ModelContext,
        bookmarkStore: BookmarkStore, layoutStore: LayoutStore
    ) async -> [ExportedBookReadingState] {
        let states = (try? modelContext.fetch(FetchDescriptor<BookReadingState>())) ?? []
        // 行の値は待つ前に写し取る(待っている間にほかの窓が行を消しうる)。
        var entries: [ExportedBookReadingState] = []
        var hints: [(index: Int, hint: BookLocatorHints)] = []
        for state in states {
            let identifier = layoutStore.bookLayoutSettings(forBookID: state.bookID)?.fileNodeIdentifier
            if identifier == nil {
                hints.append((entries.count, bookLocatorHints(
                    bookID: state.bookID, fileNodeIdentifier: nil,
                    bookmarkStore: bookmarkStore, layoutStore: layoutStore
                )))
            }
            entries.append(ExportedBookReadingState(
                bookID: state.bookID,
                inodeNumber: identifier?.inodeNumber,
                volumeDeviceNumber: identifier?.volumeDeviceNumber,
                volumeUUID: identifier?.volumeUUID,
                lastPageIndex: state.lastPageIndex,
                lastPageKey: state.lastPageKey,
                displayMode: state.displayModeRaw,
                readingDirection: state.readingDirectionRaw,
                scalingMode: state.scalingModeRaw,
                updatedAt: state.updatedAt,
                recordedPageCount: state.recordedPageCount,
                recordedSourceModificationDate: state.recordedSourceModificationDate,
                recordedSourceFileSize: state.recordedSourceFileSize,
                isAtLastPage: state.isAtLastPage ? true : nil
            ))
        }
        // 識別子の取れない本の場所探しと識別子の取得は、まとめて `FileIO` の上で(`locateAll`)。
        let located = await locateAll(hints.map(\.hint), identifies: true)
        for (pending, found) in zip(hints, located) {
            guard let identifier = found?.identifier else { continue }
            entries[pending.index].inodeNumber = identifier.inodeNumber
            entries[pending.index].volumeDeviceNumber = identifier.volumeDeviceNumber
            entries[pending.index].volumeUUID = identifier.volumeUUID
        }
        return entries.sorted { $0.bookID < $1.bookID }
    }

    // MARK: - スマートライブラリの書き出し(2026-09-23)

    private static func exportSmartLibrary(store: SmartLibraryStore) -> ExportedSmartLibrary {
        var pins: [String: [SmartFacetValue]] = [:]
        for (field, values) in store.pins where !values.isEmpty {
            pins[field.rawValue] = values
        }
        return ExportedSmartLibrary(
            shelves: store.shelves, folderPaths: store.folders.map(\.path), pins: pins
        )
    }

    // MARK: - 書誌メタデータの書き出し

    /// 登録済みのメタデータをすべて書き出す。
    ///
    /// 他のカテゴリと違い「ファイルが見つからなかった本」を集めていない(ExportResultへも
    /// 積まない)。メタデータは本の中身に一切依存しない情報で、書き出すために実ファイルを
    /// 開く必要が無く、ファイルが今そこにあるかどうかは書き出せるかどうかに影響しないため。
    private static func exportMetadata(metadataStore: BookMetadataStore) -> [ExportedBookMetadataEntry] {
        metadataStore.allMetadata()
            .map(ExportedBookMetadataEntry.init)
            // 出力の並びを安定させる(allMetadata()は辞書の値のため順不同)。同じ内容の
            // ライブラリから書き出したJSONが毎回同じ並びになり、差分を取りやすい。
            .sorted { $0.bookID < $1.bookID }
    }

    // MARK: - 本の場所を探す

    // bookIDからこの本のURLを解決する(以前の `resolveURL`)。
    //
    // ユーザー要望: iノード番号による管理に変更したい。ファイルノード識別子(fileNodeIdentifier)が
    // 分かっている場合は、まずそれを手がかりに(レイアウト/ブックマークいずれかの)
    // ローカルのセキュリティスコープ付きブックマークから現在の実際のURLを解決できないか試す。
    // この方法なら、エクスポート後にファイルがリネーム・移動されていても正しく解決できる
    // (JSONのbookID(パス)は参考情報として残すが、この解決処理では優先して使わない)。
    // 手がかりが無い/見つからない場合のみ、従来通りbookID(パス)に基づく解決(ブックマーク由来・
    // レイアウト由来のどちらかのセキュリティスコープ付きブックマーク、それも無ければ生パス)にフォールバックする。
    //
    // ■ 解決はメインの外でまとめて(2026-10-11 の規約監査)
    // 以前は `resolveURL` がメインで同期に、1 冊ごとにブックマークを解いて存在を確かめていた(書き出し・取り込みの全カテゴリで、
    // 本の数だけ)。応答しない共有の上の本が 1 冊あるだけで、その 1 冊で約 30 秒メインが止まった。いまはコレクションの取り込み
    // (2026-09-13)と同じ形 ―― メインでは手がかり(ブックマークのバイト列)を集めるだけ(`bookLocatorHints`)、解決と存在確認・
    // 識別子の取得は `FileIO` の上で(`locate` / `locateAll`)。手がかりの優先順は以前と同じ(識別子が一致する
    // レイアウト → ブックマーク、次に bookID のブックマーク → レイアウト、最後に記録したパス。2026-10-24 までは識別子が一致する
    // お気に入りが先頭だった)。違いは、確かめる前にセキュリティスコープを開くこと(許可の無い場所の本も見つかる。
    // StoredBookLocator と同じ)。

    /// 手がかりで見つけた本の場所。
    nonisolated struct LocatedBook: Sendable {
        let url: URL
        /// 見つけた場所の今の識別子(`locate(_:identifies:)` に true を渡したときだけ)。
        let identifier: FileNodeIdentifier?
    }

    /// 手がかりから本の場所を探す。**ブロッキングする**(ボリュームへの問い合わせ)ので、`FileIO` の上で呼ぶ。
    ///
    /// - Parameter identifies: 見つけた場所の識別子も求めるか(スコープを開いている間に求める)。
    nonisolated static func locate(_ hints: BookLocatorHints, identifies: Bool) -> LocatedBook? {
        for data in hints.bookmarks {
            guard let url = BookmarkResolution.resolve(data) else { continue }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            return LocatedBook(url: url, identifier: identifies ? FileNodeIdentifier.current(for: url) : nil)
        }
        guard hints.fallsBackToRecordedPath else { return nil }
        let recorded = URL(fileURLWithPath: hints.bookID)
        guard FileManager.default.fileExists(atPath: recorded.path) else { return nil }
        return LocatedBook(url: recorded, identifier: identifies ? FileNodeIdentifier.current(for: recorded) : nil)
    }

    /// 何冊ぶんもまとめて、1 回の `FileIO` で探す(並びは `hints` のまま)。
    static func locateAll(_ hints: [BookLocatorHints], identifies: Bool) async -> [LocatedBook?] {
        guard !hints.isEmpty else { return [] }
        return await FileIO.perform(qos: .utility) { hints.map { locate($0, identifies: identifies) } }
    }

    /// 1 冊ぶんの手がかりを集める(解決はしない。メインで DB を読むだけ)。
    ///
    /// - Parameter indexes: 識別子で引く索引(`FileNodeIndexes`)。行を書き換えない段でだけ渡す。nil なら全行から(答えは同じ)。
    /// - Parameter collectionStore: 渡せば、識別子が一致するコレクションの行のブックマークも最後に試す(コレクションの取り込み)。
    private static func bookLocatorHints(
        bookID: String, fileNodeIdentifier: FileNodeIdentifier?,
        bookmarkStore: BookmarkStore, layoutStore: LayoutStore,
        collectionStore: CollectionStore? = nil, indexes: FileNodeIndexes? = nil
    ) -> BookLocatorHints {
        var bookmarks: [Data] = []
        if let fileNodeIdentifier {
            bookmarks += layoutStore.bookmarkDataCandidates(matching: fileNodeIdentifier, index: indexes?.layouts)
            bookmarks += bookmarkStore.bookmarkDataCandidates(matching: fileNodeIdentifier, index: indexes?.bookmarks)
        }
        bookmarks += bookmarkStore.bookmarks(forBookID: bookID).compactMap(\.bookmarkData)
        if let data = layoutStore.bookLayoutSettings(forBookID: bookID)?.bookmarkData {
            bookmarks.append(data)
        }
        if let fileNodeIdentifier, let collectionStore {
            bookmarks += collectionStore.bookmarkDataCandidates(matching: fileNodeIdentifier, index: indexes?.collections)
        }
        return BookLocatorHints(bookID: bookID, bookmarks: bookmarks)
    }

    /// 取り込む全件の手がかりを集める(行を書き換えない段の頭で。識別子の索引を作って使い、ときどきメインを譲る ―― 譲った後は
    /// 索引を取り直す。`yieldPeriodically`)。
    private static func gatherHints(
        _ books: [(bookID: String, identifier: FileNodeIdentifier?)],
        bookmarkStore: BookmarkStore, layoutStore: LayoutStore
    ) async -> [BookLocatorHints] {
        var indexes = FileNodeIndexes(layoutStore: layoutStore, bookmarkStore: bookmarkStore)
        var hints: [BookLocatorHints] = []
        hints.reserveCapacity(books.count)
        for (index, book) in books.enumerated() {
            if await yieldPeriodically(index) {
                indexes = FileNodeIndexes(layoutStore: layoutStore, bookmarkStore: bookmarkStore)
            }
            hints.append(bookLocatorHints(
                bookID: book.bookID, fileNodeIdentifier: book.identifier,
                bookmarkStore: bookmarkStore, layoutStore: layoutStore, indexes: indexes
            ))
        }
        return hints
    }

    /// 識別子で行を引く索引を、取り込みの 1 段ぶん作ったもの(2026-10-05 の効率の監査 A5)。以前は 1 件ごとに各ストアの全行を
    /// なめ直し(読み込むメタデータの行数 × ほかのストアの行数)、メインを止めた。**その段の間、レイアウト・ブックマーク・
    /// コレクションの行を書き換えないときだけ**使う(メタデータ・読書位置の取り込み、コレクションの取り込みの手がかり集め)。
    private struct FileNodeIndexes {
        let layouts: FileNodeIndex<BookLayoutSettings>
        let bookmarks: FileNodeIndex<Bookmark>
        var collections: FileNodeIndex<CollectionItem>?

        @MainActor
        init(layoutStore: LayoutStore, bookmarkStore: BookmarkStore, collectionStore: CollectionStore? = nil) {
            layouts = layoutStore.fileNodeIndex()
            bookmarks = bookmarkStore.fileNodeIndex()
            collections = collectionStore?.fileNodeIndex()
        }
    }

    /// bookIDの本を実際に読み込む(URL解決 + セキュリティスコープの開始/終了 + BookLoader)。
    /// 失敗した場合(URLが解決できない/ファイルが見つからない/読み込みエラー)はnilを返す。
    ///
    /// 場所の解決と、読み込んだ本の居場所の事実(識別子・指紋・ブックマーク。`BookSourceFacts`)は `FileIO` の上で求める
    /// (`resolveURL` から置き換えた節のコメント)。返す本の `sourceFacts` が埋まっているので、レイアウトの行を作る書き込み
    /// (`LayoutStore.applyImportedLayout`)もメインでファイルに触らない。
    ///
    /// - Parameter makesBookmark: 行に添えるブックマークも作るか(レイアウトの取り込み ―― 行を作る ―― だけ。識別子しか使わない
    ///   ブックマークの書き出し・取り込みでは作らない)。
    private static func loadBook(
        bookID: String, fileNodeIdentifier: FileNodeIdentifier?,
        bookmarkStore: BookmarkStore, layoutStore: LayoutStore,
        cachesPageList: Bool, makesBookmark: Bool
    ) async -> MangaBook? {
        // StackNest の参照ファイルの本は、保存データの書き出しでも読み込みでも本を読み込まない(読み込みは StackNest へ問い合わせる。
        // 読み込みでは `apply` が先に外している ―― removingStackNestBooks)。
        guard !isStackNestReferenceFile(bookID) else { return nil }
        let hints = bookLocatorHints(
            bookID: bookID, fileNodeIdentifier: fileNodeIdentifier,
            bookmarkStore: bookmarkStore, layoutStore: layoutStore
        )
        guard let url = await FileIO.perform(qos: .utility, { locate(hints, identifies: false)?.url }) else { return nil }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard var book = try? await BookLoader.load(from: url, cachesPageList: cachesPageList) else { return nil }
        let sourceURL = book.sourceURL
        book.sourceFacts = await FileIO.perform(qos: .utility) { BookSourceFacts.probe(sourceURL, makesBookmark: makesBookmark) }
        return book
    }

    private static func exportBookmarks(
        bookmarkStore: BookmarkStore, layoutStore: LayoutStore,
        cachesPageList: Bool
    ) async -> ([ExportedBookmarkEntry], [String]) {
        var result: [ExportedBookmarkEntry] = []
        var skipped: [String] = []

        for group in bookmarkStore.groups {
            // 行(SwiftData のモデル)は**待つ前に値へ写す**(2026-10-25 のハング・クラッシュの監査 A6-4)。下の loadBook は本を
            // 読み込むので数秒待ちうる。その間にこの本のブックマークが消される(ビューアのトグル・編集ウインドウ・「差し替わった本」の
            // 片付け)と、待った後に消えた行を読んで落ちうる。ほかの書き出し(読書位置・レイアウト・コレクション)は先に写していた。
            let bookmarks = bookmarkStore.bookmarks(forBookID: group.bookID)
                .sorted { $0.pageIndex < $1.pageIndex }
                .map { (pageKey: $0.pageKey, pageIndex: $0.pageIndex, name: $0.name) }
            guard !bookmarks.isEmpty else { continue }
            // 同じbookIDのBookmark行はすべて同じファイルノード識別子を記録しているはずのため、
            // 最初に見つかった値をこの本の識別子として使う(1件も記録が無い場合はnilのまま)。
            var fileNodeIdentifier = bookmarkStore.bookmarks(forBookID: group.bookID).lazy.compactMap(\.fileNodeIdentifier).first
            guard let book = await loadBook(
                bookID: group.bookID, fileNodeIdentifier: fileNodeIdentifier,
                bookmarkStore: bookmarkStore, layoutStore: layoutStore,
                cachesPageList: cachesPageList, makesBookmark: false
            ) else {
                skipped.append(group.bookID)
                continue
            }
            // ユーザー要望(後方互換性): この本のブックマークに1件も識別子が無かった場合でも、
            // 本自体は(パスなどを手がかりに)実際に読み込めている=実在が確認できているため、
            // 今読み込めたbook.sourceURLから識別子を取得し直し、書き出すJSONに含める。
            // ついでにDB側の該当行にも補完しておく(BookmarkStore.backfillFileNodeIdentifier参照。
            // 次回以降のエクスポートで再び同じ手間をかけずに済む)。
            // 識別子は読み込みと一緒に FileIO の上で求めてある(`loadBook` の `sourceFacts`)。
            if fileNodeIdentifier == nil {
                fileNodeIdentifier = book.sourceFacts?.fileNodeIdentifier
                if let fileNodeIdentifier {
                    bookmarkStore.backfillFileNodeIdentifier(forBookID: group.bookID, identifier: fileNodeIdentifier)
                }
            }
            let settings = layoutStore.bookLayoutSettings(forBookID: group.bookID)
            let excludedKeys = Set(
                layoutStore.pageOverrides(forBookID: group.bookID)
                    .filter { $0.state == .excluded }
                    .map(\.pageKey)
            )
            // 鍵を持っていればそれが権威(Bookmark.pageKey参照)。持っていない古い行だけ、
            // 番号から引く ―― ただしその番号は**従来順**で記録されているため、今の実効順で
            // 引くと別のページの鍵を書き出してしまう(BookExportViewModel.exportOneの
            // 同種の変換と同じ規則。あちらに施した修正がここだけ漏れていた)。
            let legacyOrderedKeys = EffectivePageOrder.legacyOrderedPageKeys(
                for: book, pageOrderOverride: settings?.pageOrderOverride, excludedKeys: excludedKeys
            )
            var entries: [ExportedBookmark] = []
            for bookmark in bookmarks {
                if let key = bookmark.pageKey {
                    entries.append(ExportedBookmark(page: key, name: bookmark.name))
                    continue
                }
                guard legacyOrderedKeys.indices.contains(bookmark.pageIndex) else { continue }
                entries.append(ExportedBookmark(page: legacyOrderedKeys[bookmark.pageIndex], name: bookmark.name))
            }
            guard !entries.isEmpty else { continue }
            result.append(
                ExportedBookmarkEntry(
                    bookID: group.bookID,
                    inodeNumber: fileNodeIdentifier?.inodeNumber,
                    volumeDeviceNumber: fileNodeIdentifier?.volumeDeviceNumber,
                    volumeUUID: fileNodeIdentifier?.volumeUUID,
                    bookmarks: entries
                )
            )
        }
        return (result, skipped)
    }

    /// レイアウト設定はpageKeyをそのまま使うため、本を読み込み直す必要が無く軽量に書き出せる。
    ///
    /// ユーザー要望(後方互換性): 識別子を持たない古いBookLayoutSettings行についても、
    /// LayoutStore.resolvedURL(bookmarkData:bookID:)(FileIO の上)でファイルの実在が確認できる場合は、そこから
    /// 改めて識別子を取得してJSONに含める(ついでにDB側にも補完しておく。exportBookmarksの
    /// 同種の処理と同じ理由)。resolvedURL自体はbookmarkDataの解決またはbookIDの生パスへの
    /// フォールバックのどちらもfileExistsで確認済みのURLしか返さないため、ここで本自体を
    /// 読み込み直す(BookLoader)必要は無い。
    ///
    /// 存在の確かめと識別子の取得は、まとめて `FileIO` の上で(2026-10-11 の規約監査。以前は 1 冊ごとにメインで解いていた)。
    private static func exportLayouts(layoutStore: LayoutStore) async -> ([ExportedBookLayoutEntry], [String]) {
        // 行の値は待つ前に写し取る(待っている間にほかの窓が行を消しうる)。
        var entries: [ExportedBookLayoutEntry] = []
        var probes: [(bookmarkData: Data?, bookID: String, needsIdentifier: Bool)] = []
        for bookID in layoutStore.layoutBookIDs {
            let settings = layoutStore.bookLayoutSettings(forBookID: bookID)
            let overrides = layoutStore.pageOverrides(forBookID: bookID)
            guard settings != nil || !overrides.isEmpty else { continue }

            let fileNodeIdentifier = settings?.fileNodeIdentifier
            probes.append((settings?.bookmarkData, bookID, fileNodeIdentifier == nil))

            var pages: [String: ExportedPageState] = [:]
            for override in overrides {
                pages[override.pageKey] = ExportedPageState(state: override.state.rawValue)
            }
            entries.append(
                ExportedBookLayoutEntry(
                    bookID: bookID,
                    inodeNumber: fileNodeIdentifier?.inodeNumber,
                    volumeDeviceNumber: fileNodeIdentifier?.volumeDeviceNumber,
                    volumeUUID: fileNodeIdentifier?.volumeUUID,
                    layout: ExportedBookLayout(
                        readingDirection: settings?.readingDirectionOverride?.stableID,
                        forcedDisplayMode: settings?.forcedDisplayMode?.stableID,
                        pageOrder: settings?.pageOrderOverride,
                        pages: pages.isEmpty ? nil : pages
                    )
                )
            )
        }

        // (見つかったか, 今の識別子)。識別子は記録に無い本だけ求める。
        let sendableProbes = probes
        let probed: [(found: Bool, identifier: FileNodeIdentifier?)] = await FileIO.perform(qos: .utility) {
            sendableProbes.map { probe in
                guard let url = LayoutStore.resolvedURL(bookmarkData: probe.bookmarkData, bookID: probe.bookID) else {
                    return (false, nil)
                }
                guard probe.needsIdentifier else { return (true, nil) }
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                return (true, FileNodeIdentifier.current(for: url))
            }
        }

        // ユーザー要望: ファイルが見つからなかった本のパスを、書き出しの画面の下にまとめて出すために
        // 集めておく(レイアウト設定自体は従来通り、実ファイルの有無に関わらずエクスポートする)。
        var skipped: [String] = []
        for (index, result) in probed.enumerated() {
            let bookID = probes[index].bookID
            if let identifier = result.identifier {
                entries[index].inodeNumber = identifier.inodeNumber
                entries[index].volumeDeviceNumber = identifier.volumeDeviceNumber
                entries[index].volumeUUID = identifier.volumeUUID
                layoutStore.backfillFileNodeIdentifier(forBookID: bookID, identifier: identifier)
            }
            if !result.found {
                skipped.append(bookID)
            }
        }
        return (entries, skipped)
    }

    // MARK: - コレクションの書き出し

    /// ライブラリ → コレクション → 本を、ストアの公開APIだけを経由して書き出す。
    ///
    /// レイアウトと違い「ファイルが見つからなかった本」を`ExportResult`へ積まない ―― 参考情報
    /// (パス・タイトル・追加日時)だけで書き出せるうえ、書き出しのたびに全冊ぶんのブックマーク
    /// 解決を走らせると、未接続のボリューム上の本があるだけで1件あたり秒単位ブロックしうる。
    /// 識別子を持たない古い行についてだけ、実体を1回探して補完する(exportLayoutsの同種の
    /// 処理と同じ理由)。
    ///
    /// 並びは追加日時の昇順で固定する。同じ内容のライブラリから書き出したJSONが毎回同じ並びに
    /// なり、差分を取りやすい(exportMetadataがbookID順に揃えているのと同じ理由)。
    ///
    /// 識別子を持たない行の実体探しと識別子の取得は、まとめて `FileIO` の上で(2026-10-11 の規約監査。以前は 1 冊ごとにメインで
    /// 解いていた)。
    private static func exportCollections(collectionStore: CollectionStore) async -> [ExportedLibrary] {
        // 行の値は待つ前に写し取る(待っている間にほかの窓が行を消しうる)。識別子の欄は後から埋める。
        var missing: [(path: [Int], bookID: String, bookmarkData: Data)] = []
        var libraries: [ExportedLibrary] = []
        for library in collectionStore.libraries {
            var collections: [ExportedCollection] = []
            // 並びそのものには指定を効かせない(applyingPins: false)。ここは差分を取りやすく
            // するための固定の並びで、画面の見え方とは別物。
            for collection in collectionStore.collections(in: library, sort: .dateAddedAscending, applyingPins: false) {
                var books: [ExportedCollectionBook] = []
                for item in collectionStore.items(in: collection, sort: .dateAddedAscending) {
                    let identifier = item.fileNodeIdentifier
                    if identifier == nil {
                        missing.append(([libraries.count, collections.count, books.count], item.bookID, item.bookmarkData))
                    }
                    books.append(ExportedCollectionBook(
                        bookID: item.bookID,
                        inodeNumber: identifier?.inodeNumber,
                        volumeDeviceNumber: identifier?.volumeDeviceNumber,
                        volumeUUID: identifier?.volumeUUID,
                        title: item.title,
                        addedAt: item.addedAt
                    ))
                }
                collections.append(ExportedCollection(
                    name: collection.name,
                    createdAt: collection.createdAt,
                    autoFolderPath: collection.autoFolderPath,
                    books: books
                ))
            }
            libraries.append(ExportedLibrary(
                // 既定のライブラリは表示言語の見出しで書き出す(DBの文字列は表示に使って
                // いないため。BookLibrary.displayName参照)。
                name: library.displayName(language: AppLanguage.currentLocale),
                coverAspectRatio: library.coverAspectRatio.rawValue,
                coverCropAnchor: library.coverCropAnchor.rawValue,
                coverFit: library.coverFit.rawValue,
                // 常に先頭/末尾の指定は**名前で**書き出す(ExportedLibrary.pinnedFirstCollection)。
                pinnedFirstCollection: collectionStore.pinnedFirstCollection(in: library)?.name,
                pinnedLastCollection: collectionStore.pinnedLastCollection(in: library)?.name,
                collections: collections
            ))
        }

        let bookmarks = missing.map(\.bookmarkData)
        let identifiers: [FileNodeIdentifier?] = await FileIO.perform(qos: .utility) {
            bookmarks.map { data in
                guard let url = CollectionStore.existingURL(fromBookmark: data) else { return nil }
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                return FileNodeIdentifier.current(for: url)
            }
        }
        for (pending, identifier) in zip(missing, identifiers) {
            guard let identifier else { continue }
            let (l, c, b) = (pending.path[0], pending.path[1], pending.path[2])
            libraries[l].collections[c].books[b].inodeNumber = identifier.inodeNumber
            libraries[l].collections[c].books[b].volumeDeviceNumber = identifier.volumeDeviceNumber
            libraries[l].collections[c].books[b].volumeUUID = identifier.volumeUUID
            collectionStore.backfillFileNodeIdentifier(forBookID: pending.bookID, identifier: identifier)
        }
        return libraries
    }

    // MARK: - JSONの読み書き

    /// 符号化はここ(メイン。JSON の型の `Codable` はメインに分離されている)、書き込みは FileIO の上で(保存先が応答しない共有でも
    /// メインを止めない。2026-10-05 の効率の監査 A4)。
    static func write(_ file: QooLibraryExportFile, to url: URL) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try await FileIO.perform { try data.write(to: url, options: .atomic) }
    }

    /// 読み込みは FileIO の上で、復号はここ(メイン)で(`write` と同じ分け方。2026-10-11 の規約監査 ―― 以前はパネルの完了ハンドラ
    /// から同期で読み、選んだファイルが応答しない共有の上だとメインが止まった)。
    static func read(from url: URL) async throws -> QooLibraryExportFile {
        let data = try await FileIO.perform { try Data(contentsOf: url) }
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
        var bookmarks: ImportPolicy = .merge
        var layouts: ImportPolicy = .merge
        var metadata: ImportPolicy = .merge
        /// 規則(qooMeta。以前はフォーマット定義)は「アプリ全体で1組の設定」であって本ごとのデータではないため、
        /// mergeという概念が無い(2つの差分を混ぜても意味のある結果にならない)。
        /// overwrite(丸ごと差し替え)かignore(取り込まない)の2択として扱い、UIでもそのように
        /// 出し分ける(LibraryImportWindow参照)。既定はignore = 相手の規則で
        /// 自分の設定を勝手に置き換えない、という安全側。
        var metadataRules: ImportPolicy = .ignore
        /// コレクション(改善要望5)。overwriteはライブラリ・コレクション・登録した本を
        /// すべて消してから取り込む(カバー画像も消える)。
        var collections: ImportPolicy = .merge
        /// 読書位置(2026-09-23)。merge は読書位置をまだ持っていない本にだけ入れる。
        var readingStates: ImportPolicy = .merge
        /// スマートライブラリ(2026-09-23)。overwrite は手元のスマートコレクション・対象フォルダ・
        /// ピン留めを捨ててから入れる。
        var smartLibrary: ImportPolicy = .merge
        /// ファイルブラウザのよく使う項目と自動リネームの規則(2026-09-23)。
        var fileBrowser: ImportPolicy = .merge
        /// 環境設定(2026-09-23)。規則(metadataRules)と同じく「アプリ全体で1組の設定」なので
        /// merge という概念が無く、overwrite(書いてあるキーだけ上書き)か ignore の2択。
        /// 既定は ignore ―― 相手の設定で自分の設定を勝手に置き換えない、という安全側。
        var settings: ImportPolicy = .ignore
    }

    /// 取り込むファイルから、StackNest の本(参照ファイルのパスの本)をすべてのカテゴリで外す(`apply` のコメント)。外した本の bookID も返す。
    static func removingStackNestBooks(from file: QooLibraryExportFile) -> (QooLibraryExportFile, Set<String>) {
        var file = file
        var removed = Set<String>()
        func keeps(_ bookID: String) -> Bool {
            guard isStackNestReferenceFile(bookID) else { return true }
            removed.insert(bookID)
            return false
        }
        file.bookmarks = file.bookmarks?.filter { keeps($0.bookID) }
        file.layouts = file.layouts?.filter { keeps($0.bookID) }
        file.metadata = file.metadata?.filter { keeps($0.bookID) }
        file.readingStates = file.readingStates?.filter { keeps($0.bookID) }
        if var libraries = file.libraries {
            for libraryIndex in libraries.indices {
                for collectionIndex in libraries[libraryIndex].collections.indices {
                    libraries[libraryIndex].collections[collectionIndex].books.removeAll { !keeps($0.bookID) }
                }
            }
            file.libraries = libraries
        }
        return (file, removed)
    }

    struct ImportSummary {
        /// StackNest の本なので読み込まなかった本の数(`removingStackNestBooks`)。
        var stackNestSkippedBooks = 0
        var bookmarksImportedBooks = 0
        var bookmarksImportedEntries = 0
        var bookmarksSkippedBookIDs: [String] = []
        var layoutsImportedBooks = 0
        var layoutsSkippedBookIDs: [String] = []
        var metadataImportedBooks = 0
        var didImportMetadataRules = false
        /// 規則を読めずに取り込まなかったときの理由(なければ空)。
        var metadataRuleErrors: [String] = []
        var collectionsImportedLibraries = 0
        var collectionsImportedCollections = 0
        var collectionsImportedBooks = 0
        /// 実体が見つからず、コレクションへ入れられなかった本のbookID(=JSON上のパス)。
        var collectionsSkippedBookIDs: [String] = []
        // 2026-09-23 に足したカテゴリ。
        var readingStatesImportedBooks = 0
        var smartLibraryImportedShelves = 0
        var smartLibraryImportedFolders = 0
        var fileBrowserImportedLocations = 0
        var fileBrowserImportedAutoRenameRules = 0
        /// 取り込んだ環境設定の数(`UserDefaults` のキーの数)。
        var importedSettingsCount = 0
        /// 新しく足したシークレットフォルダの数(formatVersion 7)。
        var importedSecretFolderCount = 0
    }

    /// - Parameter cachesPageList: 取り込み/書き出しの途中で読み直す本を、ページ一覧の
    ///   ディスクキャッシュ(BookPageListCache)へ書き戻すかどうか。単体テストはここをfalseに
    ///   して、実物のアプリと同じ保存先(テストはTEST_HOST=実物のアプリの中で走る)へ
    ///   テスト用の本の痕跡を残さないようにする。通常の経路(取り込み/書き出しウインドウ)は
    ///   既定のtrueのまま ―― 一度読んだ本のページ一覧は、次に開くときの近道として残しておく。
    static func apply(
        _ file: QooLibraryExportFile,
        policies: ImportPolicies,
        bookmarkStore: BookmarkStore,
        layoutStore: LayoutStore,
        metadataStore: BookMetadataStore,
        metadataRulesStore: MetadataRulesStore,
        collectionStore: CollectionStore,
        backupStores: BackupStores? = nil,
        cachesPageList: Bool = true
    ) async -> ImportSummary {
        var summary = ImportSummary()
        // StackNest の本(参照ファイル)には保存データを残さない(MangaBook.leavesNoRecord)。取り込むファイルにあっても、どのカテゴリでも
        // 読み込まない(本を読み込むカテゴリは StackNest へ問い合わせることにもなる)。飛ばした冊数は結果に出す(見つからなかった本とは
        // 分けて数える)。
        let (file, stackNestBookIDs) = Self.removingStackNestBooks(from: file)
        summary.stackNestSkippedBooks = stackNestBookIDs.count

        if let libraries = file.libraries, policies.collections != .ignore {
            await applyCollections(
                libraries, policy: policies.collections,
                collectionStore: collectionStore,
                bookmarkStore: bookmarkStore, layoutStore: layoutStore,
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
                layoutStore: layoutStore, bookmarkStore: bookmarkStore,
                cachesPageList: cachesPageList, summary: &summary
            )
        }
        if let bookmarks = file.bookmarks, policies.bookmarks != .ignore {
            await applyBookmarks(
                bookmarks, policy: policies.bookmarks,
                bookmarkStore: bookmarkStore, layoutStore: layoutStore,
                cachesPageList: cachesPageList, summary: &summary
            )
        }
        if let metadata = file.metadata, policies.metadata != .ignore {
            await applyMetadata(
                metadata, policy: policies.metadata,
                bookmarkStore: bookmarkStore, layoutStore: layoutStore,
                metadataStore: metadataStore, summary: &summary
            )
        }
        if policies.metadataRules != .ignore {
            if let bundle = file.metadataRules {
                summary.metadataRuleErrors = metadataRulesStore.replaceRules(withBundle: bundle)
                summary.didImportMetadataRules = summary.metadataRuleErrors.isEmpty
            } else if let formats = file.metadataFormats {
                // 以前の形(formatVersion 3・4)。ファイル名フォーマットだけを利用者のルールセットとして取り込む
                // (QooLibraryExportFile.formatVersion のコメント)。
                summary.metadataRuleErrors = metadataRulesStore.importLegacyFilenameFormats(formats.filenameFormats)
                summary.didImportMetadataRules = summary.metadataRuleErrors.isEmpty
            }
        }
        if let backupStores {
            if let states = file.readingStates, policies.readingStates != .ignore {
                await applyReadingStates(
                    states, policy: policies.readingStates, modelContext: backupStores.modelContext,
                    bookmarkStore: bookmarkStore, layoutStore: layoutStore,
                    summary: &summary
                )
            }
            if let smart = file.smartLibrary, policies.smartLibrary != .ignore {
                let added = backupStores.smartLibrary.importBackup(
                    shelves: smart.shelves, folderPaths: smart.folderPaths,
                    pins: decodePins(smart.pins), replacingExisting: policies.smartLibrary == .overwrite
                )
                summary.smartLibraryImportedShelves += added.shelves
                summary.smartLibraryImportedFolders += added.folders
            }
            if let browser = file.fileBrowser, policies.fileBrowser != .ignore {
                let replacing = policies.fileBrowser == .overwrite
                summary.fileBrowserImportedLocations += backupStores.favoriteLocations.importBackup(
                    paths: browser.favoriteLocationPaths, replacingExisting: replacing
                )
                summary.fileBrowserImportedAutoRenameRules += backupStores.autoRename.importBackup(
                    rules: browser.autoRenameRules.map(\.rule), replacingExisting: replacing
                )
            }
            // シークレットフォルダは足すだけ(上書きでも外さない。QooLibraryExportFile.secretFolders のコメント)。
            if let secretFolders = file.secretFolders, policies.settings != .ignore, let store = backupStores.secretFolders {
                summary.importedSecretFolderCount = store.importBackup(paths: secretFolders, replacingExisting: false)
            }
            if let settings = file.settings, policies.settings != .ignore {
                summary.importedSettingsCount = SettingsBackup.apply(settings, to: backupStores.defaults)
                // 保存先を書き替えただけでは、画面が握っている値は変わらない。3 つの持ち主へ読み直させる。
                backupStores.preferences.reloadFromDefaults()
                for profile in AppearanceProfile.allCases {
                    let live = profile == .normal
                        ? backupStores.preferences.appearance : backupStores.preferences.privateAppearance
                    live.copyValues(from: AppearanceSettings(profile: profile, defaults: backupStores.defaults))
                }
                backupStores.keyBindings.reloadFromDefaults()
                // ブックマークの並べ方は `UserDefaults.standard` に直に持つ(テストの保存先では読まない ―― 実物の
                // 設定に触らない)。
                if backupStores.defaults === UserDefaults.standard {
                    bookmarkStore.reloadSortOptionsFromDefaults()
                }
            }
            // 「起動時のフォルダ: よく使う項目」の相手を、取り込んだ一覧の id に合わせ直す(2026-10-04 の監査 ST-12。設定の id は
            // 書き出した側の項目のもの)。よく使う項目か設定のどちらかを取り込んだときだけ。
            if (file.fileBrowser != nil && policies.fileBrowser != .ignore) || (file.settings != nil && policies.settings != .ignore) {
                backupStores.favoriteLocations.reconcileStartupFavorite(
                    preferences: backupStores.preferences, exportedPath: file.fileBrowser?.startupFavoritePath
                )
            }
        }
        return summary
    }

    /// 件数ぶんのループ(保存データの読み込みの段)で、ときどきメインを譲る(2026-10-06 の応答性の点検 R4-2)。`Task.yield()` ではなく
    /// 眠る ―― 譲った先がメインキューの同じ汲み出しの中で戻ってくると、入力・描画が挟まらない(`BookMetadataStore.upsertAllInBatches`)。
    ///
    /// - Returns: 譲ったか。**譲った後は、段の頭で取った行の控え(識別子の索引・行の辞書)を取り直すこと** ―― 譲っている間にほかの
    ///   ウインドウが行を消す・作る(本を開いたビューアが読書位置の行を消し直す、など)ので、古い控えのまま使うと消えた行へ書く・
    ///   同じ本の行を 2 つ作る(コードレビュー)。
    @discardableResult
    private static func yieldPeriodically(_ index: Int) async -> Bool {
        guard index > 0, index.isMultiple(of: 200) else { return false }
        try? await Task.sleep(for: .milliseconds(1))
        return true
    }

    /// 書き出した形(欄の `rawValue` → 値)を、ストアの形へ。知らない欄は捨てる。
    private static func decodePins(_ pins: [String: [SmartFacetValue]]) -> [SmartFacetField: [SmartFacetValue]] {
        var result: [SmartFacetField: [SmartFacetValue]] = [:]
        for (key, values) in pins {
            guard let field = SmartFacetField(rawValue: key) else { continue }
            result[field] = values
        }
        return result
    }

    // MARK: - 読書位置の取り込み(2026-09-23)

    /// 取り込むページ番号(`applyReadingStates`)。0 以上、記録されたページ数があれば `0..<pageCount` に丸める。
    static func clampedPageIndex(_ index: Int, pageCount: Int?) -> Int {
        let nonNegative = max(index, 0)
        guard let pageCount, pageCount > 0 else { return nonNegative }
        return min(nonNegative, pageCount - 1)
    }

    /// 読書位置を取り込む。メタデータと同じく、本を読み直す必要が無い(ページ番号も鍵もそのまま
    /// 写すだけ)ので、実ファイルが今そこに無い本の読書位置もそのまま取り込める。
    ///
    /// - overwrite: 同じ本の既存の行を書き替える。
    /// - merge: まだ読書位置を持っていない本にだけ入れる。
    private static func applyReadingStates(
        _ entries: [ExportedBookReadingState], policy: ImportPolicy, modelContext: ModelContext,
        bookmarkStore: BookmarkStore, layoutStore: LayoutStore,
        summary: inout ImportSummary
    ) async {
        func fetchByBookID() -> [String: BookReadingState] {
            let existing = (try? modelContext.fetch(FetchDescriptor<BookReadingState>())) ?? []
            return Dictionary(existing.map { ($0.bookID, $0) }, uniquingKeysWith: { first, _ in first })
        }
        // 他のカテゴリと同じく、ファイルノード識別子での照合を優先する(別の端末・移動後で
        // パスが変わっていても引き継げる)。手がかりはメインで集め(この段は読書位置の行しか書かないので、識別子の索引を作って
        // 使う ―― FileNodeIndexes。メインを譲った後は取り直す)、解決はまとめて FileIO の上で(`locateAll`)。
        let located = await locateAll(await gatherHints(
            entries.map { ($0.bookID, $0.fileNodeIdentifier) },
            bookmarkStore: bookmarkStore, layoutStore: layoutStore
        ), identifies: false)
        var byBookID = fetchByBookID()
        for (index, entry) in entries.enumerated() {
            if await yieldPeriodically(index) {
                // 譲っている間の書き込みを残すため、ここまでの分を保存してから取り直す。
                try? modelContext.save()
                byBookID = fetchByBookID()
            }
            let bookID = located[index]?.url.path ?? entry.bookID
            // フォルダの本のページの鍵は絶対パスなので、本が別のパスで見つかったら鍵も付け替える(PageKeyRelocation。ブックマーク・
            // レイアウトの取り込みと同じ。2026-09-23 の 3 回目の監査の低 ―― 以前はそのまま写し、ページ番号へ落ちていた)。
            let lastPageKey = entry.lastPageKey.map {
                PageKeyRelocation.relocated($0, fromBookID: entry.bookID, toBookID: bookID) ?? $0
            }
            // ページ番号は書かれた値をそのまま信じない(手で直した・壊れた JSON。Int.max がスマートライブラリの進み具合の計算で
            // 溢れた ―― 2026-10-25 のハング・クラッシュの監査 #7)。0 以上、ページ数が分かればその範囲へ丸める。
            let lastPageIndex = Self.clampedPageIndex(entry.lastPageIndex, pageCount: entry.recordedPageCount)
            if let row = byBookID[bookID] {
                guard policy == .overwrite else { continue }
                row.lastPageIndex = lastPageIndex
                row.lastPageKey = lastPageKey
                row.displayModeRaw = entry.displayMode
                row.readingDirectionRaw = entry.readingDirection
                row.scalingModeRaw = entry.scalingMode
                row.updatedAt = entry.updatedAt
                row.recordedPageCount = entry.recordedPageCount
                row.recordedSourceModificationDate = entry.recordedSourceModificationDate
                row.recordedSourceFileSize = entry.recordedSourceFileSize
                row.isAtLastPage = entry.isAtLastPage ?? false
            } else {
                let row = BookReadingState(bookID: bookID, lastPageIndex: lastPageIndex,
                                           lastPageKey: lastPageKey)
                // 生の rawValue で写す(知らない値でも落とさない。読む側が既定へ落とす)。
                row.displayModeRaw = entry.displayMode
                row.readingDirectionRaw = entry.readingDirection
                row.scalingModeRaw = entry.scalingMode
                row.updatedAt = entry.updatedAt
                row.recordedPageCount = entry.recordedPageCount
                row.recordedSourceModificationDate = entry.recordedSourceModificationDate
                row.recordedSourceFileSize = entry.recordedSourceFileSize
                row.isAtLastPage = entry.isAtLastPage ?? false
                modelContext.insert(row)
                byBookID[bookID] = row
            }
            summary.readingStatesImportedBooks += 1
        }
        try? modelContext.save()
    }

    // MARK: - 書誌メタデータの取り込み

    /// メタデータを取り込む。
    ///
    /// 他のカテゴリと異なり、本を読み込む必要が無い(ページキーへの変換が要らない)ため、
    /// ファイルが今そこに無い本のメタデータもそのまま取り込める。これは意図した挙動で、
    /// 「外付けボリュームを繋いでいない状態で別マシンの設定を取り込む」ような使い方ができる。
    ///
    /// - overwrite: ファイルの内容で既存の登録を置き換える。
    /// - merge: まだ登録が無い本にだけ追加する(既存の登録は一切変更しない)。
    ///
    /// ■ メインを長く止めない(2026-10-06 の応答性の点検 R4-2)
    /// 以前は 1 件ごとの場所の照合と、行ごとのブックマークの作成・識別子の stat(`upsertAll` の `sourceURL`)を、await を挟まずに
    /// メインで回していた。メタデータ生成が作った行はブックマークを持たないので、同じ Mac への復元でも行の数だけ作り、実在する本
    /// 5000 件で 8.6 秒止まった(実測。読み込み中の回転表示も止まる)。いまは照合を区切ってメインを譲り(`yieldPeriodically`)、書き込みも
    /// 区切り(`upsertAllInBatches`)、手がかり(ブックマークと識別子)は FileIO の上でまとめて作ってから入れる(`fillLocators` ――
    /// メタデータの編集ウインドウの一括の操作と同じ)。
    private static func applyMetadata(
        _ entries: [ExportedBookMetadataEntry], policy: ImportPolicy,
        bookmarkStore: BookmarkStore, layoutStore: LayoutStore,
        metadataStore: BookMetadataStore, summary: inout ImportSummary
    ) async {
        // 1件ずつupsertせず、まとめてupsertAllへ渡す。1件ごとにsave()と変更通知が出ると、
        // 通知を購読しているウインドウのreload()が件数ぶん走り、件数の二乗に比例した
        // ディスクI/Oになる(BookMetadataStore.upsertAll(_:)のコメント参照)。
        var batch: [BookMetadataStore.BatchEntry] = []
        batch.reserveCapacity(entries.count)
        var sourceImported = Set<String>()
        // 他のカテゴリと同じく、ファイルノード識別子による照合を優先し、解決できた場合は
        // 現在のパスをbookIDとして使う(別マシン/移動後でパスが変わっていても引き継げる)。手がかりはメインで集め
        // (書き込みはループの後の upsertAll だけなので、識別子の索引を作って使う)、解決はまとめて FileIO の上で(`locateAll`)。
        let located = await locateAll(await gatherHints(
            entries.map { ($0.bookID, $0.fileNodeIdentifier) },
            bookmarkStore: bookmarkStore, layoutStore: layoutStore
        ), identifies: false)
        // 手がかりを後から作る本(bookID → 見つかった場所)。
        var locatorTargets: [String: URL] = [:]
        for (index, entry) in entries.enumerated() {
            await yieldPeriodically(index)
            let resolvedURL = located[index]?.url
            let bookID = resolvedURL?.path ?? entry.bookID
            // 「足す」は、利用者が手を入れた行を変えない ―― 画面の約束は「既存のものは変えない」。置き換えるのはファイル名の読み
            // だけの行(`isParsedOnly`。2026-09-22 から解析した本はすべて行を持つので、それを「まだ無い」とみなす)。以前はロックした
            // 行だけを除いていて、ロックしていない行の直した欄・ルールセットが、読み込んだ値で黙って置き換わった(2026-09-22 の監査)。
            if policy == .merge, let existing = metadataStore.metadata(forBookID: bookID), !existing.isParsedOnly { continue }
            // 書き出した版の欄の版のまま入れる。版の無い以前のファイル(formatVersion 4 以前・qooMeta の書き出し)の行は、
            // qooMeta の欄が無ければ以前の版の欄の登録として入れる(空の欄を埋めるかを尋ねる。importedFieldsVersion)。
            batch.append(BookMetadataStore.BatchEntry(bookID: bookID, values: entry.values,
                                                      fieldsVersion: entry.importedFieldsVersion,
                                                      state: entry.importedState))
            if let resolvedURL { locatorTargets[bookID] = resolvedURL }
            if entry.importedSourceMetadata == true { sourceImported.insert(bookID) }
        }
        // 「足す」は、照合の間(メインを譲っている間)に利用者が手を入れた行を変えない ―― 書く直前に確かめ直す(コードレビュー)。
        if policy == .merge {
            batch.removeAll { metadataStore.metadata(forBookID: $0.bookID).map { !$0.isParsedOnly } ?? false }
        }
        // ファイルの書誌を取り込み済みの印(行の値とは別に持つので、書いた後で立てる)は、区切りごとに立てる ―― 最後にまとめて立てると、
        // 区切りの間にその本を開いたとき、ファイルの書誌を取り込み直してしまう(コードレビュー)。
        summary.metadataImportedBooks += await metadataStore.upsertAllInBatches(batch) { written in
            metadataStore.markSourceMetadataImported(Set(written.map(\.bookID)).intersection(sourceImported))
        }
        // 手がかりはファイルに触るので FileIO の上でまとめて作る(上の型コメント)。書いた行のうち、まだ無いものにだけ入る。
        let written = Set(batch.map(\.bookID))
        let targets = locatorTargets.filter { written.contains($0.key) }
        if !targets.isEmpty {
            let locators = await FileIO.perform(qos: .utility) {
                targets.mapValues { BookMetadataStore.makeLocator(for: $0) }
            }
            metadataStore.fillLocators(locators)
        }

    }

    // MARK: - コレクションの取り込み

    /// JSONの中のコレクションの位置(何番目のライブラリの何番目のコレクションか)。
    private struct CollectionPosition: Hashable {
        let library: Int
        let collection: Int
    }

    /// 本1冊ぶんの、場所を探す手がかり。メインアクターの外へ持ち出せる値だけで作る(`bookLocatorHints`)。
    nonisolated struct BookLocatorHints: Sendable {
        let bookID: String
        /// 試す順に並べたセキュリティスコープ付きブックマーク。
        let bookmarks: [Data]
        /// どのブックマークでも見つからなければ、記録したパス(bookID)そのものを試すか。
        var fallsBackToRecordedPath = true
    }

    /// 手がかりから、コレクションへ登録する材料を作る。見つからなければその本はnil。
    ///
    /// **`FileIO` の上で走る**(applyCollectionsのコメント参照)。以前は `@concurrent` で協調スレッドプールの上を走り、応答しない共有の
    /// 本があるとプールのスレッドを塞いだ(同じ形の `CollectionStore.makePendingItems` は先に FileIO へ移してあった。2026-10-11 の
    /// 規約監査で揃えた)。
    ///
    /// **ブックマークを解決したURLは、アクセスを開始してから触る**(監査で指摘 2026-09-13)。
    /// 以前は開始しないまま存在確認とブックマークの生成をしていたので、許可済みフォルダの外に
    /// ある本は、実在して有効なブックマークもあるのに「見つからない」として飛ばされえた。
    /// 見つからなかったブックマークは次の候補へ進む(以前は最初の1件目が解決できた
    /// 時点で打ち切り、それが消えた場所を指していても次を試さなかった)。
    static func makePendingItems(
        for hints: [BookLocatorHints]
    ) async -> [CollectionStore.PendingItem?] {
        await FileIO.perform(qos: .utility) {
            hints.map { hint in
                for data in hint.bookmarks {
                    guard let url = BookmarkResolution.resolve(data) else { continue }
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                    guard FileManager.default.fileExists(atPath: url.path),
                          let item = CollectionStore.makePendingItem(for: url)
                    else { continue }
                    return item
                }
                let fallback = URL(fileURLWithPath: hint.bookID)
                guard FileManager.default.fileExists(atPath: fallback.path) else { return nil }
                return CollectionStore.makePendingItem(for: fallback)
            }
        }
    }

    /// ライブラリ → コレクション → 本を取り込む。
    ///
    /// - overwrite: 既存のライブラリ・コレクション・登録をすべて消してから入れ直す
    ///   (カバー画像のファイルも消える)。
    /// - merge: 同じ名前のライブラリ/コレクションがあればそこへ合流し、無ければ作る。
    ///   同じコレクションに同じ本は入らない(CollectionStore.addがパス・iノードで弾く)。
    ///
    /// 取り込んだ本のカバーは`CollectionCoverStatus.pending`のまま置く。実際の抽出は
    /// ウェルカム画面の`CollectionCoverExtractor.refill()`が行う ―― 取り込みの最中に
    /// 全冊ぶんの本を開き始めると、件数によっては終わりが見えなくなるため。
    ///
    /// ■ 本の場所の解決は、先にまとめてメインアクターの外で行う(監査で指摘 2026-09-13)
    /// 以前は本1冊ごとに、メインアクター上で各ストアのブックマークを解決して存在を確かめ、
    /// さらにブックマークを作り直していた。数千冊のJSONで、到達できないボリュームを指す
    /// ブックマークが混ざると、1冊あたり秒単位でメインが止まり、取り込み中の表示すら出ない。
    /// いまは(1)メインで各ストアから**ブックマークのバイト列だけ**を集め(bookLocatorHints)、
    /// (2)解決・存在確認・ブックマークの生成を外で済ませ(makePendingItems)、(3)メインへ
    /// 戻って行を作る。
    ///
    /// 手がかりは**上書きで消す前に**集める。以前は消してから探していたので、コレクション自身の
    /// 登録(collectionStore.bookmarkDataCandidates)が上書きのときには必ず空振りしていた。
    ///
    /// **`libraries`が空なら何もしない**(上書きでも消さない)。アプリ自身は必ずライブラリを
    /// 1つ以上書き出す(CollectionStore.ensureDefaultLibrary)ので、空の配列は手で編集した
    /// ファイルにしか現れない。そこへ前のファイルで選んだ「上書き」が残っていると、何も
    /// 取り込まれないまま全コレクションと表紙が消えていた(監査で指摘 2026-09-13)。
    private static func applyCollections(
        _ libraries: [ExportedLibrary], policy: ImportPolicy,
        collectionStore: CollectionStore,
        bookmarkStore: BookmarkStore, layoutStore: LayoutStore,
        summary: inout ImportSummary
    ) async {
        guard !libraries.isEmpty else { return }

        // (1) 手がかりを集める(メイン。DBを読むだけ)。本はJSONの並びどおりに平らに並べ、
        //     どのコレクションの何冊目からかを控えておく ―― 下のループはライブラリを作れずに
        //     飛ばすことがあるので、順に読み出す形にするとそこから先が1冊ずつずれる。
        var hints: [BookLocatorHints] = []
        var startIndexByCollection: [CollectionPosition: Int] = [:]
        // 手がかり集めは読むだけなので、識別子の索引を 1 度だけ作って使う(FileNodeIndexes)。
        let indexes = FileNodeIndexes(
            layoutStore: layoutStore, bookmarkStore: bookmarkStore, collectionStore: collectionStore
        )
        for (libraryIndex, exportedLibrary) in libraries.enumerated() {
            for (collectionIndex, exportedCollection) in exportedLibrary.collections.enumerated() {
                startIndexByCollection[CollectionPosition(library: libraryIndex, collection: collectionIndex)] = hints.count
                for book in exportedCollection.books {
                    hints.append(bookLocatorHints(
                        bookID: book.bookID, fileNodeIdentifier: book.fileNodeIdentifier,
                        bookmarkStore: bookmarkStore,
                        layoutStore: layoutStore, collectionStore: collectionStore, indexes: indexes
                    ))
                }
            }
        }
        // (2) 解決と登録の材料づくり(外)。
        let resolved = await makePendingItems(for: hints)

        // (3) ここからメイン。
        // 自動登録フォルダの確かめ方(applyAutoFolder)に使う。マウントの一覧は MNT_NOWAIT で、応答しない共有でも止まらない。
        let mounts = MountTable.current()
        if policy == .overwrite {
            collectionStore.deleteAll()
        }
        // 上書きの後始末に使う(下の「空のライブラリを片付ける」参照)。
        var touchedLibraryIDs: Set<UUID> = []

        for (libraryIndex, exportedLibrary) in libraries.enumerated() {
            let name = exportedLibrary.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            // 同名のライブラリがあれば合流する。JSON側に同名のライブラリが2つあった場合も、
            // 2つ目は1つ目へ合流する(createLibraryが重複を作らないため)。
            let library: BookLibrary
            if let existing = collectionStore.libraries.first(where: {
                // 既定のライブラリは全言語の既定名で合流させる ―― 英語環境で書き出した
                // 「Library」が、日本語環境の既定のライブラリへ入るように
                // (BookLibrary.occupiedNames参照)。
                $0.occupiedNames.contains(name)
            }) {
                library = existing
            } else if let created = collectionStore.createLibrary(name: name) {
                library = created
                summary.collectionsImportedLibraries += 1
            } else {
                continue
            }
            touchedLibraryIDs.insert(library.id)
            // カバーの見せ方はJSONにあるときだけ上書きする(古いJSON・未知の値では触らない)。
            // 合流先が既存のライブラリでも書き替える ―― 保存データの取り込みは「向こうの状態を
            // 再現する」ものなので、名前だけ合流させて見た目が元のまま、では復元にならない。
            let importedAspect = exportedLibrary.coverAspectRatio
                .flatMap(CoverAspectRatio.init(rawValue:))
            let importedAnchor = CoverCropAnchor.stored(exportedLibrary.coverCropAnchor)
            let importedFit = exportedLibrary.coverFit.flatMap(CoverFit.init(rawValue:))
            if importedAspect != nil || importedAnchor != nil || importedFit != nil {
                collectionStore.setCoverAppearance(
                    library,
                    aspectRatio: importedAspect ?? library.coverAspectRatio,
                    anchor: importedAnchor ?? library.coverCropAnchor,
                    fit: importedFit ?? library.coverFit
                )
            }

            for (collectionIndex, exportedCollection) in exportedLibrary.collections.enumerated() {
                let collectionName = exportedCollection.name
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !collectionName.isEmpty,
                      let startIndex = startIndexByCollection[
                          CollectionPosition(library: libraryIndex, collection: collectionIndex)
                      ]
                else { continue }

                var pending: [CollectionStore.PendingItem] = []
                var resolvedPaths: Set<String> = []
                for (offset, book) in exportedCollection.books.enumerated() {
                    // (2)で解決済み。
                    //
                    // ユーザー要望: JSONのファイルパスは参考情報。まずファイルノード識別子を
                    // 手がかりに、ローカルに保存済みのセキュリティスコープ付きブックマークから
                    // 現在のURLを解決する(bookLocatorHints参照)。
                    guard let item = resolved[startIndex + offset] else {
                        summary.collectionsSkippedBookIDs.append(book.bookID)
                        continue
                    }
                    guard !resolvedPaths.contains(item.url.path) else { continue }
                    pending.append(item)
                    resolvedPaths.insert(item.url.path)
                }
                // 1冊も見つからなかったコレクションは作らない(空のコレクションは作らない
                // というアプリ全体の方針。CollectionStore.createCollection参照)。
                guard !pending.isEmpty else { continue }

                if let existing = collectionStore.collections(in: library, sort: .nameAscending)
                    .first(where: {
                        $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == collectionName
                    }) {
                    summary.collectionsImportedBooks += collectionStore.add(pending, to: existing).count
                    // 既にあるコレクションへ混ぜる場合は、**こちらの設定を上書きしない**
                    // (まだ設定されていないときだけ入れる)。JSONを追加で取り込んだだけで、
                    // 手元で決めた自動登録フォルダが差し替わるのは筋が通らない。
                    if existing.autoFolderPath == nil {
                        applyAutoFolder(exportedCollection, to: existing, collectionStore: collectionStore, mounts: mounts)
                    }
                } else if let created = collectionStore.createCollection(
                    name: collectionName, in: library, items: pending
                ) {
                    summary.collectionsImportedCollections += 1
                    summary.collectionsImportedBooks += created.items.count
                    applyAutoFolder(exportedCollection, to: created, collectionStore: collectionStore, mounts: mounts)
                }
            }

            // 常に先頭/末尾の指定は、そのライブラリのコレクションを作り終えてから名前で
            // 引き直して設定する(applyPinnedCollections参照)。
            applyPinnedCollections(exportedLibrary, to: library, collectionStore: collectionStore)
        }

        // 上書きのときだけ: 取り込み先にならなかった空のライブラリを片付ける。
        // deleteAll()の直後にCollectionStore.reload()が「ライブラリは必ず1つ以上」を保つため
        // 既定の「Library」を作り直しており、JSON側にその名前が無いと空のまま残ってしまう。
        if policy == .overwrite {
            for library in collectionStore.libraries
            where !touchedLibraryIDs.contains(library.id) && library.collections.isEmpty {
                collectionStore.delete(library)
            }
        }
    }

    /// JSONに書かれていた自動登録フォルダを設定する(ExportedCollection.autoFolderPath参照)。
    /// 登録してよいかは、ほかのパスだけのフォルダの設定と同じ `BackupFolderPaths.shouldImport` で決める: 繋がっているローカルの
    /// ボリュームでフォルダが無いものだけを落とし、繋がっていないボリューム・ネットワークのボリュームの上は確かめずに登録する。
    /// 以前は `fileExists` をメインでコレクションごとに呼んでいて、応答しない共有では 1 つあたり 30 秒〜無期限止まった
    /// (2026-10-25 のハング・クラッシュの監査 #10)。
    private static func applyAutoFolder(
        _ exported: ExportedCollection, to collection: BookCollection,
        collectionStore: CollectionStore, mounts: MountTable
    ) {
        guard let path = exported.autoFolderPath, !path.isEmpty else { return }
        guard BackupFolderPaths.shouldImport(path, mounts: mounts) else { return }
        collectionStore.setAutoFolder(URL(fileURLWithPath: path, isDirectory: true), for: collection)
    }

    /// JSONに書かれていた「常に先頭/末尾に表示するコレクション」を設定する
    /// (ExportedLibrary.pinnedFirstCollection参照。ユーザー要望 2026-09-10)。
    ///
    /// **名前で引き直す** ―― 取り込み側ではコレクションのidが作り直されるため。書かれていない、
    /// あるいはその名前のコレクションが取り込み先に無い(本が1冊も見つからず作られなかった等)
    /// ときは何もしない。「JSONにあるときだけ上書きする」というライブラリの設定の扱いに揃えて
    /// あり(カバーの見せ方と同じ)、手元の指定を黙って消すことはない。
    private static func applyPinnedCollections(
        _ exported: ExportedLibrary, to library: BookLibrary, collectionStore: CollectionStore
    ) {
        func resolve(_ name: String?) -> BookCollection? {
            guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty
            else { return nil }
            return library.collections.first {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
            }
        }
        if let first = resolve(exported.pinnedFirstCollection) {
            collectionStore.setPinnedCollection(first, atStart: true, in: library)
        }
        if let last = resolve(exported.pinnedLastCollection) {
            collectionStore.setPinnedCollection(last, atStart: false, in: library)
        }
    }

    // MARK: - ブックマークの取り込み

    private static func applyBookmarks(
        _ bookmarks: [ExportedBookmarkEntry], policy: ImportPolicy,
        bookmarkStore: BookmarkStore, layoutStore: LayoutStore,
        cachesPageList: Bool, summary: inout ImportSummary
    ) async {
        for entry in bookmarks {
            guard !entry.bookmarks.isEmpty else { continue }
            guard let book = await loadBook(
                bookID: entry.bookID, fileNodeIdentifier: entry.fileNodeIdentifier,
                bookmarkStore: bookmarkStore, layoutStore: layoutStore,
                cachesPageList: cachesPageList, makesBookmark: false
            ) else {
                summary.bookmarksSkippedBookIDs.append(entry.bookID)
                continue
            }
            // ファイルノード識別子による解決の結果、実際のbookID(book.id)がJSON上のbookIDと
            // 異なることがある(リネーム・移動後)。以降はすべてbook.id(実際の現在のパス)を
            // 使う(JSONのbookIDはここまでの解決処理でのみ参考情報として使う)。
            let bookID = book.id
            // ユーザー要望: JSON側のinodeNumber/volumeDeviceNumberをそのまま信用せず、今実際に
            // 解決できたbook.sourceURLから改めて取得し直した識別子をDBに記録する(誤って削除した
            // ファイルをバックアップからコピーしてきた場合など、実体のinodeがJSONの記録時点と
            // 変わっているケースに対応するため。qooViewer改善要望.md「ファイルパスならば実在する
            // 場合、inodeをDB上のinodeはそのファイルパスから再取得してinodeで設定すること」参照)。
            // 読み込みと一緒に FileIO の上で(スコープを開いたまま)求めてある(`loadBook` の `sourceFacts`。2026-10-11 の規約監査)。
            let resolvedFileNodeIdentifier = book.sourceFacts?.fileNodeIdentifier
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
            } else if let resolvedFileNodeIdentifier {
                // merge時、この本に既にある(識別子を持たない古い)ブックマークにも、ついでに
                // 補完しておく(exportBookmarksの同種の処理と同じ理由)。
                bookmarkStore.backfillFileNodeIdentifier(forBookID: bookID, identifier: resolvedFileNodeIdentifier)
            }
            // 経緯(ユーザー報告): JSONインポートが非常に遅い。Xcodeのコンソールを見る限りJSONを
            // 1行読むたびにSQLiteへの書き込みが起きているように見える、との指摘。実際、以前は
            // ここでbookmarkStore.addBookmark(bookID:pageIndex:name:)をこの本のブックマーク件数
            // ぶんループで個別に呼んでおり、そのたびに同期save()+reload()+通知が走っていた
            // (本1冊で数百件になることも珍しくない)。対象ページが見つかったブックマークを
            // いったんpendingEntriesに貯めておき、addBookmarks(bookID:entries:)へまとめて渡す
            // ことで、この本につき保存・再フェッチ・通知を1回にまとめる(重複防止の意味は
            // addBookmarkのループ呼び出しと変わらない)。
            var pendingEntries: [(pageIndex: Int, pageKey: String?, name: String)] = []
            for bookmarkEntry in entry.bookmarks {
                // フォルダの本の鍵は絶対パスなので、書き出した後に本が動いていれば鍵の頭も付け替える(2026-09-22 の監査。
                // 以前はそのまま引いて見つからず、ブックマークが数えられもせずに黙って落ちた。PageKeyRelocation)。
                let pageKey = PageKeyRelocation.relocated(bookmarkEntry.page, fromBookID: entry.bookID, toBookID: bookID)
                    ?? bookmarkEntry.page
                guard let pageIndex = keyToIndex[pageKey] else { continue }
                // JSONは元から鍵で持っているので、そのまま鍵として保存する
                // (番号だけの行にしない。Bookmark.pageKeyのコメント参照)。
                pendingEntries.append(
                    (pageIndex: pageIndex, pageKey: pageKey, name: bookmarkEntry.name)
                )
            }
            let addedCount = bookmarkStore.addBookmarks(
                bookID: bookID, entries: pendingEntries, fileNodeIdentifier: resolvedFileNodeIdentifier
            )
            if addedCount > 0 {
                summary.bookmarksImportedBooks += 1
                summary.bookmarksImportedEntries += addedCount
            }
        }
    }

    // MARK: - レイアウト設定の取り込み

    private static func applyLayouts(
        _ layouts: [ExportedBookLayoutEntry], policy: ImportPolicy,
        layoutStore: LayoutStore, bookmarkStore: BookmarkStore,
        cachesPageList: Bool, summary: inout ImportSummary
    ) async {
        for entry in layouts {
            guard let book = await loadBook(
                bookID: entry.bookID, fileNodeIdentifier: entry.fileNodeIdentifier,
                bookmarkStore: bookmarkStore, layoutStore: layoutStore,
                cachesPageList: cachesPageList, makesBookmark: true
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
            // 手元のブックマークのうち鍵を持たない古い行(1.36 以前)の番号は、取り込む前の並びの従来順で数えたもの。並びを
            // 書き換える前に、その従来順の鍵を控えておく(下の振り直し。鍵を持つ行しか無ければ作らない ―― 並べ直しが要るので)。
            let legacyKeysBeforeImport: [String] = bookmarkStore.bookmarks(forBookID: bookID).contains { $0.pageKey == nil }
                ? EffectivePageOrder.legacyOrderedPageKeys(
                    for: book, pageOrderOverride: existingSettings?.pageOrderOverride,
                    excludedKeys: Set(layoutStore.pageOverrides(forBookID: bookID)
                        .filter { $0.state == .excluded }.map(\.pageKey))
                )
                : []

            if policy == .overwrite {
                // 行ごとは消さない ―― JSONに無いコレクション表紙・カバー画像などが同居している
                // (LayoutStore.discardPageLayoutのコメント参照)。
                layoutStore.discardPageLayout(forBookID: bookID)
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
            // フォルダの本の鍵は絶対パスなので、書き出した後に本が動いていれば鍵の頭も付け替える(ブックマークと同じ。
            // 2026-09-22 の監査。PageKeyRelocation)。
            let relocatedKey = { (key: String) in
                PageKeyRelocation.relocated(key, fromBookID: entry.bookID, toBookID: bookID) ?? key
            }
            // 重なった鍵はここでは落とさない(本の側に同じ sortKey のページが 2 枚ある本では正しい並びの一部。数は読む側の
            // EffectivePageOrder がページ数までに抑える ―― 2026-10-25 の監査 A1-6)。
            let pageOrder = hasExistingBookLevelSettings
                ? nil : layout.pageOrder.flatMap { $0.isEmpty ? nil : $0.map(relocatedKey) }

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
                for (exportedKey, pageState) in pages {
                    let pageKey = relocatedKey(exportedKey)
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
            // 並び(並べ替え・除外)が変わったので、手元のブックマークの番号を今の並びへ振り直す(ビューアが開いていなくても ――
            // docs/07「ページの鍵」。2026-10-04 のレビューの R2-7: 以前は振り直さず、次に本を開くまで、ブックマーク一覧の番号・
            // 一括リネームの連番・「次のブックマーク」が古い並びのページを見た)。JSON のブックマークはこの後 `applyBookmarks` が
            // 取り込んだ後の並びで数えて足す。
            let importedSettings = layoutStore.bookLayoutSettings(forBookID: bookID)
            let currentOrderedKeys = EffectivePageOrder.pageKeys(
                for: book, pageOrderOverride: importedSettings?.pageOrderOverride,
                excludedKeys: Set(layoutStore.pageOverrides(forBookID: bookID).filter { $0.state == .excluded }.map(\.pageKey))
            )
            bookmarkStore.renumberBookmarks(forBookID: bookID, currentOrderedKeys: currentOrderedKeys) {
                legacyKeysBeforeImport
            }
            summary.layoutsImportedBooks += 1
        }
    }
}


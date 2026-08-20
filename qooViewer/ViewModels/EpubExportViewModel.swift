import Foundation
import SwiftUI
import Combine

/// EPUB出力ウインドウ(設計コンセプト7節)のロジックを担当する。BookLayoutEditorViewModelと
/// 同じく、対象の一覧・出力オプション・実際の出力処理(進捗・キャンセル・同名確認・失敗集約)を
/// このクラスに集約し、EpubExportWindow(View)側は表示に専念する。
@MainActor
final class EpubExportViewModel: ObservableObject {
    /// 7.1節の対象一覧の1行。pdf/epub形式以外で、レイアウトまたはブックマーク情報を持つ本。
    struct Row: Identifiable {
        let bookID: String
        let hasLayout: Bool
        let hasBookmarks: Bool
        let hasMetadata: Bool
        var id: String { bookID }
        var displayName: String {
            URL(fileURLWithPath: bookID).deletingPathExtension().lastPathComponent
        }
    }

    struct FailureReport: Identifiable {
        let id = UUID()
        let displayName: String
        let message: String
    }

    enum OverwriteDecision {
        case overwrite
        case skip
    }

    private struct ExportSkippedByUser: Error {}
    private struct SimpleError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published private(set) var rows: [Row] = []
    @Published var selectedBookIDs: Set<String> = []

    // MARK: - タイトル・著者名(ユーザー要望: Apple Books互換性。ファイル名/フォルダ名から
    // タイトル・著者名を取得し、この画面で変更できるようにしたい)

    /// bookID -> タイトル(編集可能)。reload()で新しく現れた本にだけ、ファイル名/フォルダ名から
    /// TitleAuthorFilenameParserで推測した値を初期値として設定する(既存の編集内容は保持する)。
    @Published var titleOverrides: [String: String] = [:]
    /// bookID -> 著者名(編集可能)。titleOverridesと同じ考え方。
    @Published var authorOverrides: [String: String] = [:]

    func titleBinding(forBookID bookID: String) -> Binding<String> {
        Binding(
            get: { self.titleOverrides[bookID] ?? "" },
            set: { self.titleOverrides[bookID] = $0 }
        )
    }

    func authorBinding(forBookID bookID: String) -> Binding<String> {
        Binding(
            get: { self.authorOverrides[bookID] ?? "" },
            set: { self.authorOverrides[bookID] = $0 }
        )
    }

    /// 7.2節の出力オプション。連番リネームは既定OFF(ユーザー要望。元のファイル名をそのまま
    /// 使いたい場合が多いため、必要な場合にだけ明示的にONにしてもらう形にした。以前は文字化け
    /// 対策を兼ねて既定ONにしていたが、そちらの判断は撤回した)、除外ページを含めるかは既定OFF
    /// (7.2節の既定と同じ)。
    @Published var renumberImagesSequentially = false
    @Published var includeExcludedPages = false

    // 実行中の状態
    @Published private(set) var isExporting = false
    @Published private(set) var currentBookDisplayName: String?
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    private var isCancelled = false

    // 同名ファイルの確認(7.3節)
    @Published private(set) var pendingOverwriteBookDisplayName: String?
    private var overwriteDecisionContinuation: CheckedContinuation<OverwriteDecision, Never>?
    private var rememberedOverwriteDecision: OverwriteDecision?

    // 結果
    @Published private(set) var failures: [FailureReport] = []
    @Published private(set) var successCount = 0
    @Published private(set) var didFinish = false

    private let bookmarkStore: BookmarkStore
    private let layoutStore: LayoutStore
    private let metadataStore: BookMetadataStore
    private let preferences: AppPreferences

    /// この画面はWindow(id: "epubExport")という単一インスタンスのシーンで開くため、一度表示された
    /// EpubExportViewModelはウインドウを閉じても(BookmarkListView.BookmarkEditorViewの
    /// BookmarkStore/LayoutStoreと違い)アプリを終了するまで使い回される。そのため、初期化時の
    /// reload()一発きりでは、この画面を開いた後に「ブックマーク・レイアウトの編集」ウインドウで
    /// 別の本のレイアウト・ブックマークを新規に追加しても一覧に反映されず、アプリを再起動しない
    /// 限り一覧に出てこない、という不具合(ユーザー報告)があった。
    ///
    /// BookmarkStore/LayoutStore/ViewerViewModelと同じく、bookmarksDidChange/layoutDataDidChange
    /// 通知を受けてreload()し直すことで、このウインドウを開いたままでも常に最新の対象一覧を
    /// 表示できるようにする。
    private var bookmarksChangeObserver: NSObjectProtocol?
    private var layoutDataChangeObserver: NSObjectProtocol?
    private var metadataChangeObserver: NSObjectProtocol?

    /// loadBook(forBookID:)でstartAccessingSecurityScopedResource()に成功したURLの集合。
    ///
    /// 読み込んだ本は、この後もカバー列の表示名の解決やカバーピッカーのサムネイル取得で
    /// 元のファイルを読み続けるため、loadBook()の中でアクセスを閉じることはできず、この
    /// インスタンスが生きている間ずっと開いたままにしておく必要がある。そのため対になる
    /// stopAccessingSecurityScopedResource()はdeinitで呼ぶ
    /// (BookLayoutEditorViewModel.securityScopedURLと同じ方針)。
    ///
    /// 以前は`_ = url.startAccessingSecurityScopedResource()`と開きっぱなしにしており、
    /// アクセス権がリークしていた。しかもBookLayoutEditorViewModel(1冊ごとに作り直される)と
    /// 違い、このViewModelはウインドウを閉じてもアプリ終了まで使い回されるうえ、
    /// loadBook()はカバー列のセルの.task(refreshCoverName)から行ごとに呼ばれるため、
    /// 一覧をスクロールして行が再表示されるたびに対象の本の数だけ積み上がっていた。
    ///
    /// Set(URL単位で1回だけ開く)にしているのは、startAccessingSecurityScopedResourceが
    /// 参照カウント式のため。同じ本を何度読み込んでも開くのは1回だけにしておかないと、
    /// deinitでの1回のstopでは釣り合わない。
    private var securityScopedURLs: Set<URL> = []

    init(
        bookmarkStore: BookmarkStore, layoutStore: LayoutStore, metadataStore: BookMetadataStore,
        preferences: AppPreferences
    ) {
        self.bookmarkStore = bookmarkStore
        self.layoutStore = layoutStore
        self.metadataStore = metadataStore
        self.preferences = preferences
        reload()

        // queue: .mainを指定しているため実行時には必ずMainActor上で呼ばれるが、クロージャ自体の
        // 型はMainActorに分離されていないため、コンパイラは静的にそれを保証できない
        // (BookmarkStore.init/ViewerViewModel.initの同種のコメント参照)。
        bookmarksChangeObserver = NotificationCenter.default.addObserver(
            forName: .bookmarksDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
            }
        }
        layoutDataChangeObserver = NotificationCenter.default.addObserver(
            forName: .layoutDataDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
            }
        }
        metadataChangeObserver = NotificationCenter.default.addObserver(
            forName: .bookMetadataDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
            }
        }
    }

    deinit {
        if let bookmarksChangeObserver {
            NotificationCenter.default.removeObserver(bookmarksChangeObserver)
        }
        if let layoutDataChangeObserver {
            NotificationCenter.default.removeObserver(layoutDataChangeObserver)
        }
        if let metadataChangeObserver {
            NotificationCenter.default.removeObserver(metadataChangeObserver)
        }
        // loadBook(forBookID:)で開いたセキュリティスコープ付きアクセスを閉じる
        // (securityScopedURLsのコメント参照)。
        for url in securityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// 対象一覧を読み直す。レイアウト情報またはブックマーク情報を持つ本のうち、pdf/epub形式は
    /// 除外する(7.1節: 「pdf/epub形式以外」)。カバー画像だけを上書き設定している本
    /// (読み方向・ページ順等の上書きは無い)も対象に含める(ユーザー要望: カバー画像を
    /// 選択・変更できるようにしたい。layoutStore.layoutBookIDsはisBookLevelSettingEmptyで
    /// カバー関連プロパティを見ていないため、これだけでは拾えない)。
    ///
    /// バグ修正(ユーザー報告): 過去にレイアウトやブックマークを編集した本の元ファイル/フォルダを
    /// 後から削除しても、DB上のBookLayoutSettings/Bookmarkレコード自体は(設計コンセプト10.3節の
    /// 方針により)自動削除されず残り続けるため、それだけで一覧に表示されてしまっていた。
    /// resolveURL(forBookID:)はbookmarkStore/layoutStoreどちらもセキュリティスコープ付き
    /// ブックマークの解決先(無ければ生パス)についてFileManager.fileExistsを確認したうえで
    /// 返す(見つからなければnil)ため、これを使って実在が確認できた本だけに絞り込む。
    /// ユーザー報告と同じ構図の改善: 対象一覧の絞り込み(元のファイルが今も存在するか)は、
    /// 登録済みの本1冊ごとにセキュリティスコープ付きブックマークの解決を行う。以前はこれを
    /// メインスレッドで同期実行していたため、本体が未接続の外付け/ネットワークボリューム上に
    /// あると、このウインドウを開くだけでその間ずっと操作を受け付けなくなっていた。
    ///
    /// SwiftDataから材料を集める部分(軽い)だけをここで行い、解決本体はメインアクターの外へ
    /// 逃がす(BookURLResolver参照)。結果が返るまでは一覧を空にせず、直前の内容をそのまま
    /// 見せておく(この画面を開いたままでも通知を受けてreload()し直されるため)。
    func reload() {
        var bookIDs = layoutStore.layoutBookIDs
        bookIDs.formUnion(bookmarkStore.groups.map(\.bookID))
        bookIDs.formUnion(layoutStore.coverOverrideBookIDs())
        // ユーザー要望: メタデータの登録がある本もEPUB出力の対象に含める。
        bookIDs.formUnion(metadataStore.registeredBookIDs)
        // ユーザー要望: 元のファイル形式による制限を撤廃し、
        // zip/cbz・rar/cbr・7z/cb7・pdf・epub・フォルダのすべてを対象にする
        // (元がPDFの場合の画像の扱いはPDFImageExtractor参照)。
        // 実在確認の材料(各ストアが持つブックマークデータ)だけをここで集める。
        // 解決そのものはメインスレッドを止めうるため、下のTask.detachedで行う。
        let candidates = bookIDs.map { bookID in
            BookURLResolver.Candidates(
                bookID: bookID,
                bookmarkStoreBookmarks: bookmarkStore.bookmarkDataList(forBookID: bookID),
                layoutBookmark: layoutStore.bookLayoutSettings(forBookID: bookID)?.bookmarkData,
                metadataBookmark: metadataStore.metadata(forBookID: bookID)?.bookmarkData
            )
        }
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isLoadingRows = true
        // [weak self]で受けたselfを、awaitをまたぐ前にguard letで強参照へ変換しておく
        // (理由はRecentFilesStore.scheduleRefresh()の同種のコメント参照)。
        Task.detached(priority: .userInitiated) { [weak self] in
            let eligible = candidates.compactMap { BookURLResolver.resolvedURL($0) != nil ? $0.bookID : nil }
            guard let self else { return }
            await self.applyEligibleBookIDs(Set(eligible), generation: generation)
        }
    }

    /// reload()の絞り込み結果を反映して、一覧を組み立てる。
    private func applyEligibleBookIDs(_ eligibleIDs: Set<String>, generation: Int) {
        // 自分より新しいreload()が既に走っている場合は、古い結果を捨てる。
        guard generation == reloadGeneration else { return }
        isLoadingRows = false

        // bookmarkStore.groupsはArrayなので、mapの中で毎回containsを呼ぶとO(件数^2)になる。
        // 事前にSet化して1回のO(1)ルックアップにする(結果は従来と同一)。
        let bookIDsWithBookmarks = Set(bookmarkStore.groups.map(\.bookID))
        rows = eligibleIDs
            .map { bookID in
                Row(
                    bookID: bookID,
                    hasLayout: layoutStore.layoutBookIDs.contains(bookID),
                    hasBookmarks: bookIDsWithBookmarks.contains(bookID),
                    hasMetadata: metadataStore.isRegistered(bookID: bookID)
                )
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        selectedBookIDs.formIntersection(Set(rows.map(\.bookID)))

        // タイトル・著者名の初期値。ユーザー要望により、メタデータDBに登録がある本は
        // そちらを優先し、無い本だけ従来通りファイル名/フォルダ名から推測する。
        // 既にユーザーがこの画面で編集済みの値は上書きしない。
        for row in rows where titleOverrides[row.bookID] == nil {
            if let metadata = metadataStore.metadata(forBookID: row.bookID), !metadata.title.isEmpty {
                titleOverrides[row.bookID] = metadata.title
                authorOverrides[row.bookID] = metadata.author
                continue
            }
            let parsed = TitleAuthorFilenameParser.parse(baseName: row.displayName)
            titleOverrides[row.bookID] = parsed.title.isEmpty ? row.displayName : parsed.title
            authorOverrides[row.bookID] = parsed.author
        }
    }

    // MARK: - 一括選択(7.1節)

    /// ユーザー要望により、上部の「選択」メニュー(4条件)と「選択解除」ボタンは廃止し、
    /// 代わりに一覧のタイトル行にチェックボックスを設けて全選択/全選択解除を行う形にした
    /// (EpubExportWindow.columnHeaderRowのselectAllBinding参照)。
    func selectAll() { selectedBookIDs = Set(rows.map(\.bookID)) }
    func deselectAll() { selectedBookIDs.removeAll() }

    // MARK: - カバー画像(ユーザー要望: EPUB出力のカバー画像を選択・変更できるようにしたい)

    /// カバー列に表示する名前のキャッシュ(bookID -> 表示名)。上書き設定がある場合は
    /// BookLayoutSettingsに保存済みの値をそのまま使えるが、既定(先頭ページ)の場合は本を
    /// 読み込んで確認する必要があるため、非同期で解決してここへキャッシュする
    /// (refreshCoverName(forBookID:)参照)。
    @Published private(set) var resolvedCoverNames: [String: String] = [:]

    /// カバー列の表示文字列。まだ解決できていない間は読み込み中であることが分かる文字列を返す。
    func coverDisplayName(forBookID bookID: String) -> String {
        resolvedCoverNames[bookID] ?? String(localized: "Loading…")
    }

    /// この本のカバー表示名を最新化する。呼び出し元(カバー列のセル)の.taskから、行の表示中に
    /// 一度だけ呼ぶ想定(BookmarkListView.PageRowViewのサムネイル読み込みと同じ考え方)。
    func refreshCoverName(forBookID bookID: String) async {
        guard let settings = layoutStore.bookLayoutSettings(forBookID: bookID) else {
            await resolveDefaultCoverName(forBookID: bookID)
            return
        }
        if let externalName = settings.externalCoverFileName {
            resolvedCoverNames[bookID] = externalName
            return
        }
        if settings.coverPageKey != nil, let cached = settings.coverPageDisplayName {
            resolvedCoverNames[bookID] = cached
            return
        }
        await resolveDefaultCoverName(forBookID: bookID)
    }

    /// 既定(上書き無し)の場合のカバー名。実際に書き出したときと同じロジック
    /// (EffectivePageOrder)で実質的な先頭ページを求める。
    ///
    /// ユーザー報告と同じ構図の改善: 以前はここで必ずBookLoader.load(from:)を呼んでいた。
    /// 欲しいのは「実質的な先頭ページのファイル名」1つだけなのに、そのために書庫を全走査して
    /// いたことになる。しかもこれは一覧のカバー列のセルごと(=対象の本の数だけ)呼ばれるため、
    /// 本体が未接続の外付け/ネットワークボリューム上にあるとウインドウを開くだけで延々と
    /// 読み込みが続いていた。
    ///
    /// 並べ替え(pageOrderOverride)と除外(excluded)はDBから引けるので、必要な本体側の情報は
    /// ページの並び順とファイル名だけ。まずキャッシュ(BookPageListCache)を見て、あればそれで
    /// 済ませる。無い場合だけ従来どおり読み込む(その読み込み自体がBookLoader.load経由で
    /// キャッシュを埋めるため、次回以降は読み込み無しで解決できる)。
    private func resolveDefaultCoverName(forBookID bookID: String) async {
        let settings = layoutStore.bookLayoutSettings(forBookID: bookID)
        let excludedKeys = Set(
            layoutStore.pageOverrides(forBookID: bookID).filter { $0.state == .excluded }.map(\.pageKey)
        )

        if let cached = await BookPageListCache.shared.pageList(forBookID: bookID), !cached.pages.isEmpty {
            let ordered = EffectivePageOrder.orderedPages(
                for: cached.pages, pageOrderOverride: settings?.pageOrderOverride, excludedKeys: excludedKeys
            )
            if let first = ordered.first {
                resolvedCoverNames[bookID] = first.displayName
                return
            }
        }

        guard let book = await loadBook(forBookID: bookID) else { return }
        let ordered = EffectivePageOrder.orderedPages(
            for: book, pageOrderOverride: settings?.pageOrderOverride, excludedKeys: excludedKeys
        )
        guard let first = ordered.first else { return }
        resolvedCoverNames[bookID] = first.displayName
    }

    /// カバーピッカー(本のページ一覧を表示する画面)から呼ばれる。この本を読み込んで返す
    /// (セキュリティスコープ付きアクセスはBookLayoutEditorViewModel.loadと同じく、ウインドウが
    /// 開いている間ずっとサムネイルを読み込めるよう、明示的に閉じずに保持したままにし、
    /// deinitでまとめて閉じる。securityScopedURLsのコメント参照)。
    func loadBookForCoverPicker(bookID: String) async -> MangaBook? {
        await loadBook(forBookID: bookID)
    }

    private func loadBook(forBookID bookID: String) async -> MangaBook? {
        guard let url = resolveURL(forBookID: bookID) else { return nil }
        // 同じ本を何度読み込んでも、開くのは最初の1回だけにする(securityScopedURLsのコメント参照)。
        if !securityScopedURLs.contains(url), url.startAccessingSecurityScopedResource() {
            securityScopedURLs.insert(url)
        }
        return try? await BookLoader.load(from: url)
    }

    /// 本に含まれる既存ページをカバーに指定する。
    func setCover(forBookID bookID: String, book: MangaBook, page: PageRef) {
        layoutStore.setCoverPageKey(for: book, pageKey: page.sortKey, displayName: page.displayName)
        resolvedCoverNames[bookID] = page.displayName
    }

    /// 本に含まれない専用ファイルをカバーに指定する。この専用ファイルは本の一部として扱わない
    /// ため、ビューアのページ一覧には現れない(LayoutStore.setExternalCoverのコメント参照)。
    func setExternalCover(forBookID bookID: String, book: MangaBook, fileURL: URL) {
        guard (try? layoutStore.setExternalCover(for: book, fileURL: fileURL)) != nil else { return }
        resolvedCoverNames[bookID] = fileURL.lastPathComponent
    }

    /// カバーの上書きを解除し、既定(先頭ページ)に戻す。
    func resetCover(forBookID bookID: String) {
        layoutStore.clearCoverOverride(forBookID: bookID)
        resolvedCoverNames.removeValue(forKey: bookID)
        Task { await refreshCoverName(forBookID: bookID) }
    }

    // MARK: - 空き容量チェック(7.3節)

    /// 選択されている本の元ファイル/フォルダの合計サイズ。アーカイブ・PDFはfileSizeKey、
    /// フォルダは中の画像ファイルサイズを再帰合計する。
    func totalSourceSize() -> Int64 {
        let targets = rows.filter { selectedBookIDs.contains($0.bookID) }
        var total: Int64 = 0
        for row in targets {
            guard let url = resolveURL(forBookID: row.bookID) else { continue }
            total += sourceSize(of: url)
        }
        return total
    }

    private func sourceSize(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if isDirectory.boolValue {
            var total: Int64 = 0
            if let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    if values?.isDirectory != true, let size = values?.fileSize {
                        total += Int64(size)
                    }
                }
            }
            return total
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// 出力先ボリュームの空き容量。取得できなければnil(その場合、呼び出し側は容量チェック自体を
    /// 諦めてそのまま続行する。取得失敗を「容量不足」と誤判定してユーザーの操作を止めないため)。
    ///
    /// 以前はvolumeAvailableCapacityForImportantUsageKeyのみを使っていたが、このキーは
    /// 「読み込み結果」ではなく「あとで自動的に解放されうるパージ可能領域(キャッシュ・
    /// ローカルTime Machineスナップショット等)を除いた、重要な用途向けの空き容量」という
    /// 独自の見積もりであり、ボリュームによってはFinderの表示(実際の空き容量)よりずっと
    /// 小さい値(場合によっては数十MB程度)を返すことが実機で確認された(ユーザー報告:
    /// 101MBのファイル1つ、出力先の実際の空き容量は2.52TBあるにもかかわらず「空き容量不足」
    /// と誤警告された)。Finderの「使用可能な容量」表示と一致する素直な合計値である
    /// volumeAvailableCapacityKeyを優先して使い、それが取得できない場合にのみ
    /// ForImportantUsage版へフォールバックする形に変更する。
    func availableCapacity(at folderURL: URL) -> Int64? {
        let values = try? folderURL.resourceValues(
            forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        )
        if let plain = values?.volumeAvailableCapacity {
            return Int64(plain)
        }
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// 7.3節: 出力先の空き容量が合計サイズの1.2倍未満なら警告(false)。
    func hasSufficientDiskSpace(at folderURL: URL) -> Bool {
        guard let available = availableCapacity(at: folderURL) else { return true }
        let required = Double(totalSourceSize()) * 1.2
        return Double(available) >= required
    }

    // MARK: - bookIDからのURL解決

    /// 各ストアが持つセキュリティスコープ付きブックマークからURLを解決する
    /// (LibraryImportExportService.resolveURLと同じ考え方)。
    ///
    /// バグ修正: メタデータの登録がある本を対象へ加えた際、この解決経路にBookMetadataStoreを
    /// 足し忘れていた。メタデータだけを持つ本(EPUB/PDFを単体で開いたときの自動取り込み分が
    /// まさにこれ)は、BookmarkStore/LayoutStoreのどちらもブックマークを持たないため、
    /// 生パスに対するFileManager.fileExistsへフォールバックする。サンドボックス下では
    /// アクセス権の無いパスに対する存在確認自体が失敗するため、実在していても一覧から
    /// 落ちていた(BookMetadata.bookmarkDataは、まさにこの用途のために持っている)。
    /// 対象一覧の絞り込み(実在確認)が進行中かどうか。ウインドウ側はこの間、
    /// 「対象の本がありません」ではなく読み込み中の表示にする。
    @Published private(set) var isLoadingRows = false
    /// 非同期の絞り込みが多重に走った場合に、古い結果で新しい結果を上書きしないための世代番号。
    private var reloadGeneration = 0

    private func resolveURL(forBookID bookID: String) -> URL? {
        bookmarkStore.resolvedURLFromBookmarkData(forBookID: bookID)
            ?? layoutStore.resolvedURL(forBookID: bookID)
            ?? metadataStore.resolvedURL(forBookID: bookID)
    }

    // MARK: - 出力実行(7.3節)

    func cancel() {
        isCancelled = true
    }

    /// 結果シートを閉じる(OKボタン、またはシート自体のスワイプ/×での閉じ操作)。
    func acknowledgeFinish() {
        didFinish = false
    }

    /// 同名ファイル確認ダイアログへの回答。applyToRemainingがtrueなら、以降の本には
    /// このダイアログを出さずこの回答をそのまま適用する。
    func resolveOverwrite(_ decision: OverwriteDecision, applyToRemaining: Bool) {
        if applyToRemaining {
            rememberedOverwriteDecision = decision
        }
        pendingOverwriteBookDisplayName = nil
        overwriteDecisionContinuation?.resume(returning: decision)
        overwriteDecisionContinuation = nil
    }

    private func askOverwriteDecision(for displayName: String) async -> OverwriteDecision {
        if let remembered = rememberedOverwriteDecision {
            return remembered
        }
        pendingOverwriteBookDisplayName = displayName
        return await withCheckedContinuation { continuation in
            overwriteDecisionContinuation = continuation
        }
    }

    func startExport(destinationFolder: URL) async {
        let targets = rows.filter { selectedBookIDs.contains($0.bookID) }
        guard !targets.isEmpty else { return }

        isExporting = true
        isCancelled = false
        failures = []
        successCount = 0
        completedCount = 0
        totalCount = targets.count
        rememberedOverwriteDecision = nil
        didFinish = false

        for row in targets {
            guard !isCancelled else { break }
            currentBookDisplayName = row.displayName
            do {
                try await exportOne(row: row, destinationFolder: destinationFolder)
                successCount += 1
            } catch is ExportSkippedByUser {
                // ユーザーがこの本のスキップを選んだ場合。失敗としては扱わない。
            } catch {
                failures.append(FailureReport(displayName: row.displayName, message: error.localizedDescription))
            }
            completedCount += 1
        }

        isExporting = false
        currentBookDisplayName = nil
        didFinish = true
    }

    private func exportOne(row: Row, destinationFolder: URL) async throws {
        guard let sourceURL = resolveURL(forBookID: row.bookID) else {
            throw SimpleError(message: String(localized: "The original file/folder couldn't be found."))
        }
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let book = try await BookLoader.load(from: sourceURL)
        let settings = layoutStore.bookLayoutSettings(forBookID: row.bookID)
        var overrides: [String: PageLayoutState] = [:]
        for override in layoutStore.pageOverrides(forBookID: row.bookID) {
            overrides[override.pageKey] = override.state
        }

        // settings?.pageOrderOverrideはJSON文字列をその都度デコードする計算プロパティのため、
        // この関数内で2回(EffectivePageOrder.pageKeys呼び出し用とEpubExportInput用)使うぶんを
        // まとめて1回だけ読んでおく(結果は同一)。
        let pageOrderOverride = settings?.pageOrderOverride
        let excludedKeys = includeExcludedPages
            ? []
            : Set(overrides.filter { $0.value == .excluded }.map(\.key))
        let orderedKeys = EffectivePageOrder.pageKeys(
            for: book, pageOrderOverride: pageOrderOverride, excludedKeys: excludedKeys
        )

        let bookmarksSorted = bookmarkStore.bookmarks(forBookID: row.bookID).sorted { $0.pageIndex < $1.pageIndex }
        var exportBookmarks: [EpubExportBookmark] = []
        for bookmark in bookmarksSorted {
            guard orderedKeys.indices.contains(bookmark.pageIndex) else { continue }
            exportBookmarks.append(EpubExportBookmark(pageKey: orderedKeys[bookmark.pageIndex], name: bookmark.name))
        }

        // Apple Books互換性(ユーザー要望): 本ごとの読み方向の上書きが無い場合、EPUBの
        // spineにpage-progression-directionを一切出力しないと、Apple Booksは既定でLTRとして
        // 開いてしまい、右開き(日本式)の本が正しく認識されない。以前はsettings?.
        // readingDirectionOverrideがnilのときreadingDirectionOverrideもnilのまま渡していたため、
        // 本ごとに明示的な上書きを設定していない(＝アプリの環境設定の既定値に従っている)
        // 大多数の本でこの属性が欠落していた。環境設定の既定読み方向をフォールバックとして
        // 使うことで、常に明示的なpage-progression-directionを出力するようにする。
        let readingDirection = settings?.readingDirectionOverride ?? preferences.defaultReadingDirection
        let metadata = metadataStore.metadata(forBookID: row.bookID)
        let input = EpubExportInput(
            book: book,
            pageOrderOverride: pageOrderOverride,
            pageOverrides: overrides,
            readingDirectionOverride: readingDirection,
            forcedDisplayMode: settings?.forcedDisplayMode,
            bookmarks: exportBookmarks,
            coverOverride: resolveCoverOverride(settings: settings),
            titleOverride: titleOverrides[row.bookID],
            author: authorOverrides[row.bookID],
            // シリーズ名・巻数はこの画面に入力欄が無く、メタデータDBの登録内容をそのまま使う
            // (ユーザー要望: 登録がある場合はそちらを優先する)。巻数はEPUBのgroup-positionが
            // 数値必須のため、数値として解釈できる場合だけ書き出す
            // (BookMetadata.exportableSeriesIndex参照)。
            series: metadata?.series,
            seriesIndex: metadata?.exportableSeriesIndex,
            language: exportLanguageCode
        )
        let options = EpubExportOptions(
            renumberImagesSequentially: renumberImagesSequentially, includeExcludedPages: includeExcludedPages
        )

        let destinationFileURL = destinationFolder.appendingPathComponent("\(row.displayName).epub")
        if FileManager.default.fileExists(atPath: destinationFileURL.path) {
            let decision = await askOverwriteDecision(for: row.displayName)
            guard decision == .overwrite else { throw ExportSkippedByUser() }
        }

        try await EpubExporter.export(input, options: options, to: destinationFileURL)
    }

    /// EPUBのdc:languageへ書き出す言語タグ。
    ///
    /// ユーザー報告: 従来固定で出力していた"und"(言語不明)をKindle Previewerがエラーとして
    /// 弾くため、実際の言語コードを入れる必要がある。qooViewerが扱うのは画像ベースのコミックで
    /// 本文テキストを持たず、本の内容から言語を判定する手立てが無いため、アプリの表示言語設定
    /// (AppPreferences.effectiveLocale。「システムに従う」ならOSのロケール)を根拠にする。
    ///
    /// languageCodeが取れない(ロケール識別子に言語が含まれない)極端なケースでは"en"にする
    /// (EpubExporter側にも同じフォールバックがあるが、値を決める責任はこちらに寄せておく)。
    private var exportLanguageCode: String {
        preferences.effectiveLocale.language.languageCode?.identifier ?? "en"
    }

    /// ユーザー要望: カバー画像を選択・変更できるようにしたい。BookLayoutSettingsの上書き設定を
    /// EpubExporter向けのEpubCoverOverrideへ変換する(未設定ならnil=既定の先頭ページ)。
    private func resolveCoverOverride(settings: BookLayoutSettings?) -> EpubCoverOverride? {
        guard let settings else { return nil }
        if let pageKey = settings.coverPageKey {
            return .existingPage(pageKey: pageKey)
        }
        guard settings.externalCoverBookmarkData != nil,
              let url = layoutStore.resolvedExternalCoverURL(forBookID: settings.bookID)
        else { return nil }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
        return .externalFile(data: data, fileExtension: ext)
    }
}

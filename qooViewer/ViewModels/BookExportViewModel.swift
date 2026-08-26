import Foundation
import SwiftUI
import Combine

/// EPUB / PDF / CBZ の各出力ウインドウが共通で使うロジックの基底クラス。
///
/// 元々はEpubExportViewModelだけがあり、PDF出力を足す際にほぼ丸ごとコピーされ、
/// 「EpubExportViewModelの同種のコメント参照」という注意書きで2本が並行して保守されていた。
/// CBZ出力を足すと3本目の同じコピーになるため、共通部分をここへ集約し、各形式は
/// 「1冊ぶんの材料をどの形で書き出すか」の差分だけを持つサブクラスにしてある。
///
/// ここに集約したもの:
/// - 対象一覧の組み立てと実在確認(reload / applyEligibleBookIDs)
/// - タイトル・著者名の編集欄(titleOverrides / authorOverrides)
/// - カバー画像の選択(supportsCoverSelectionがtrueのサブクラスのみ使う)
/// - 出力先の空き容量チェック
/// - 出力の進捗・キャンセル・同名ファイル確認・失敗集約(startExport)
///
/// サブクラスが必ず用意するもの(下の「サブクラスの拡張点」参照):
/// - outputFileExtension
/// - export(_:to:)
///
/// @MainActor: SwiftUIのView(@ObservedObject)から直接観測される。
@MainActor
class BookExportViewModel: ObservableObject {
    /// 対象一覧の1行。レイアウト・ブックマーク・メタデータのいずれかを持つ本。
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

    /// 同名ファイルの確認でユーザーが「スキップ」を選んだことを表す内部エラー。
    /// startExportはこれを失敗として数えない。
    struct ExportSkippedByUser: Error {}

    struct SimpleError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 1冊ぶんの書き出しに必要な材料のうち、形式に依らない共通部分。
    /// 基底クラスがDB・ファイルから集めてサブクラスのexport(_:to:)へ渡す
    /// (各形式のExportInputは、この内容を自分の語彙へ詰め替えるだけで済む)。
    struct PreparedBook {
        let row: Row
        /// BookLoaderで読み込んだ、並べ替え前・除外前の生のMangaBook。
        let book: MangaBook
        let pageOrderOverride: [String]?
        /// pageKey(PageRef.sortKey) -> レイアウト状態。
        let pageOverrides: [String: PageLayoutState]
        /// 本ごとの上書き。無い場合はnil(サブクラス側で環境設定の既定へ落とすかを判断する)。
        let forcedDisplayMode: DisplayMode?
        /// 本ごとの上書きが無い場合は環境設定の既定読み方向で埋めた、常に確定した読み方向。
        ///
        /// Apple Books互換性(ユーザー要望): 本ごとの読み方向の上書きが無い場合、EPUBの
        /// spineにpage-progression-directionを一切出力しないと、Apple Booksは既定でLTRとして
        /// 開いてしまい、右開き(日本式)の本が正しく認識されない。以前はsettings?.
        /// readingDirectionOverrideがnilのときnilのまま渡していたため、本ごとに明示的な
        /// 上書きを設定していない(＝アプリの環境設定の既定値に従っている)大多数の本で
        /// この属性が欠落していた。CBZのComicInfo.xml(Manga要素)も事情はまったく同じ。
        let readingDirection: ReadingDirection
        /// 実際の出力順に対応するpageKeyへ解決済みのブックマーク。
        let bookmarks: [ExportBookmark]
        /// カバーの上書き指定(supportsCoverSelectionがfalseのサブクラスでは常にnil)。
        let coverOverride: ExportCoverOverride?
        /// この画面で編集されたタイトル。空文字/nilなら未編集扱い。
        let title: String?
        /// この画面で編集された著者名。空文字/nilなら未編集扱い。
        let author: String?
        /// メタデータDBの登録内容(シリーズ名・巻数を読むために渡す)。未登録ならnil。
        let metadata: BookMetadata?
    }

    @Published private(set) var rows: [Row] = []
    @Published var selectedBookIDs: Set<String> = []
    /// 対象一覧の絞り込み(実在確認)が進行中かどうか。ウインドウ側はこの間、
    /// 「対象の本がありません」ではなく読み込み中の表示にする(reload()参照)。
    @Published private(set) var isLoadingRows = false

    /// 絞り込みの世代番号。applyEligibleBookIDs(_:generation:)が「自分が最新の結果か」を
    /// 単体で判断できるようにするためのもの。
    ///
    /// 下のisReloadingによる間引きが入った今、絞り込みは同時に1本しか走らないため、この
    /// 照合が実際に食い違うことは無い。それでも残してあるのは、結果を反映してよいかどうかの
    /// 判断をapplyEligibleBookIDs自身の中で完結させておくためで、将来この経路が増えたときに
    /// 古い結果が紛れ込むのを防ぐ。
    private var reloadGeneration = 0
    /// 絞り込みが実行中かどうか。実行中に来たreload()の要求は、走らせ直さずに
    /// needsAnotherReloadへ畳む(reload()参照)。
    private var isReloading = false
    /// 実行中に来たreload()の要求を1回ぶんだけ覚えておくフラグ。
    private var needsAnotherReload = false

    // MARK: - タイトル・著者名(ユーザー要望: ファイル名/フォルダ名から推測した値を初期値にし、
    // この画面で変更できるようにしたい)

    /// bookID -> タイトル(編集可能)。reload()で新しく現れた本にだけ、メタデータDBの登録内容、
    /// 無ければファイル名/フォルダ名からTitleAuthorFilenameParserで推測した値を初期値として
    /// 設定する(既存の編集内容は保持する)。
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

    // MARK: - 出力オプション

    /// 画像ファイルの連番リネーム。ONの場合、書き出す順序(ページ順補正を反映済み)を基準に、
    /// 桁数可変の連番("000.jpg"など)へリネームする。
    ///
    /// PDF出力はページごとの画像ファイル名という概念自体を持たないため、この値を使わない
    /// (PDFExportOptionsにも対応する項目は無い)。既定値は形式によって異なるため、
    /// 必要なサブクラスが自身のinitで設定し直す(CBZは既定ONにしている。理由はそちら参照)。
    @Published var renumberImagesSequentially = false
    /// 除外(非表示)ページを含めるか。false(既定)なら除外ページは出力に含めない。
    @Published var includeExcludedPages = false

    // MARK: - 実行中の状態

    @Published private(set) var isExporting = false
    @Published private(set) var currentBookDisplayName: String?
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    private var isCancelled = false

    // MARK: - 同名ファイルの確認

    @Published private(set) var pendingOverwriteBookDisplayName: String?
    private var overwriteDecisionContinuation: CheckedContinuation<OverwriteDecision, Never>?
    private var rememberedOverwriteDecision: OverwriteDecision?

    // MARK: - 結果

    @Published private(set) var failures: [FailureReport] = []
    @Published private(set) var successCount = 0
    @Published private(set) var didFinish = false

    let bookmarkStore: BookmarkStore
    let layoutStore: LayoutStore
    let metadataStore: BookMetadataStore
    let preferences: AppPreferences

    /// これらの画面はWindow(id:)という単一インスタンスのシーンで開くため、一度表示された
    /// ViewModelはウインドウを閉じても(BookmarkListView.BookmarkEditorViewの
    /// BookmarkStore/LayoutStoreと違い)アプリを終了するまで使い回される。そのため、初期化時の
    /// reload()一発きりでは、この画面を開いた後に「ブックマーク・レイアウトの編集」ウインドウで
    /// 別の本のレイアウト・ブックマークを新規に追加しても一覧に反映されず、アプリを再起動しない
    /// 限り一覧に出てこない、という不具合(ユーザー報告)があった。
    ///
    /// BookmarkStore/LayoutStore/ViewerViewModelと同じく、bookmarksDidChange /
    /// layoutDataDidChange / bookMetadataDidChange通知を受けてreload()し直すことで、この
    /// ウインドウを開いたままでも常に最新の対象一覧を表示できるようにする。
    private var changeObservers: [NSObjectProtocol] = []

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
        for name in [Notification.Name.bookmarksDidChange, .layoutDataDidChange, .bookMetadataDidChange] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reload()
                }
            }
            changeObservers.append(observer)
        }
    }

    deinit {
        for observer in changeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        // loadBook(forBookID:)で開いたセキュリティスコープ付きアクセスを閉じる
        // (securityScopedURLsのコメント参照)。
        for url in securityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - サブクラスの拡張点

    /// 出力ファイルの拡張子("epub" / "pdf" / "cbz")。出力先のファイル名の決定にだけ使う。
    ///
    /// Swiftには抽象メンバーの仕組みが無いため、既定実装をpreconditionFailureにして
    /// 「サブクラスで必ず上書きすること」を実行時に強制している(この基底クラスは
    /// 直接インスタンス化されない)。
    var outputFileExtension: String {
        preconditionFailure("サブクラスで必ず上書きすること")
    }

    /// カバー画像の選択機能を持つか。trueのサブクラス(EPUB / CBZ)では、カバー画像だけを
    /// 上書き設定している本も対象一覧に含め、カバー列の解決処理も動かす。
    /// PDF出力はカバーの概念自体を持たないためfalse(PDFExportInputのコメント参照)。
    var supportsCoverSelection: Bool { false }

    /// 1冊ぶんの実際の書き出し。基底クラスが集めた材料を、自分の形式のExportInput/Optionsへ
    /// 詰め替えてExporterを呼ぶだけでよい。
    func export(_ prepared: PreparedBook, to destinationURL: URL) async throws {
        preconditionFailure("サブクラスで必ず上書きすること")
    }

    // MARK: - 対象一覧

    /// 対象一覧を読み直す。レイアウト情報・ブックマーク情報・メタデータのいずれかを持つ本を
    /// 対象にする。カバー画像だけを上書き設定している本(読み方向・ページ順等の上書きは無い)は、
    /// カバー選択機能を持つサブクラスでのみ対象に含める(layoutStore.layoutBookIDsは
    /// isBookLevelSettingEmptyでカバー関連プロパティを見ていないため、これだけでは拾えない)。
    ///
    /// 元のファイル形式による制限は設けない(ユーザー要望。zip/cbz・rar/cbr・7z/cb7・pdf・
    /// epub・フォルダのすべてが対象。元がPDFの場合の画像の扱いはPDFImageExtractor参照)。
    ///
    /// バグ修正(ユーザー報告): 過去にレイアウトやブックマークを編集した本の元ファイル/フォルダを
    /// 後から削除しても、DB上のBookLayoutSettings/Bookmarkレコード自体は(設計コンセプト10.3節の
    /// 方針により)自動削除されず残り続けるため、それだけで一覧に表示されてしまっていた。
    /// BookURLResolverはセキュリティスコープ付きブックマークの解決先(無ければ生パス)について
    /// FileManager.fileExistsを確認したうえで返す(見つからなければnil)ため、これを使って
    /// 実在が確認できた本だけに絞り込む。
    ///
    /// ユーザー報告と同じ構図の改善: この実在確認は、登録済みの本1冊ごとにセキュリティスコープ
    /// 付きブックマークの解決を行う。以前はこれをメインスレッドで同期実行していたため、本体が
    /// 未接続の外付け/ネットワークボリューム上にあると、このウインドウを開くだけでその間ずっと
    /// 操作を受け付けなくなっていた。SwiftDataから材料を集める部分(軽い)だけをここで行い、
    /// 解決本体はメインアクターの外へ逃がす(BookURLResolver参照)。結果が返るまでは一覧を
    /// 空にせず、直前の内容をそのまま見せておく。
    ///
    /// 絞り込みが実行中に呼ばれた場合は、その場では走らせず1回ぶんだけ覚えておいて、
    /// 完了後にやり直す。このメソッドはブックマーク・レイアウト・メタデータの3つの変更通知から
    /// 呼ばれるため、他のウインドウで編集を続けられると、そのたびに登録済みの本すべてに対する
    /// 実在確認が積み上がる。メインスレッドは止まらないが、無駄であることに変わりはない。
    final func reload() {
        guard !isReloading else {
            needsAnotherReload = true
            return
        }
        isReloading = true

        var bookIDs = layoutStore.layoutBookIDs
        bookIDs.formUnion(bookmarkStore.groups.map(\.bookID))
        if supportsCoverSelection {
            bookIDs.formUnion(layoutStore.coverOverrideBookIDs())
        }
        bookIDs.formUnion(metadataStore.registeredBookIDs)

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
        isReloading = false
        defer {
            // 絞り込み中に来ていたreload()の要求があれば、ここでやり直す。
            if needsAnotherReload {
                needsAnotherReload = false
                reload()
            }
        }
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
        // そちらを優先し、無い本だけファイル名/フォルダ名から推測する。
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

    // MARK: - 一括選択

    /// ユーザー要望により、上部の「選択」メニュー(4条件)と「選択解除」ボタンは廃止し、
    /// 代わりに一覧のタイトル行にチェックボックスを設けて全選択/全選択解除を行う形にした
    /// (各出力ウインドウのcolumnHeaderRowのselectAllBinding参照)。
    final func selectAll() { selectedBookIDs = Set(rows.map(\.bookID)) }
    final func deselectAll() { selectedBookIDs.removeAll() }

    // MARK: - カバー画像(supportsCoverSelectionがtrueのサブクラスのみ使う)

    /// カバー列に表示する名前のキャッシュ(bookID -> 表示名)。上書き設定がある場合は
    /// BookLayoutSettingsに保存済みの値をそのまま使えるが、既定(先頭ページ)の場合は本を
    /// 読み込んで確認する必要があるため、非同期で解決してここへキャッシュする
    /// (refreshCoverName(forBookID:)参照)。
    @Published private(set) var resolvedCoverNames: [String: String] = [:]

    /// カバー列の表示文字列。まだ解決できていない間は読み込み中であることが分かる文字列を返す。
    final func coverDisplayName(forBookID bookID: String) -> String {
        resolvedCoverNames[bookID] ?? String(localized: "Loading…")
    }

    /// この本のカバー表示名を最新化する。呼び出し元(カバー列のセル)の.taskから、行の表示中に
    /// 一度だけ呼ぶ想定(BookmarkListView.PageRowViewのサムネイル読み込みと同じ考え方)。
    final func refreshCoverName(forBookID bookID: String) async {
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
                // 書庫の中のフォルダ・入れ子の書庫の中にある画像は、ファイル名だけでは
                // どのページか区別できないため、本の直下からの相対パスで表示する
                // (PageLocation参照)。folderPathを持たない古いキャッシュではnilになり、
                // 従来どおりファイル名だけになる。
                //
                // EPUBをここでも改めて弾いているのは、**この経路だけが本体を読み直さない**ため。
                // EPUBのfolderPathを残していた頃のキャッシュが手元にあると、その本を開き直す
                // まで`OEBPS/Images/001.jpg`のままになってしまう。
                let folderPath = isEpubFile(bookID) ? nil : first.folderPath
                resolvedCoverNames[bookID] = folderPath.map { "\($0)/\(first.displayName)" }
                    ?? first.displayName
                return
            }
        }

        guard let book = await loadBook(forBookID: bookID) else { return }
        let ordered = EffectivePageOrder.orderedPages(
            for: book, pageOrderOverride: settings?.pageOrderOverride, excludedKeys: excludedKeys
        )
        guard let first = ordered.first else { return }
        resolvedCoverNames[bookID] = first.location(inBookAt: book.sourceURL).fullPath
    }

    /// カバーピッカー(本のページ一覧を表示する画面)から呼ばれる。この本を読み込んで返す
    /// (セキュリティスコープ付きアクセスはBookLayoutEditorViewModel.loadと同じく、ウインドウが
    /// 開いている間ずっとサムネイルを読み込めるよう、明示的に閉じずに保持したままにし、
    /// deinitでまとめて閉じる。securityScopedURLsのコメント参照)。
    final func loadBookForCoverPicker(bookID: String) async -> MangaBook? {
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
    final func setCover(forBookID bookID: String, book: MangaBook, page: PageRef) {
        // 表示名は、書庫の中のフォルダ・入れ子の書庫まで含めた本の中での相対パスで持つ
        // (ファイル名だけでは、章ごとに001.jpgから振り直されている本でどのページを
        // カバーにしたのか分からないため。PageLocation参照)。
        let coverName = page.location(inBookAt: book.sourceURL).fullPath
        layoutStore.setCoverPageKey(for: book, pageKey: page.sortKey, displayName: coverName)
        resolvedCoverNames[bookID] = coverName
    }

    /// 本に含まれない専用ファイルをカバーに指定する。この専用ファイルは本の一部として扱わない
    /// ため、ビューアのページ一覧には現れない(LayoutStore.setExternalCoverのコメント参照)。
    final func setExternalCover(forBookID bookID: String, book: MangaBook, fileURL: URL) {
        guard (try? layoutStore.setExternalCover(for: book, fileURL: fileURL)) != nil else { return }
        resolvedCoverNames[bookID] = fileURL.lastPathComponent
    }

    /// カバーの上書きを解除し、既定(先頭ページ)に戻す。
    final func resetCover(forBookID bookID: String) {
        layoutStore.clearCoverOverride(forBookID: bookID)
        resolvedCoverNames.removeValue(forKey: bookID)
        Task { await refreshCoverName(forBookID: bookID) }
    }

    /// BookLayoutSettingsの上書き設定を、Exporterが受け取るExportCoverOverrideへ変換する
    /// (未設定ならnil=既定の先頭ページ)。
    private func resolveCoverOverride(settings: BookLayoutSettings?) -> ExportCoverOverride? {
        guard supportsCoverSelection, let settings else { return nil }
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

    // MARK: - 空き容量チェック

    /// 選択されている本の元ファイル/フォルダの合計サイズ。アーカイブ・PDFはfileSizeKey、
    /// フォルダは中の画像ファイルサイズを再帰合計する。
    final func totalSourceSize() -> Int64 {
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
    final func availableCapacity(at folderURL: URL) -> Int64? {
        let values = try? folderURL.resourceValues(
            forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        )
        if let plain = values?.volumeAvailableCapacity {
            return Int64(plain)
        }
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// 出力先の空き容量が合計サイズの1.2倍未満なら警告(false)。
    /// どの形式も画像を再圧縮せずそのまま埋め込むため、元とおおむね近いサイズになる想定で、
    /// 同じ倍率をそのまま使う。
    final func hasSufficientDiskSpace(at folderURL: URL) -> Bool {
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
    private func resolveURL(forBookID bookID: String) -> URL? {
        bookmarkStore.resolvedURLFromBookmarkData(forBookID: bookID)
            ?? layoutStore.resolvedURL(forBookID: bookID)
            ?? metadataStore.resolvedURL(forBookID: bookID)
    }

    // MARK: - 出力実行

    final func cancel() {
        isCancelled = true
    }

    /// 結果シートを閉じる(OKボタン、またはシート自体のスワイプ/×での閉じ操作)。
    final func acknowledgeFinish() {
        didFinish = false
    }

    /// 同名ファイル確認ダイアログへの回答。applyToRemainingがtrueなら、以降の本には
    /// このダイアログを出さずこの回答をそのまま適用する。
    final func resolveOverwrite(_ decision: OverwriteDecision, applyToRemaining: Bool) {
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

    final func startExport(destinationFolder: URL) async {
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

    /// 1冊ぶんの材料をDB・ファイルから集め、出力先を確定して、サブクラスのexport(_:to:)へ渡す。
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
        // この関数内で2回(EffectivePageOrder.pageKeys呼び出し用とPreparedBook用)使うぶんを
        // まとめて1回だけ読んでおく(結果は同一)。
        let pageOrderOverride = settings?.pageOrderOverride
        let excludedKeys = includeExcludedPages
            ? []
            : Set(overrides.filter { $0.value == .excluded }.map(\.key))
        let orderedKeys = EffectivePageOrder.pageKeys(
            for: book, pageOrderOverride: pageOrderOverride, excludedKeys: excludedKeys
        )

        let bookmarksSorted = bookmarkStore.bookmarks(forBookID: row.bookID).sorted { $0.pageIndex < $1.pageIndex }
        var exportBookmarks: [ExportBookmark] = []
        for bookmark in bookmarksSorted {
            guard orderedKeys.indices.contains(bookmark.pageIndex) else { continue }
            exportBookmarks.append(ExportBookmark(pageKey: orderedKeys[bookmark.pageIndex], name: bookmark.name))
        }

        let prepared = PreparedBook(
            row: row,
            book: book,
            pageOrderOverride: pageOrderOverride,
            pageOverrides: overrides,
            forcedDisplayMode: settings?.forcedDisplayMode,
            readingDirection: settings?.readingDirectionOverride ?? preferences.defaultReadingDirection,
            bookmarks: exportBookmarks,
            coverOverride: resolveCoverOverride(settings: settings),
            title: titleOverrides[row.bookID],
            author: authorOverrides[row.bookID],
            metadata: metadataStore.metadata(forBookID: row.bookID)
        )

        let destinationFileURL = destinationFolder
            .appendingPathComponent("\(row.displayName).\(outputFileExtension)")
        if FileManager.default.fileExists(atPath: destinationFileURL.path) {
            let decision = await askOverwriteDecision(for: row.displayName)
            guard decision == .overwrite else { throw ExportSkippedByUser() }
        }

        // **出力先へ直接書かず、必ず一時ファイルへ書いてから最後に置き換える。**
        //
        // バグ修正: 出力先フォルダに元の本と同じ場所を選ぶと(cbzを開いてcbzとして書き出す、
        // pdfをpdfとして書き出す、といった「その場で作り直す」使い方はごく自然に起こりうる)、
        // 出力先のパスが元ファイルのパスとまったく同じになる。各Exporterは書き込みを始める前に
        // 既存の出力先ファイルを削除するため、その時点で**元ファイルそのものが消える**。
        // ページ画像は書き込みループの中で元ファイルから1枚ずつ読み出す作りなので、
        // 削除された直後に読み出しが失敗し、元の本も出力も両方失われていた。
        //
        // 一時ファイルは出力先と同じフォルダに作る。別ボリュームをまたがないため最後の
        // 置き換えが単なるリネームで済み、書き出しの途中で失敗したり、ユーザーがキャンセル
        // したりした場合も、出力先には中途半端なファイルが残らない
        // (PDFExporterが「壊れたファイルだけが残る」不具合を直したときと同じ考え方を、
        //  3つの形式すべてに効く1か所へ寄せたもの)。
        let temporaryURL = destinationFolder.appendingPathComponent(
            ".qooViewer-export-\(UUID().uuidString).\(outputFileExtension)"
        )
        do {
            try await export(prepared, to: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        do {
            if FileManager.default.fileExists(atPath: destinationFileURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationFileURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationFileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// 出力ファイルへ書き出す言語タグ(EPUBのdc:language、CBZのComicInfo.xmlのLanguageISO)。
    ///
    /// ユーザー報告: EPUBで従来固定出力していた"und"(言語不明)をKindle Previewerがエラーとして
    /// 弾くため、実際の言語コードを入れる必要がある。qooViewerが扱うのは画像ベースのコミックで
    /// 本文テキストを持たず、本の内容から言語を判定する手立てが無いため、アプリの表示言語設定
    /// (AppPreferences.effectiveLocale。「システムに従う」ならOSのロケール)を根拠にする。
    ///
    /// languageCodeが取れない(ロケール識別子に言語が含まれない)極端なケースでは"en"にする
    /// (Exporter側にも同じフォールバックがあるが、値を決める責任はこちらに寄せておく)。
    var exportLanguageCode: String {
        preferences.effectiveLocale.language.languageCode?.identifier ?? "en"
    }
}

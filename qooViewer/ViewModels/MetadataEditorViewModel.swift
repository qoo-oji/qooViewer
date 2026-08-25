import Foundation
import SwiftUI
import SwiftData
import Combine

/// 「メタデータの編集」ウインドウのロジックを担当する。EpubExportViewModel/
/// BookLayoutEditorViewModelと同じく、対象一覧・編集中の値・登録/解除の実処理をこのクラスへ
/// 集約し、View側は表示に専念する。
///
/// 一覧に並べる本は「このアプリが何らかの形で知っている本」すべて(ユーザー選択)。具体的には
/// 読書履歴(BookReadingState)・お気に入り・ブックマーク・レイアウト設定・登録済みメタデータの
/// いずれかに記録がある本のbookIDを、重複を除いて集めたもの。実ファイルの存在確認による
/// 絞り込みは行わない(サンドボックス環境では、アクセス権を持たないパスに対する存在確認自体が
/// 失敗するため、絞り込むと大半の本が一覧から消えてしまう。加えて、メタデータはファイルが
/// 一時的に接続されていない外部ボリュームにあっても保持し続けたい情報である)。
@MainActor
final class MetadataEditorViewModel: ObservableObject {

    /// 一覧の1行。ファイル名は編集不可で、それ以外の4項目が編集対象になる。
    struct Row: Identifiable, Equatable {
        let bookID: String
        /// 拡張子付きの実際のファイル名(フォルダの場合はフォルダ名)。一覧の「ファイル名」列に
        /// そのまま表示する。
        let fileName: String
        /// 拡張子を除いたファイル名。メタデータの推測(BookMetadataDeriver)に使う。
        let baseName: String
        var id: String { bookID }
    }

    /// 1行分の編集中の値。登録済みならDBの値、未登録ならファイル名からの推測値で初期化する。
    struct Draft: Equatable {
        var author = ""
        var title = ""
        var series = ""
        var seriesIndex = ""

        init() {}

        init(_ derived: DerivedBookMetadata) {
            author = derived.author
            title = derived.title
            series = derived.series
            seriesIndex = derived.seriesIndex
        }

        init(_ metadata: BookMetadata) {
            author = metadata.author
            title = metadata.title
            series = metadata.series
            seriesIndex = metadata.seriesIndex
        }

        var isEmpty: Bool {
            author.isEmpty && title.isEmpty && series.isEmpty && seriesIndex.isEmpty
        }
    }

    /// 検索文字列で絞り込んだ後の表示対象。
    @Published private(set) var rows: [Row] = []
    /// bookID -> 編集中の値。
    @Published var drafts: [String: Draft] = [:]
    /// 一覧上部の検索文字列(ファイル名・著者・タイトル・シリーズを対象に部分一致で絞り込む)。
    @Published var searchText: String = "" {
        didSet { guard oldValue != searchText else { return }; rebuildRows() }
    }
    /// 絞り込み前の全件数(「N件中M件を表示」のような表示に使う)。
    @Published private(set) var totalRowCount = 0
    /// ファイル名からの推測をメインアクターの外で実行中かどうか。
    ///
    /// 推測が終わるまで一覧の代わりに進捗表示を出すために使う。推測前の空欄を一度出してから
    /// 埋めると、ほぼ全部の行が未登録である普通の状態では、一覧全体が一瞬空になって見える。
    @Published private(set) var isPreparingDrafts = false

    private let metadataStore: BookMetadataStore
    private let formatStore: MetadataFormatStore
    private let bookmarkStore: BookmarkStore
    private let layoutStore: LayoutStore
    private let favoritesStore: FavoritesStore
    private let modelContext: ModelContext

    /// 絞り込み前の全行(検索文字列に関わらず保持しておき、検索のたびに集め直さずに済ませる)。
    private var allRows: [Row] = []
    /// bookID -> ファイル名から推測した値のキャッシュ。推測1件あたり十数本の正規表現照合が
    /// 走るため、行の再構築(通知による再読み込み・検索・スクロール)のたびにやり直さずに済むよう
    /// 保持する。フォーマット定義が変わったとき(derivedCacheRevisionの不一致)にだけ捨てる。
    private var derivedCache: [String: DerivedBookMetadata] = [:]
    private var derivedCacheRevision: Int

    private var observers: [NSObjectProtocol] = []
    private var formatChangeCancellable: AnyCancellable?

    init(
        metadataStore: BookMetadataStore,
        formatStore: MetadataFormatStore,
        bookmarkStore: BookmarkStore,
        layoutStore: LayoutStore,
        favoritesStore: FavoritesStore,
        modelContext: ModelContext
    ) {
        self.metadataStore = metadataStore
        self.formatStore = formatStore
        self.bookmarkStore = bookmarkStore
        self.layoutStore = layoutStore
        self.favoritesStore = favoritesStore
        self.modelContext = modelContext
        self.derivedCacheRevision = formatStore.revision
        reload()

        // このウインドウはWindow(id: "editMetadata")という単一インスタンスのシーンで開くため、
        // 一度作られたViewModelは閉じてもアプリ終了まで使い回される。開いたまま別ウインドウで
        // ブックマーク・レイアウトを追加した場合にも一覧が追随するよう、他のストアと同じく
        // 変更通知を購読して読み直す(EpubExportViewModel.initの同種のコメント参照)。
        //
        // queue: .mainを指定しているため実行時には必ずMainActor上で呼ばれるが、クロージャ自体の
        // 型はMainActorに分離されていないため、コンパイラは静的にそれを保証できない。
        for name in [Notification.Name.bookmarksDidChange, .layoutDataDidChange, .bookMetadataDidChange] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
            observers.append(observer)
        }

        // フォーマット定義が変わったら、推測値のキャッシュを捨てて全行を作り直す
        // (未登録の行の表示内容が変わるため。登録済みの行はDBの値なので影響を受けない)。
        formatChangeCancellable = formatStore.$revision
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateDerivedValues() }
            }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 一覧の構築

    /// 対象の本を集め直し、行と編集中の値を作り直す。
    ///
    /// 既にユーザーが編集中の値(drafts)は保持する。ウインドウを開いたまま別の本を開いた
    /// (=一覧に行が増えた)ときに、入力途中の内容が消えてしまわないようにするため。
    /// ただし登録・解除の直後だけは、その本の値をDB/推測値から作り直す
    /// (refreshDraft(forBookID:)を明示的に呼ぶ)。
    func reload() {
        let bookIDs = collectKnownBookIDs()
        allRows = bookIDs
            .map { bookID -> Row in
                let url = URL(fileURLWithPath: bookID)
                return Row(bookID: bookID, fileName: url.lastPathComponent, baseName: Self.baseName(forBookID: bookID))
            }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        totalRowCount = allRows.count

        // 編集中の値がまだ無い行を埋める。DBの値・推測済みのキャッシュから即座に埋められる
        // ものはここで埋め、実際に正規表現を回す必要がある行だけを非同期の推測へ回す
        // (scheduleDerivation参照)。
        var pending: [Row] = []
        for row in allRows where drafts[row.bookID] == nil {
            if let metadata = metadataStore.metadata(forBookID: row.bookID) {
                drafts[row.bookID] = Draft(metadata)
            } else if let cached = cachedDerivedMetadata(forBookID: row.bookID) {
                drafts[row.bookID] = Draft(cached)
            } else {
                pending.append(row)
            }
        }
        // 一覧から消えた本(データを全部削除した等)の編集中の値は捨てる。
        let liveIDs = Set(allRows.map(\.bookID))
        drafts = drafts.filter { liveIDs.contains($0.key) }

        rebuildRows()
        scheduleDerivation(for: pending)
    }

    // MARK: - ファイル名からの推測(非同期)

    /// 走行中の推測の世代番号。推測を始めるたびに1増やし、完了時に一致するものだけを受け付ける
    /// (通知による再読み込みが重なった場合に、古い結果が後から届いて新しい結果を上書きするのを
    /// 防ぐ。LibraryCleanupViewModel.existenceScanGenerationと同じ考え方)。
    private var derivationGeneration = 0

    /// ファイル名からの推測をメインアクターの外で走らせる。
    ///
    /// 1行あたり、除外文字列・ファイル名フォーマット・巻数フォーマットで十数本の正規表現照合が
    /// 走る。この一覧は数千行になりうるため、メインアクター上でまとめて回すとウインドウを
    /// 開いた瞬間に描画が止まる。BookMetadataDeriver / MetadataFormatCompiler /
    /// CompiledMetadataRuleSetがいずれも`nonisolated`・`Sendable`なのは、まさにこのためにある
    /// (Services/ArchiveReading.swift冒頭のコメント参照)。
    private func scheduleDerivation(for rows: [Row]) {
        guard !rows.isEmpty else { return }
        derivationGeneration &+= 1
        let generation = derivationGeneration
        // ルール一式とファイル名だけをSendableな値として写し取ってから外へ渡す。
        let revision = formatStore.revision
        let rules = formatStore.compiledRules
        let items = rows.map { (bookID: $0.bookID, baseName: $0.baseName) }
        isPreparingDrafts = true
        // [weak self]で受けたselfを、awaitをまたぐ前にguard letで強参照へ変換しておく
        // (理由はRecentFilesStore.scheduleRefresh()の同種のコメント参照)。
        Task.detached(priority: .userInitiated) { [weak self] in
            var derived: [String: DerivedBookMetadata] = [:]
            derived.reserveCapacity(items.count)
            for item in items {
                derived[item.bookID] = BookMetadataDeriver.derive(baseName: item.baseName, rules: rules)
            }
            guard let self else { return }
            await self.applyDerived(derived, generation: generation, revision: revision)
        }
    }

    /// 推測結果を編集中の値へ差し込む。
    private func applyDerived(
        _ derived: [String: DerivedBookMetadata], generation: Int, revision: Int
    ) {
        guard generation == derivationGeneration else { return }
        isPreparingDrafts = false
        // 推測している間にルールが変更されていたら、この結果はもう古い。捨ててやり直す。
        guard revision == formatStore.revision else {
            invalidateDerivedValues()
            return
        }
        derivedCacheRevision = revision
        for (bookID, value) in derived {
            derivedCache[bookID] = value
            // 推測している間にユーザーが編集した/登録した行は上書きしない。
            guard drafts[bookID] == nil, !metadataStore.isRegistered(bookID: bookID) else { continue }
            drafts[bookID] = Draft(value)
        }
        rebuildRows()
    }

    /// 推測済みのキャッシュ(ルールが変わっていれば捨てる)。
    private func cachedDerivedMetadata(forBookID bookID: String) -> DerivedBookMetadata? {
        if derivedCacheRevision != formatStore.revision {
            derivedCache.removeAll(keepingCapacity: true)
            derivedCacheRevision = formatStore.revision
        }
        return derivedCache[bookID]
    }

    /// 「このアプリが知っている本」のbookIDを、重複を除いて集める。
    private func collectKnownBookIDs() -> Set<String> {
        var bookIDs = metadataStore.registeredBookIDs
        bookIDs.formUnion(layoutStore.layoutBookIDs)
        bookIDs.formUnion(layoutStore.coverOverrideBookIDs())
        bookIDs.formUnion(bookmarkStore.groups.map(\.bookID))
        bookIDs.formUnion(favoritesStore.allRegisteredBookIDs())
        // 読書履歴。一度でも開いた本はすべてここに含まれるため、実質的にこれが一覧の母体になる
        // (BookReadingStateはLibraryDataPrunerによって上限件数まで自動的に間引かれる。
        // 環境設定「一般」の「データを保持する本の数」参照)。
        let readingStates = (try? modelContext.fetch(FetchDescriptor<BookReadingState>())) ?? []
        bookIDs.formUnion(readingStates.map(\.bookID))
        return bookIDs
    }

    /// 検索文字列による絞り込みだけをやり直す(対象の本を集め直さない、軽い経路)。
    private func rebuildRows() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            rows = allRows
            return
        }
        rows = allRows.filter { row in
            let draft = drafts[row.bookID]
            let haystack = [row.fileName, draft?.author ?? "", draft?.title ?? "", draft?.series ?? ""]
            return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// フォーマット定義が変わったときに、未登録の行の表示内容を作り直す。
    /// 登録済みの行はDBの値をそのまま使っているため影響を受けない(ユーザー要望:
    /// 「DBに登録されたメタデータは、ファイル名フォーマットや除外文字列を変更しても影響を受けない」)。
    private func invalidateDerivedValues() {
        derivedCache.removeAll(keepingCapacity: true)
        derivedCacheRevision = formatStore.revision
        // 実際の推測はメインアクターの外で行うため(scheduleDerivation参照)、ここでは
        // 対象の行の編集中の値を落として、作り直しを予約するだけにする。
        var pending: [Row] = []
        for row in allRows where !metadataStore.isRegistered(bookID: row.bookID) {
            drafts.removeValue(forKey: row.bookID)
            pending.append(row)
        }
        rebuildRows()
        scheduleDerivation(for: pending)
    }

    /// 行の初期値。登録済みならDBの値、未登録ならファイル名からの推測値。
    private func makeInitialDraft(for row: Row) -> Draft {
        if let metadata = metadataStore.metadata(forBookID: row.bookID) {
            return Draft(metadata)
        }
        return Draft(derivedMetadata(for: row))
    }

    /// 1行だけの推測。登録を解除した直後に、その行の表示を推測値へ戻すために使う
    /// (refreshDraft(forBookID:))。1行ぶんならメインアクター上で回しても一瞬で終わるため、
    /// 非同期にはしない(まとめて数千行を処理するのがscheduleDerivationの役目)。
    private func derivedMetadata(for row: Row) -> DerivedBookMetadata {
        if let cached = cachedDerivedMetadata(forBookID: row.bookID) { return cached }
        let derived = BookMetadataDeriver.derive(baseName: row.baseName, rules: formatStore.compiledRules)
        derivedCache[row.bookID] = derived
        return derived
    }

    /// bookID(フルパス)から、メタデータの推測に使う「拡張子を除いたファイル名」を求める。
    ///
    /// 単純に`deletingPathExtension()`を使うと、拡張子を持たないフォルダ名の一部が拡張子として
    /// 削られてしまう(例: 「作品名 vol.3」というフォルダが「作品名 vol」になり、巻数が
    /// 取れなくなる)。qooViewerが本として開けるファイル形式の拡張子である場合にだけ削ることで、
    /// フォルダ名を壊さないようにする。
    static func baseName(forBookID bookID: String) -> String {
        let url = URL(fileURLWithPath: bookID)
        let fileName = url.lastPathComponent
        guard isArchiveFile(fileName) || isPDFFile(fileName) || isEpubFile(fileName) else { return fileName }
        return url.deletingPathExtension().lastPathComponent
    }

    // MARK: - 編集中の値へのアクセス(View側のTextField用)

    /// EpubExportViewModel.titleBinding(forBookID:)と同じ考え方。@Publishedな辞書を
    /// TextFieldから直接編集できるようにする。
    func binding(forBookID bookID: String, keyPath: WritableKeyPath<Draft, String>) -> Binding<String> {
        Binding(
            get: { self.drafts[bookID]?[keyPath: keyPath] ?? "" },
            set: { newValue in
                var draft = self.drafts[bookID] ?? Draft()
                draft[keyPath: keyPath] = newValue
                self.drafts[bookID] = draft
            }
        )
    }

    func isRegistered(bookID: String) -> Bool {
        metadataStore.isRegistered(bookID: bookID)
    }

    // MARK: - 登録・解除

    /// 編集中の値をDBへ登録する(登録済みなら上書き)。
    func register(bookID: String) {
        guard let draft = drafts[bookID] else { return }
        metadataStore.upsert(
            bookID: bookID,
            author: draft.author,
            title: draft.title,
            series: draft.series,
            seriesIndex: draft.seriesIndex,
            // このウインドウからはファイルを開いていないため、セキュリティスコープ付き
            // ブックマークは作れない(作ろうとしてもアクセス権が無く失敗する)。
            // 既に他のストアが同じ本のブックマークを持っていれば、そちらから解決できる。
            sourceURL: nil
        )
        refreshDraft(forBookID: bookID)
    }

    /// 登録を解除し、表示をファイル名からの推測値へ戻す。
    func unregister(bookID: String) {
        metadataStore.delete(forBookID: bookID)
        refreshDraft(forBookID: bookID)
    }

    /// 1行ぶんの編集中の値を、現在のDB状態(登録済みならDBの値、未登録なら推測値)で作り直す。
    private func refreshDraft(forBookID bookID: String) {
        guard let row = allRows.first(where: { $0.bookID == bookID }) else { return }
        drafts[bookID] = makeInitialDraft(for: row)
        rebuildRows()
    }
}

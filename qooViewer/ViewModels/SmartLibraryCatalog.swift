import AppKit
import Combine
import Foundation
import QooMetaKit
import SwiftData

/// スマートライブラリに並べる本の一覧を集める役(アプリで 1 つ。AppStores)。2026-09-21。
///
/// 対象は**スマートライブラリに登録した対象フォルダ(`SmartLibraryStore.folders`)の中の本だけ**(2026-09-22、利用者の指示)。
/// 最初はライブラリの本とファイルブラウザの「よく使う項目」の中の本も混ぜていたが、ライブラリとファイルブラウザは環境設定で
/// 個別に OFF にできるので、その中身がここへ漏れ出さないように切り分けた。フォルダの中は `SmartLibraryScanner` で探す
/// (FileIO の上)。
///
/// **スマートライブラリは読むだけ**(2026-09-22、利用者の方針。docs/plans/metadata-generator-plan.md): 探した本の一覧を
/// 記録し(`MetadataCorpusStore` ―― メタデータ生成の母体)、並べるメタデータは DB の値(メタデータ生成が書いたもの)。行が
/// まだ無い本だけ、メタデータ生成の読みをつなぎに使う。以前はここでも qooMeta の索引を持って読み、DB へ書いていた
/// (メタデータの編集ウインドウと見比べる本の範囲が違い、読みが食い違った)。読書位置も集めた時点の値を持つ(並べ替え・絞り込みの
/// 間はディスクにも DB にも触れない)。
///
/// ■ 速さ(2026-09-22、利用者の要望。2,439 冊を実測: フォルダを探す 0.16 秒)
/// **前回の一覧を保存しておき、画面を出したらまずそれを出す**(`cacheURL`。起動直後は読み直しが終わるまで前回の中身が
/// 見え、終わったら差し替わる)。対象フォルダが変わっていれば使わない。
///
/// ■ 環境設定でスマートライブラリを OFF にしたとき(`setFeatureEnabled`。2026-09-22 の監査)
/// 画面が消えるので新しい集め直しは始まらないが、それだけでは足りなかった: 走っている最中の集め直し(フォルダの探索・
/// 保存)が最後まで走り、集めた一覧・探した結果がメモリに残り、保存した一覧の読み込みも後から
/// 一覧を出した。OFF にしたら**全部取り消して手放す**(世代を進め、await の後で世代を見る)。入り口(`activate`・
/// アプリ自身のファイル操作の知らせ)も OFF の間は何もしない。保存した一覧・対象フォルダ・スマートコレクション・記録した本の一覧
/// (メタデータ生成の母体。OFF の間もメタデータの対象は変わらない)は
/// 消さない(ON へ戻せば、画面を出したときに今までどおり集める)。止めないのは対象フォルダの付け替え
/// (`SmartLibraryStore.relocate` ―― 保存したパスを正しく保つ仕事)だけ。
///
/// ■ いつ集め直すか
/// 画面(スマートライブラリのペイン)が出ている間だけ(`activate` / `deactivate`)。出ている間は、メタデータ・対象フォルダ・
/// 規則が変わったら少し待ってから集め直す。フォルダの中を探すのは、対象フォルダが変わったとき・アプリ自身がその中の
/// ファイルを動かしたとき・利用者が「本を探し直す」を押したときだけ(ネットワークのボリュームでは遅いので、
/// メタデータが変わっただけで探し直さない)。
@MainActor
final class SmartLibraryCatalog: ObservableObject {
    @Published private(set) var books: [SmartBook] = []
    /// 集めている最中か。
    @Published private(set) var isLoading = false
    /// 一度でも集め終えたか。**まだ集めていない(空)と、集めたが 1 冊も無い(空)を画面が見分けるため**(2026-09-22、
    /// 利用者の指摘: 起動直後に「表示する本がありません」が一瞬出た。集め始める前のコマでは isLoading もまだ false だった)。
    @Published private(set) var hasLoaded = false
    /// フォルダを探すのを上限で打ち切ったか。
    @Published private(set) var isTruncated = false
    /// 中身が変わるたびに進む番号(画面の作り置きを作り直す鍵)。
    @Published private(set) var revision = 0

    private let metadataStore: BookMetadataStore
    private let store: SmartLibraryStore
    private let rulesStore: MetadataRulesStore
    private let modelContext: ModelContext
    /// 前回の一覧の保存先(型コメント「速さ」の 1)。nil なら保存しない(テスト)。
    private let cacheURL: URL?

    /// 探した本の一覧を記録する先(メタデータ生成の母体。nil ならしない ―― テスト)。
    private let corpusStore: MetadataCorpusStore?
    /// 行がまだ無い本の読みを借りる相手(メタデータ生成)。
    private weak var generator: MetadataGenerator?
    /// 保存した前回の一覧を読んでいる最中か(2 度読まない)。
    private var isRestoringCache = false
    /// 環境設定「スマートライブラリを有効にする」(型コメント)。
    private(set) var isFeatureEnabled = true

    /// 画面に出ている数(ウインドウごと)。0 なら何もしない。
    private var activeCount = 0
    /// そのうち、記録の残るウインドウ(シークレットウインドウでない)の数。0 の間は並べた本を DB へ登録しない
    /// (ビューアの登録が `skipsPersistence` で止まるのと同じ。2026-09-22 の 2 回目の監査の 8)。
    private var persistingCount = 0
    private var subscriptions: Set<AnyCancellable> = []
    private var pending: Task<Void, Never>?
    private var building: Task<Void, Never>?
    /// 最後にフォルダを探した結果(探す場所ごと)。探す場所が同じなら使い回す。
    private var scanned: (roots: [String], result: SmartLibraryScanner.Result)?
    private var generation = 0

    init(metadataStore: BookMetadataStore, store: SmartLibraryStore, rulesStore: MetadataRulesStore,
         modelContext: ModelContext, cacheURL: URL? = nil, corpusStore: MetadataCorpusStore? = nil,
         generator: MetadataGenerator? = nil) {
        self.corpusStore = corpusStore
        self.generator = generator
        self.metadataStore = metadataStore
        self.store = store
        self.rulesStore = rulesStore
        self.modelContext = modelContext
        self.cacheURL = cacheURL
        // ボリュームを付けた・外したら、前に探した結果は捨てる(2026-09-22 の監査。以前は捨てず、外付けが無いときに探した空の結果が
        // 付けた後も残った)。画面が出ていなくても捨てる。
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            // 知らせを出すスレッドは文書に無いので、メインで受ける(ほかの購読と同じ。assumeIsolated がメインの外でトラップしない
            // ように。2026-09-23 の 3 回目の監査の低)。
            workspace.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.handleVolumeChange() } }
                .store(in: &volumeSubscriptions)
        }
    }

    private var volumeSubscriptions: Set<AnyCancellable> = []

    private func handleVolumeChange() {
        guard isFeatureEnabled else { return }
        scanned = nil
        if activeCount > 0 { scheduleRebuild(rescan: true, delay: .milliseconds(400)) }
    }

    /// 既定の保存先(Application Support の中)。**Caches には置かない** ―― 空きが足りないと macOS が消し、その回は保存した
    /// 一覧が無いまま探すことになる(ネットワークの対象フォルダでは長く待たされる)。消えても次に集めれば作り直される写し。
    static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SmartLibrary", isDirectory: true)
            .appendingPathComponent("catalog.json")
    }

    /// 以前の保存先(Caches。2026-09-22 の 1 日だけ)。残っていれば消す。
    static func removeLegacyCache() {
        guard let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SmartLibrary", isDirectory: true) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 環境設定「スマートライブラリを有効にする」(型コメント「OFF にしたとき」)。
    func setFeatureEnabled(_ isEnabled: Bool) {
        guard isEnabled != isFeatureEnabled else { return }
        isFeatureEnabled = isEnabled
        guard !isEnabled else { return }
        generation += 1
        subscriptions.removeAll()
        pending?.cancel()
        pending = nil
        building?.cancel()
        building = nil
        scanned = nil
        lastSavedCache = nil
        books = []
        isTruncated = false
        isLoading = false
        hasLoaded = false
        revision += 1
    }

    // MARK: - 画面が出ている間だけ

    /// - Parameter persistsMetadata: 記録の残るウインドウか(シークレットウインドウなら false。`persistingCount`)。
    func activate(persistsMetadata: Bool = true) {
        guard isFeatureEnabled else { return }
        if persistsMetadata { persistingCount += 1 }
        activeCount += 1
        guard activeCount == 1 else { return }
        subscribe()
        // 集め直しは次のコマで始まるので、「集めている最中」はここで立てておく(その間を空の一覧として描かない)。
        isLoading = true
        restoreCacheIfNeeded()
        scheduleRebuild(rescan: false, delay: .zero)
    }

    func deactivate(persistsMetadata: Bool = true) {
        if persistsMetadata { persistingCount = max(0, persistingCount - 1) }
        activeCount = max(0, activeCount - 1)
        guard activeCount == 0 else { return }
        subscriptions.removeAll()
        pending?.cancel()
        pending = nil
        // 始まる前に取り消した集め直しは「最中」を下ろす人がいない。
        if building == nil { isLoading = false }
    }

    /// 「読み直す」(フォルダの中も探し直す)。
    func reload() {
        scanned = nil
        scheduleRebuild(rescan: true, delay: .zero)
    }

    /// アプリ自身がファイルを動かした(AppStores.handleFileSystemChange から)。探している場所の中なら探し直す。
    func handleFileSystemChange(_ change: FileSystemChange) {
        guard isFeatureEnabled, activeCount > 0 || scanned != nil else { return }
        let roots = scanRoots()
        let touched = change.affectedFolderPaths.contains { folder in
            roots.contains { MountTable.path(folder, isAtOrUnder: $0) }
        }
        guard touched else { return }
        scanned = nil
        if activeCount > 0 { scheduleRebuild(rescan: true, delay: .milliseconds(300)) }
    }

    private func subscribe() {
        let rebuild: (Bool) -> Void = { [weak self] rescan in
            self?.scheduleRebuild(rescan: rescan, delay: .milliseconds(400))
        }
        metadataStore.$revision.dropFirst().sink { _ in rebuild(false) }.store(in: &subscriptions)
        store.$folders.dropFirst().removeDuplicates().sink { _ in rebuild(true) }.store(in: &subscriptions)
        // メタデータ生成が読み終えた(行がまだ無い本の読みが変わる。値は DB へ書かれ、上の `revision` でも届く)。
        generator?.updates.sink { _ in rebuild(false) }.store(in: &subscriptions)
        // 読書位置は通知が無い。本を開くとホームのペインは消え(deactivate)、戻ると出る(activate)ので、そこで読み直される。
    }

    private func scheduleRebuild(rescan: Bool, delay: Duration) {
        guard isFeatureEnabled else { return }
        if rescan { scanned = nil }
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    // MARK: - 集める

    /// フォルダを探す起点(対象フォルダ)。
    private func scanRoots() -> [String] {
        store.folders.map(\.path)
    }

    /// 本を集め直す(メインで集められるもの → 画面の外でフォルダを探す → qooMeta で変わった本だけ読む → 入れ替える)。
    ///
    /// **1 本ずつ順に**: 前の集め直しは取り消したうえで終わりを待つ(索引と「最後に渡した本」をいつも揃えておくため。
    /// 取り消された `apply` は索引を呼ぶ前のまま残すので、待つのは一瞬)。
    private func rebuild() {
        generation += 1
        let generation = generation
        let previous = building
        previous?.cancel()
        isLoading = true
        let snapshot = gatherOnMain()
        let roots = scanRoots()
        let cachedScan = scanned.flatMap { $0.roots == roots ? $0.result : nil }
        building = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            // 1. フォルダの中の本(同じ場所なら前の結果を使う)。
            var scan = cachedScan ?? SmartLibraryScanner.Result()
            if cachedScan == nil, !roots.isEmpty {
                scan = await FileIO.perform { SmartLibraryScanner.scan(roots: roots) }
            }
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            // 2. 探した本の一覧を記録する(メタデータを作るのはメタデータ生成。記録の残るウインドウが出ている間だけ ――
            //    シークレットウインドウだけで出した本は記録しない。`persistingCount`)。
            if self.persistingCount > 0 {
                self.corpusStore?.recordSmartLibraryScan(roots: roots, bookIDs: scan.books.map(\.path),
                                                         isTruncated: scan.isTruncated)
            }
            // 3. 組み立てる(画面の外で)。メタデータは DB の値(メタデータ生成が書く)。行がまだ無い本はメタデータ生成の読み。
            let proposals = self.generatorProposals(scan: scan)
            let books = await Task.detached(priority: .userInitiated) {
                Self.assemble(snapshot: snapshot, scan: scan, proposals: proposals)
            }.value
            guard !Task.isCancelled, generation == self.generation else { return }
            self.scanned = (roots, scan)
            self.books = books
            self.isTruncated = scan.isTruncated
            self.isLoading = false
            self.hasLoaded = true
            self.revision += 1
            // 対象フォルダのボリュームが繋がっていない回は保存しない(2026-09-22 の監査。以前は空の一覧で上書きし、次の起動の
            // 先出しも失った)。判定は MountTable だけで、パスには触らない。
            let mounts = MountTable.current()
            if !roots.contains(where: { mounts.isOnAnUnmountedVolume(URL(fileURLWithPath: $0)) }) {
                self.saveCache(roots: roots, books: books, isTruncated: scan.isTruncated)
            }
            self.building = nil
        }
    }

    /// メタデータ生成の読み(行がまだ無い本の値のつなぎと、型に合ったかの印。`assemble`)。
    private func generatorProposals(scan: SmartLibraryScanner.Result) -> [String: BookProposal] {
        guard let generator else { return [:] }
        var result: [String: BookProposal] = [:]
        for book in scan.books {
            if let proposal = generator.proposal(for: book.path) { result[book.path] = proposal }
        }
        return result
    }

    // MARK: - 前回の一覧(型コメント「速さ」の 1)

    nonisolated struct CachedCatalog: Codable, Sendable {
        var version = CachedCatalog.currentVersion
        var roots: [String]
        var books: [SmartBook]
        var isTruncated: Bool

        /// 形を変えたら上げる(古い形は読まずに捨てる)。2: 表紙の鍵を足した。
        static let currentVersion = 2
    }

    /// まだ何も並んでいなければ、保存した前回の一覧を読んで先に出す。対象フォルダが変わっていれば使わない。
    /// 本当の集め直しが先に終わっていたら何もしない。
    private func restoreCacheIfNeeded() {
        guard let cacheURL, isFeatureEnabled, !hasLoaded, books.isEmpty, !isRestoringCache else { return }
        isRestoringCache = true
        let roots = scanRoots()
        let generation = generation
        Task { [weak self] in
            let cached = await Task.detached(priority: .userInitiated) { () -> CachedCatalog? in
                guard let data = try? Data(contentsOf: cacheURL),
                      let cached = try? JSONDecoder().decode(CachedCatalog.self, from: data),
                      cached.version == CachedCatalog.currentVersion, cached.roots == roots
                else { return nil }
                return cached
            }.value
            guard let self else { return }
            self.isRestoringCache = false
            guard let cached, self.isFeatureEnabled, generation == self.generation, !self.hasLoaded, self.books.isEmpty
            else { return }
            self.books = cached.books
            self.isTruncated = cached.isTruncated
            self.revision += 1
        }
    }

    /// 最後に保存した一覧(同じなら書き直さない)。`books` と同じ配列を指すので、持っていても写しは増えない。
    private var lastSavedCache: CachedCatalog?

    /// 集め終えた一覧を保存する(画面の外で。対象フォルダが無ければ消す)。
    ///
    /// **中身が前に保存したものと同じなら書かない**(2026-09-22 の監査)。集め直しは、メタデータの編集中なら 400 ms 待つごとに
    /// 走り、そのたびに全冊ぶんの JSON(数千冊で数 MB)を書き直していた。
    private func saveCache(roots: [String], books: [SmartBook], isTruncated: Bool) {
        guard let cacheURL else { return }
        let cached = CachedCatalog(roots: roots, books: books, isTruncated: isTruncated)
        if let lastSavedCache, lastSavedCache.roots == roots, lastSavedCache.isTruncated == isTruncated,
           lastSavedCache.books == books { return }
        lastSavedCache = cached
        Task.detached(priority: .utility) {
            if roots.isEmpty {
                try? FileManager.default.removeItem(at: cacheURL)
                return
            }
            guard let data = try? JSONEncoder().encode(cached) else { return }
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    /// メインで集める値(SwiftData の行とストアの中身)。画面の外へ渡せる値にしておく。
    nonisolated struct Snapshot: Sendable {
        struct Reading: Sendable {
            let updatedAt: Date
            let progress: Double?
            var isAtLastPage = false
        }
        /// DB のメタデータの行。
        var records: [String: BookMetadataRecord] = [:]
        var readings: [String: Reading] = [:]
    }

    private func gatherOnMain() -> Snapshot {
        var snapshot = Snapshot()
        snapshot.records = metadataStore.allRecords()
        let states = (try? modelContext.fetch(FetchDescriptor<BookReadingState>())) ?? []
        for state in states {
            let progress = state.recordedPageCount.flatMap { count -> Double? in
                count > 0 ? min(1, Double(state.lastPageIndex + 1) / Double(count)) : nil
            }
            if let existing = snapshot.readings[state.bookID], existing.updatedAt >= state.updatedAt { continue }
            snapshot.readings[state.bookID] = .init(updatedAt: state.updatedAt, progress: progress,
                                                    isAtLastPage: state.isAtLastPage)
        }
        return snapshot
    }

    /// 集めた値と qooMeta の提案から本の一覧を作る(画面の外で)。
    nonisolated static func assemble(snapshot: Snapshot, scan: SmartLibraryScanner.Result,
                                     proposals: [String: BookProposal]) -> [SmartBook] {
        var byID: [String: SmartBook] = [:]
        for scanned in scan.books where byID[scanned.path] == nil {
            let name = (scanned.path as NSString).lastPathComponent
            var current = SmartBook(id: scanned.path, fileName: name,
                                    kind: SmartBookKind(fileName: name, isFolder: scanned.isFolder),
                                    metadata: BookMetadataValues(), isRegistered: false)
            current.creationDate = scanned.creationDate
            current.modificationDate = scanned.modificationDate
            current.fileSize = scanned.fileSize
            current.dateAdded = scanned.addedDate ?? scanned.creationDate
            current.thumbnailKey = scanned.thumbnailKey
            byID[scanned.path] = current
        }
        let ids = byID.keys.sorted()
        var result: [SmartBook] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            guard var current = byID[id] else { continue }
            // メタデータ: 行のある本は DB の値(メタデータ生成が書いたもの。ロックした本は利用者が確定したもの)。行がまだ無い本は
            // メタデータ生成の読み(行ができるまでのつなぎ)。スマートライブラリは読むだけで、DB へは書かない(2026-09-22)。
            if let record = snapshot.records[id] {
                current.metadata = record.values
                current.isRegistered = record.isLocked
            }
            if let proposal = proposals[id] {
                if snapshot.records[id] == nil { current.metadata = BookMetadataValues(proposal.metadata) }
                current.matchedFormat = proposal.reading.formatIndex != nil
            }
            if let reading = snapshot.readings[id] {
                current.lastRead = reading.updatedAt
                current.progress = reading.progress
                current.isAtLastPage = reading.isAtLastPage
            }
            result.append(current)
        }
        return result
    }

    /// 索引を使わずに全冊を読んで組み立てる(テストの口。結果は `rebuild` と同じ)。
    nonisolated static func assemble(snapshot: Snapshot, scan: SmartLibraryScanner.Result, rules: CompiledRules) -> [SmartBook] {
        let inputs = MetadataGenerator.inputs(for: scan.books.map(\.path), records: snapshot.records, reusing: [:], rules: rules)
        let set = proposeSync(inputs.ordered, rules: rules, dictionaries: MetadataRulesStore.dictionaries)
        let proposals = Dictionary(set.proposals.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        return assemble(snapshot: snapshot, scan: scan, proposals: proposals)
    }
}

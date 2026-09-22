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
/// 本ごとのメタデータは、登録済みなら DB の値、未登録なら **qooMeta の提案**(全冊をまとめて読むので、番号の無いシリーズも
/// 同じ書き手の本と見比べて見つかる。メタデータの編集ウインドウと同じ規則・同じルールセットの選び方)。読書位置も
/// 集めた時点の値を持つ(並べ替え・絞り込みの間はディスクにも DB にも触れない)。
///
/// 対象フォルダの本は、メタデータの編集ウインドウの対象にもなる(`folderBookIDs()`。2026-09-22、利用者の指示)。
///
/// ■ 速さ(2026-09-22、利用者の要望。2,439 冊を実測: フォルダを探す 0.16 秒、qooMeta で読む 1.3 秒)
/// 1. **前回の一覧を保存しておき、画面を出したらまずそれを出す**(`cacheURL`。起動直後は読み直しが終わるまで前回の中身が
///    見え、終わったら差し替わる)。対象フォルダが変わっていれば使わない。
/// 2. **qooMeta の読みは変わった本だけ**(`ProposalIndex` を持ち続ける。メタデータの編集ウインドウと同じ)。最初の 1 回は
///    `load` で並列に読み、以後は足した・消した・登録を変えた本だけを `apply` で渡す。規則が変わったら索引ごと作り直す。
///    ルールセットの自動の選択(`autoPreset`)も、規則が同じ間は本ごとに前の結果を使う。
///
/// ■ 環境設定でスマートライブラリを OFF にしたとき(`setFeatureEnabled`。2026-09-22 の監査)
/// 画面が消えるので新しい集め直しは始まらないが、それだけでは足りなかった: 走っている最中の集め直し(フォルダの探索・
/// qooMeta・保存)が最後まで走り、集めた一覧・qooMeta の索引・探した結果がメモリに残り、保存した一覧の読み込みも後から
/// 一覧を出した。OFF にしたら**全部取り消して手放す**(世代を進め、await の後で世代を見る)。入り口(`activate`・
/// `folderBookIDs`・アプリ自身のファイル操作の知らせ)も OFF の間は何もしない。保存した一覧・対象フォルダ・スマートコレクションは
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

    /// qooMeta の索引と、それに最後に渡した本(型コメント「速さ」の 2)。集め直しは 1 本ずつ順に走らせる
    /// (`rebuild` が前の集め直しの終わりを待つ)ので、ここを触るのはいつも 1 つだけ。
    private var index: ProposalIndex?
    private var indexRulesHash: String?
    private var indexedInputs: [String: BookInput] = [:]
    private var proposalsByID: [String: BookProposal] = [:]
    /// 保存した前回の一覧を読んでいる最中か(2 度読まない)。
    private var isRestoringCache = false
    /// 環境設定「スマートライブラリを有効にする」(型コメント)。
    private(set) var isFeatureEnabled = true

    /// 画面に出ている数(ウインドウごと)。0 なら何もしない。
    private var activeCount = 0
    /// そのうち、記録の残るウインドウ(シークレットウインドウでない)の数。0 の間は並べた本を DB へ登録しない
    /// (ビューアの登録が `skipsPersistence` で止まるのと同じ。2026-09-22 の 2 回目の監査の 8)。
    private var persistingCount = 0
    /// この起動の間に登録した値(本ごと)。同じ値はもう書かない(`registerParsed`)。
    private var lastRegistered: [String: BookMetadataValues] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var pending: Task<Void, Never>?
    private var building: Task<Void, Never>?
    /// 最後にフォルダを探した結果(探す場所ごと)。探す場所が同じなら使い回す。
    private var scanned: (roots: [String], result: SmartLibraryScanner.Result)?
    private var generation = 0

    init(metadataStore: BookMetadataStore, store: SmartLibraryStore, rulesStore: MetadataRulesStore,
         modelContext: ModelContext, cacheURL: URL? = nil) {
        self.metadataStore = metadataStore
        self.store = store
        self.rulesStore = rulesStore
        self.modelContext = modelContext
        self.cacheURL = cacheURL
        // ボリュームを付けた・外したら、前に探した結果は捨てる(2026-09-22 の監査。以前は捨てず、外付けが無いときに探した空の結果が
        // 付けた後も残った ―― メタデータの編集ウインドウの `folderBookIDs()` も同じ)。画面が出ていなくても捨てる。
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspace.publisher(for: name)
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

    /// 対象フォルダの中の本(bookID)。メタデータの編集ウインドウの母体に足す。前に探した結果があればそれを使い、
    /// 無ければ探す(画面が出ていなくても)。
    func folderBookIDs() async -> [String] {
        guard isFeatureEnabled else { return [] }
        let roots = scanRoots()
        guard !roots.isEmpty else { return [] }
        if let scanned, scanned.roots == roots { return scanned.result.books.map(\.path) }
        let generation = generation
        let result = await FileIO.perform { SmartLibraryScanner.scan(roots: roots) }
        // 探している間に対象フォルダが変わっていなければ、結果を覚えておく(画面を開いたときに探し直さない)。
        // 探している間に OFF にされていたら覚えない(手放したものを戻さない)。
        guard isFeatureEnabled, generation == self.generation else { return [] }
        if scanRoots() == roots { scanned = (roots, result) }
        return result.books.map(\.path)
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
        index = nil
        indexRulesHash = nil
        indexedInputs = [:]
        proposalsByID = [:]
        lastRegistered = [:]
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
        // 自分の規則のストアの知らせだけ(テストでは別のストアが同じ名前で次々に知らせ、そのたびに集め直しが先へ延びた)。
        NotificationCenter.default.publisher(for: MetadataRulesStore.rulesDidChange, object: rulesStore)
            .sink { _ in rebuild(false) }.store(in: &subscriptions)
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
        let rules = rulesStore.rules
        building = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            // 1. フォルダの中の本(同じ場所なら前の結果を使う)。
            var scan = cachedScan ?? SmartLibraryScanner.Result()
            if cachedScan == nil, !roots.isEmpty {
                scan = await FileIO.perform { SmartLibraryScanner.scan(roots: roots) }
            }
            guard let self, !Task.isCancelled else { return }
            // 2. qooMeta へ渡す本(規則が同じなら、前に渡した本の名前とルールセットを使い回す)。
            let sameRules = self.indexRulesHash == rules.contentHash
            let previousInputs = sameRules ? self.indexedInputs : [:]
            let paths = scan.books.map(\.path)
            let inputs = await Task.detached(priority: .userInitiated) {
                Self.inputs(for: paths, records: snapshot.records, reusing: previousInputs, rules: rules)
            }.value
            guard !Task.isCancelled, generation == self.generation else { return }
            // 3. 変わった本だけ読む(索引が無い・規則が変わったら作り直して並列に読む)。
            var proposals = sameRules ? self.proposalsByID : [:]
            var newIndex: ProposalIndex?
            do {
                if let index = self.index, sameRules {
                    let changes = Self.changes(from: previousInputs, to: inputs)
                    if !changes.isEmpty {
                        let delta = try await index.apply(changes)
                        for proposal in delta.changed { proposals[proposal.id] = proposal }
                        for id in delta.removedBooks { proposals[id] = nil }
                    }
                } else {
                    let index = ProposalIndex(rules: rules, dictionaries: MetadataRulesStore.dictionaries)
                    try await index.load(inputs.ordered)
                    proposals = Dictionary(await index.snapshot().proposals.map { ($0.id, $0) },
                                           uniquingKeysWith: { _, b in b })
                    newIndex = index
                }
            } catch {
                return // 取り消された(索引は呼ぶ前のまま)。
            }
            // 索引は渡した変更を当て終えている(取り消されたら上で抜けている ―― 全か無か)。**控えは世代に関わらず揃える**
            // (2026-09-22 の監査で指摘): 以前はここで世代を見てから書き戻していたので、当て終えた直後に新しい集め直しが
            // 始まると、索引だけ進んで「最後に渡した本」が古いまま残り、次の集め直しはその差を「変わっていない」と見て
            // 渡さなかった(その本の提案が、規則が変わるまで古いまま出た)。次の集め直しはこの Task の終わりを待ってから
            // 控えを読むので、ここで書けば必ず間に合う。OFF にされていたら手放したまま(書き戻さない)。
            guard self.isFeatureEnabled else { return }
            if let newIndex { self.index = newIndex }
            self.indexedInputs = inputs.byID
            self.indexRulesHash = rules.contentHash
            self.proposalsByID = proposals
            // 一覧を出すのは、いちばん新しい集め直しだけ。
            guard !Task.isCancelled, generation == self.generation else { return }
            // 4. 組み立てる(画面の外で)。
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
            // 登録は区切って書くので時間がかかる。その間も `building` に残しておき、次の集め直し・OFF(`setFeatureEnabled`)が
            // 取り消せるようにする(取り消されたら残りは次の集め直しが書く)。
            await self.registerParsed(books, snapshot: snapshot)
            if generation == self.generation { self.building = nil }
        }
    }

    /// 並べた本を DB に登録する(利用者の指示 2026-09-22: 解析した本はすべて登録する)。行の無い本はロックせずに作り、
    /// ロックしていない行は今の読みに揃える。**ロックした行・除外フォルダの本には書かない**。
    /// 書くと `metadataStore.revision` が進んで集め直しがもう 1 度走るが、そのときは揃っているので何も書かない。
    /// 数千冊を初めて並べたときは多いので、区切って書く(`BookMetadataStore.upsertAllInBatches`)。
    ///
    /// ■ この起動の間に書いた値は、もう書かない(2026-09-22 の 2 回目の監査の 4・5)
    /// 「揃っているので何も書かない」は、書いた値が DB を往復して同じに戻ることが前提だった。著者名の中の改行(著者は改行で
    /// つないで保存する)のように往復で変わる値が 1 冊でもあると、書く → 集め直し → また違う、が止まらない。また、メタデータの
    /// 編集ウインドウで「メタデータを削除」した本は、その削除の知らせで走った集め直しが 0.5 秒で行を作り直していた(一覧からは
    /// 消えたまま)。同じ本に同じ値を書くのは、この起動の間は 1 度だけにする(値が変われば ―― 規則を変えた・名前を変えた ――
    /// また書く)。消した本は、アプリを起動し直す・メタデータの編集ウインドウを開き直すと、また登録される(利用者の指示どおり
    /// 覚えてはおかない)。
    private func registerParsed(_ books: [SmartBook], snapshot: Snapshot) async {
        guard isFeatureEnabled, persistingCount > 0 else { return }
        var written: [String: BookMetadataValues] = [:]
        let entries = books.compactMap { book -> BookMetadataStore.BatchEntry? in
            let record = snapshot.records[book.id]
            let values = book.metadata.trimmed
            // この起動中に利用者が消した行は作り直さない(BookMetadataStore.deletedThisSession)。
            guard record?.isLocked != true, record?.values != values, lastRegistered[book.id] != values,
                  !values.isEmpty, !rulesStore.isExcluded(bookID: book.id),
                  record != nil || !metadataStore.deletedThisSession.contains(book.id) else { return nil }
            written[book.id] = values
            return BookMetadataStore.BatchEntry(bookID: book.id, values: book.metadata, onlyIfUnlocked: true)
        }
        guard !entries.isEmpty else { return }
        // 控えは書き終えた区切りのぶんだけ(取り消されて書けなかった本は、次の集め直しで書く)。
        await metadataStore.upsertAllInBatches(entries) { [weak self] batch in
            for entry in batch { if let values = written[entry.bookID] { self?.lastRegistered[entry.bookID] = values } }
        }
    }

    // MARK: - qooMeta へ渡す本

    /// 渡す本の一覧(入れる順 = パスの順)と、id からの引き。
    nonisolated struct Inputs: Sendable {
        var ordered: [BookInput] = []
        var byID: [String: BookInput] = [:]
    }

    /// 本ごとの入力。ロックした本は DB の値をすべて確定した内容として渡し(錨として、ほかの本のシリーズも決める)、
    /// ロックしていない本は直した欄とルールセットを渡す(`BookMetadataRecord.confirmation`)。
    /// 名前とルールセットの自動の選択は、`reusing` に同じ本があればそれを使う(規則が同じ間だけ渡される)。
    /// (利用者が選んだルールセットを自動に戻した本は、使い回すと前のルールセットのまま ―― 規則が変わるまで。まれなので許す。)
    nonisolated static func inputs(for paths: [String], records: [String: BookMetadataRecord],
                                   reusing previous: [String: BookInput], rules: CompiledRules) -> Inputs {
        let ids = Set(paths).sorted()
        // 新しい本の名前とルールセットの自動の選択は並列に(2,439 冊を順に選ぶと 0.7 秒かかった。どちらも本ごとに独立した計算)。
        let fresh = ids.filter { previous[$0] == nil }
        var readings = [(name: String, preset: String?)](repeating: ("", nil), count: fresh.count)
        let autoRules = MetadataRulesStore.autoPresetRules(of: rules)
        readings.withUnsafeMutableBufferPointer { buffer in
            // 各反復は自分の添字にだけ書く(重ならない)ので、同時に書いても安全。
            nonisolated(unsafe) let buffer = buffer
            DispatchQueue.concurrentPerform(iterations: fresh.count) { i in
                let name = MetadataRulesStore.parsingName(forBookID: fresh[i])
                buffer[i] = (name, MetadataRulesStore.autoPreset(forBookID: fresh[i], name: name, autoRules: autoRules))
            }
        }
        let freshByID = Dictionary(uniqueKeysWithValues: zip(fresh, readings))
        var result = Inputs()
        for id in ids {
            let record = records[id]
            let confirmation = record?.confirmation ?? .none
            let input: BookInput
            if let old = previous[id] {
                input = BookInput(id: id, name: old.name, preset: record?.ruleSet ?? old.preset, confirmation: confirmation)
            } else {
                let reading = freshByID[id] ?? (MetadataRulesStore.parsingName(forBookID: id), nil)
                input = BookInput(id: id, name: reading.name, preset: record?.ruleSet ?? reading.preset,
                                  confirmation: confirmation)
            }
            result.ordered.append(input)
            result.byID[id] = input
        }
        return result
    }

    /// 前に渡した本と今の本の差(足した・変わった本は upsert、無くなった本は remove)。
    nonisolated static func changes(from previous: [String: BookInput], to current: Inputs) -> [BookChange] {
        var changes: [BookChange] = []
        for input in current.ordered where previous[input.id] != input { changes.append(.upsert(input)) }
        for id in previous.keys.sorted() where current.byID[id] == nil { changes.append(.remove(id: id)) }
        return changes
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
            // メタデータ: ロックした本は DB の値、ほかは qooMeta の提案(直した欄を重ねたもの。DB へもこの値を書く)。
            if let record = snapshot.records[id], record.isLocked {
                current.metadata = record.values
                current.isRegistered = true
            } else if let proposal = proposals[id] {
                current.metadata = BookMetadataValues(proposal.metadata)
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
        let inputs = inputs(for: scan.books.map(\.path), records: snapshot.records, reusing: [:], rules: rules)
        let set = proposeSync(inputs.ordered, rules: rules, dictionaries: MetadataRulesStore.dictionaries)
        let proposals = Dictionary(set.proposals.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        return assemble(snapshot: snapshot, scan: scan, proposals: proposals)
    }
}

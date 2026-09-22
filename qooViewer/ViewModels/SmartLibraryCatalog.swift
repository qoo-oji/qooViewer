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
    /// フォルダを探すのを上限で打ち切ったか。
    @Published private(set) var isTruncated = false
    /// 中身が変わるたびに進む番号(画面の作り置きを作り直す鍵)。
    @Published private(set) var revision = 0

    private let metadataStore: BookMetadataStore
    private let store: SmartLibraryStore
    private let rulesStore: MetadataRulesStore
    private let modelContext: ModelContext

    /// 画面に出ている数(ウインドウごと)。0 なら何もしない。
    private var activeCount = 0
    private var subscriptions: Set<AnyCancellable> = []
    private var pending: Task<Void, Never>?
    private var building: Task<Void, Never>?
    /// 最後にフォルダを探した結果(探す場所ごと)。探す場所が同じなら使い回す。
    private var scanned: (roots: [String], result: SmartLibraryScanner.Result)?
    private var generation = 0

    init(metadataStore: BookMetadataStore, store: SmartLibraryStore, rulesStore: MetadataRulesStore,
         modelContext: ModelContext) {
        self.metadataStore = metadataStore
        self.store = store
        self.rulesStore = rulesStore
        self.modelContext = modelContext
    }

    /// 対象フォルダの中の本(bookID)。メタデータの編集ウインドウの母体に足す。前に探した結果があればそれを使い、
    /// 無ければ探す(画面が出ていなくても)。
    func folderBookIDs() async -> [String] {
        let roots = scanRoots()
        guard !roots.isEmpty else { return [] }
        if let scanned, scanned.roots == roots { return scanned.result.books.map(\.path) }
        let result = await FileIO.perform { SmartLibraryScanner.scan(roots: roots) }
        // 探している間に対象フォルダが変わっていなければ、結果を覚えておく(画面を開いたときに探し直さない)。
        if scanRoots() == roots { scanned = (roots, result) }
        return result.books.map(\.path)
    }

    // MARK: - 画面が出ている間だけ

    func activate() {
        activeCount += 1
        guard activeCount == 1 else { return }
        subscribe()
        scheduleRebuild(rescan: false, delay: .zero)
    }

    func deactivate() {
        activeCount = max(0, activeCount - 1)
        guard activeCount == 0 else { return }
        subscriptions.removeAll()
        pending?.cancel()
        pending = nil
    }

    /// 「読み直す」(フォルダの中も探し直す)。
    func reload() {
        scanned = nil
        scheduleRebuild(rescan: true, delay: .zero)
    }

    /// アプリ自身がファイルを動かした(AppStores.handleFileSystemChange から)。探している場所の中なら探し直す。
    func handleFileSystemChange(_ change: FileSystemChange) {
        guard activeCount > 0 || scanned != nil else { return }
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
        NotificationCenter.default.publisher(for: MetadataRulesStore.rulesDidChange)
            .sink { _ in rebuild(false) }.store(in: &subscriptions)
        // 読書位置は通知が無い。本を開くとホームのペインは消え(deactivate)、戻ると出る(activate)ので、そこで読み直される。
    }

    private func scheduleRebuild(rescan: Bool, delay: Duration) {
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

    /// 本を集め直す(メインで集められるもの → 画面の外でフォルダを探す → qooMeta で読む → 入れ替える)。
    private func rebuild() {
        generation += 1
        let generation = generation
        building?.cancel()
        isLoading = true
        let snapshot = gatherOnMain()
        let roots = scanRoots()
        let cachedScan = scanned.flatMap { $0.roots == roots ? $0.result : nil }
        let rules = rulesStore.rules
        building = Task { [weak self] in
            // 1. フォルダの中の本(同じ場所なら前の結果を使う)。
            var scan = cachedScan ?? SmartLibraryScanner.Result()
            if cachedScan == nil, !roots.isEmpty {
                scan = await FileIO.perform { SmartLibraryScanner.scan(roots: roots) }
            }
            guard !Task.isCancelled else { return }
            // 2. 組み立てて、未登録の本を qooMeta で読む(画面の外で)。
            let books = await Task.detached(priority: .userInitiated) {
                Self.assemble(snapshot: snapshot, scan: scan, rules: rules)
            }.value
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.scanned = (roots, scan)
            self.books = books
            self.isTruncated = scan.isTruncated
            self.isLoading = false
            self.revision += 1
        }
    }

    /// メインで集める値(SwiftData の行とストアの中身)。画面の外へ渡せる値にしておく。
    nonisolated struct Snapshot: Sendable {
        struct Reading: Sendable {
            let updatedAt: Date
            let progress: Double?
            var isAtLastPage = false
        }
        var registered: [String: BookMetadataValues] = [:]
        var readings: [String: Reading] = [:]
    }

    private func gatherOnMain() -> Snapshot {
        var snapshot = Snapshot()
        for metadata in metadataStore.allMetadata() { snapshot.registered[metadata.bookID] = metadata.values }
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

    /// 集めた値から本の一覧を作る(画面の外で。qooMeta の読み取りもここ)。
    nonisolated static func assemble(snapshot: Snapshot, scan: SmartLibraryScanner.Result, rules: CompiledRules) -> [SmartBook] {
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
            byID[scanned.path] = current
        }

        // メタデータ: 登録済みは DB の値(すべて確定した内容として渡すので、錨として未登録の本のシリーズも決める)、
        // 未登録は qooMeta の提案。
        let ids = byID.keys.sorted()
        var inputs: [BookInput] = []
        inputs.reserveCapacity(ids.count)
        for id in ids {
            let name = MetadataRulesStore.parsingName(forBookID: id)
            inputs.append(BookInput(id: id, name: name,
                                    preset: MetadataRulesStore.autoPreset(forBookID: id, name: name, rules: rules),
                                    confirmation: snapshot.registered[id]?.confirmation ?? .none))
        }
        let proposals = proposeSync(inputs, rules: rules, dictionaries: MetadataRulesStore.dictionaries)
        var result: [SmartBook] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            guard var current = byID[id] else { continue }
            if let values = snapshot.registered[id] {
                current.metadata = values
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
}

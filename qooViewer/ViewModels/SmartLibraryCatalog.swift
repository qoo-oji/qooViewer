import Combine
import Foundation
import QooMetaKit
import SwiftData

/// スマートライブラリに並べる本の一覧を集める役(アプリで 1 つ。AppStores)。2026-09-21。
///
/// 対象(利用者の指示 2026-09-21)は 3 つの和:
/// 1. **ライブラリに登録されている本**(コレクションの行。同じ本が複数のコレクションにあっても 1 冊)
/// 2. **ファイルブラウザの「よく使う項目」のフォルダに含まれる本**
/// 3. **スマートライブラリに登録した対象フォルダに含まれる本**
/// どれを含めるかは `SmartLibraryStore.sources` で選べる。2 と 3 は `SmartLibraryScanner` でフォルダの中を探す(FileIO の上)。
///
/// 本ごとのメタデータは、登録済みなら DB の値、未登録なら **qooMeta の提案**(全冊をまとめて読むので、番号の無いシリーズも
/// 同じ書き手の本と見比べて見つかる。メタデータの編集ウインドウと同じ規則・同じルールセットの選び方)。読書位置・お気に入りも
/// 集めた時点の値を持つ(並べ替え・絞り込みの間はディスクにも DB にも触れない)。
///
/// ■ いつ集め直すか
/// 画面(スマートライブラリのペイン)が出ている間だけ(`activate` / `deactivate`)。出ている間は、ライブラリ・メタデータ・
/// よく使う項目・対象フォルダ・規則が変わったら少し待ってから集め直す。フォルダの中を探すのは、探す場所が変わったとき・
/// アプリ自身がその中のファイルを動かしたとき・利用者が「読み直す」を押したときだけ(ネットワークのボリュームでは遅いので、
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

    private let collectionStore: CollectionStore
    private let metadataStore: BookMetadataStore
    private let favoritesStore: FavoritesStore
    private let favoriteLocations: FavoriteLocationStore
    private let store: SmartLibraryStore
    private let rulesStore: MetadataRulesStore
    private let preferences: AppPreferences
    private let modelContext: ModelContext

    /// 画面に出ている数(ウインドウごと)。0 なら何もしない。
    private var activeCount = 0
    private var subscriptions: Set<AnyCancellable> = []
    private var pending: Task<Void, Never>?
    private var building: Task<Void, Never>?
    /// 最後にフォルダを探した結果(探す場所ごと)。探す場所が同じなら使い回す。
    private var scanned: (roots: [String], result: SmartLibraryScanner.Result)?
    private var generation = 0

    init(collectionStore: CollectionStore, metadataStore: BookMetadataStore, favoritesStore: FavoritesStore,
         favoriteLocations: FavoriteLocationStore, store: SmartLibraryStore, rulesStore: MetadataRulesStore,
         preferences: AppPreferences, modelContext: ModelContext) {
        self.collectionStore = collectionStore
        self.metadataStore = metadataStore
        self.favoritesStore = favoritesStore
        self.favoriteLocations = favoriteLocations
        self.store = store
        self.rulesStore = rulesStore
        self.preferences = preferences
        self.modelContext = modelContext
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
        collectionStore.$revision.dropFirst().sink { _ in rebuild(false) }.store(in: &subscriptions)
        metadataStore.$revision.dropFirst().sink { _ in rebuild(false) }.store(in: &subscriptions)
        favoriteLocations.$items.dropFirst().removeDuplicates().sink { _ in rebuild(true) }.store(in: &subscriptions)
        store.$folders.dropFirst().removeDuplicates().sink { _ in rebuild(true) }.store(in: &subscriptions)
        store.$sources.dropFirst().removeDuplicates().sink { _ in rebuild(true) }.store(in: &subscriptions)
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

    /// フォルダを探す起点(よく使う項目と対象フォルダ。含めない設定のものは除く)。
    private func scanRoots() -> [String] {
        var roots: [String] = []
        if store.sources.favoriteLocations, preferences.fileBrowserFeatureEnabled {
            roots += favoriteLocations.items.map(\.path)
        }
        if store.sources.folders { roots += store.folders.map(\.path) }
        return roots
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
        struct LibraryBook: Sendable {
            let bookID: String
            let itemID: UUID
            let addedAt: Date
            let libraryName: String?
            let collectionName: String?
            let created: Date?
            let modified: Date?
        }
        struct Reading: Sendable {
            let updatedAt: Date
            let progress: Double?
        }
        var includesLibrary = true
        var libraryBooks: [LibraryBook] = []
        var registered: [String: BookMetadataValues] = [:]
        var readings: [String: Reading] = [:]
        var favorites: Set<String> = []
    }

    private func gatherOnMain() -> Snapshot {
        var snapshot = Snapshot()
        snapshot.includesLibrary = store.sources.library && preferences.libraryFeatureEnabled
        if snapshot.includesLibrary {
            let locale = preferences.effectiveLocale
            for item in collectionStore.allItems() {
                let dates = collectionStore.fileDatesByItemID[item.id]
                snapshot.libraryBooks.append(.init(
                    bookID: item.bookID, itemID: item.id, addedAt: item.addedAt,
                    libraryName: item.collection?.library?.displayName(language: locale),
                    collectionName: item.collection?.name, created: dates?.created, modified: dates?.modified))
            }
        }
        for metadata in metadataStore.allMetadata() { snapshot.registered[metadata.bookID] = metadata.values }
        let states = (try? modelContext.fetch(FetchDescriptor<BookReadingState>())) ?? []
        for state in states {
            let progress = state.recordedPageCount.flatMap { count -> Double? in
                count > 0 ? min(1, Double(state.lastPageIndex + 1) / Double(count)) : nil
            }
            if let existing = snapshot.readings[state.bookID], existing.updatedAt >= state.updatedAt { continue }
            snapshot.readings[state.bookID] = .init(updatedAt: state.updatedAt, progress: progress)
        }
        snapshot.favorites = favoritesStore.allRegisteredBookIDs()
        return snapshot
    }

    /// 集めた値から本の一覧を作る(画面の外で。qooMeta の読み取りもここ)。
    nonisolated static func assemble(snapshot: Snapshot, scan: SmartLibraryScanner.Result, rules: CompiledRules) -> [SmartBook] {
        var byID: [String: SmartBook] = [:]
        func book(for path: String, isFolder: Bool) -> SmartBook {
            let name = (path as NSString).lastPathComponent
            return SmartBook(id: path, fileName: name, kind: SmartBookKind(fileName: name, isFolder: isFolder),
                             sources: [], metadata: BookMetadataValues(), isRegistered: false)
        }
        for entry in snapshot.libraryBooks {
            let name = (entry.bookID as NSString).lastPathComponent
            let isFolder = !(isArchiveFile(name) || isPDFFile(name) || isEpubFile(name))
            var current = byID[entry.bookID] ?? book(for: entry.bookID, isFolder: isFolder)
            current.sources.insert(.library)
            if let name = entry.libraryName, !current.libraryNames.contains(name) { current.libraryNames.append(name) }
            if let name = entry.collectionName, !current.collectionNames.contains(name) { current.collectionNames.append(name) }
            // 表紙と追加日は、最初に入れたコレクションのもの。
            if current.dateAdded.map({ entry.addedAt < $0 }) ?? true {
                current.dateAdded = entry.addedAt
                current.collectionItemID = entry.itemID
            }
            current.creationDate = current.creationDate ?? entry.created
            current.modificationDate = current.modificationDate ?? entry.modified
            byID[entry.bookID] = current
        }
        for scanned in scan.books {
            var current = byID[scanned.path] ?? book(for: scanned.path, isFolder: scanned.isFolder)
            current.sources.insert(.folders)
            current.creationDate = current.creationDate ?? scanned.creationDate
            current.modificationDate = scanned.modificationDate ?? current.modificationDate
            current.fileSize = current.fileSize ?? scanned.fileSize
            if current.dateAdded == nil { current.dateAdded = scanned.creationDate }
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
            }
            current.isFavorite = snapshot.favorites.contains(id)
            result.append(current)
        }
        return result
    }
}

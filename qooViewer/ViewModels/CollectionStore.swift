import Foundation
import SwiftData
import AppKit
import Combine

/// ライブラリ(BookLibrary)・コレクション(BookCollection)・その中の本(CollectionItem)の
/// 永続化と操作をまとめて担当する(改善要望5)。FavoritesStoreと同じ作り・同じ約束事で書いてある。
///
/// ■ FavoritesStoreとの違い
/// - **メニューバーに出ない。** そのためMenuBarMenuGate/MenuBarMenuRefresherには一切関わらない
///   (`AppStores.allObjectWillChangePublishers`にも足さない)。お気に入りの@Publishedが
///   メニュー全体を作り直していた轍を踏まないため(AppStoresの型コメント参照)。
/// - 並び順(FavoritesSortOption)はこのストアが持たない。ウェルカム画面の状態
///   (WelcomeLibraryState)が持ち、`collections(in:sort:)`/`items(in:sort:)`へ都度渡す。
/// - 件数・階層の上限は無い(ライブラリ → コレクション → 本の2段で固定)。
///
/// ■ SwiftDataの約束事(docs/06・CLAUDE.md)
/// - `#Predicate`での絞り込みフェッチは使わない。絞り込み無しで全件取得してSwift側で振り分ける
///   (LayoutStore.bookLayoutSettings(forBookID:)のコメント参照。絞り込みフェッチが誤って
///   0件を返す事象を踏んでいる)。
/// - `@Attribute(.unique)`は付けない。一意性はこのストアが登録前に確認して保証する。
/// - insert/deleteのたびに全件フェッチのキャッシュを捨てる(invalidateLookupCaches)。
@MainActor
final class CollectionStore: ObservableObject {
    /// 帯に並ぶライブラリ(sortOrder順)。
    @Published private(set) var libraries: [BookLibrary] = []

    /// 本の実体がまだ存在するかどうかのキャッシュ(CollectionItem.id -> 存在するか)。
    /// 確認そのものはメインアクターの外で行い、表示側はこの辞書を読むだけ
    /// (FavoritesStore.existenceByFavoriteIDと同じ理由・同じ作り)。
    @Published private(set) var existenceByItemID: [UUID: Bool] = [:]

    /// 「ライブラリ/コレクション/本のどれかが変わった」ことだけを表す通し番号
    /// (saveAndNotifyのコメント参照)。値そのものは誰も読まない。
    @Published private(set) var revision: UInt64 = 0

    private let modelContext: ModelContext
    /// カバー画像(ディスク上のJPEG)の保管庫。**書き込み・削除はこのストアが受け持つ**が、
    /// 読み出しはグリッドのセル(CollectionCoverThumbnail)が直接行うため公開している
    /// (`image(for:maxPixelSize:)`はnonisolatedで、actorの上を通らない)。
    let coverStore: CollectionCoverStore

    /// 絞り込み無し全件フェッチの結果のキャッシュ(FavoritesStore.cachedFolders/cachedBooksと同じ)。
    /// このストアが3つのモデルの唯一の書き込み口であるため、insert/deleteのたびに捨てておけば
    /// 毎回フェッチした場合と同じ結果になる。
    private var cachedLibraries: [BookLibrary]?
    private var cachedCollections: [BookCollection]?
    private var cachedItems: [CollectionItem]?

    private var activationObserver: NSObjectProtocol?
    private var volumeObservers: [NSObjectProtocol] = []
    private var isRefreshingExistence = false
    private var needsAnotherExistenceRefresh = false

    init(modelContext: ModelContext, coverStore: CollectionCoverStore) {
        self.modelContext = modelContext
        self.coverStore = coverStore
        reload()

        // 実体の存在確認は重いので、描画のたびではなく「古くなっている可能性が生まれたとき」に
        // だけ非同期で行う(FavoritesStore.initと同じ考え方・同じ契機)。
        scheduleExistenceRefresh()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleExistenceRefresh() }
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleExistenceRefresh() }
            }
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in volumeObservers {
            workspaceCenter.removeObserver(observer)
        }
    }

    /// このストアが張った購読を外す。**テストのための口**(FavoritesStore.releaseResourcesと
    /// 同じ理由・同じ形。deinitでは間に合わない ―― 解放がメインスレッド以外で始まると
    /// 通知の処理と重なる)。
    func releaseResources() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in volumeObservers {
            workspaceCenter.removeObserver(observer)
        }
        volumeObservers = []
    }

    // MARK: - 読み込み

    /// ライブラリ一覧を読み込み直す。コレクション・本はリレーションシップ経由でその都度取れる
    /// ため、ここでは読まない。**必ず最後にensureDefaultLibrary()を通す**ので、このストアを
    /// 作った時点でライブラリは必ず1つ以上ある。
    func reload() {
        invalidateLookupCaches()
        libraries = allLibraries().sorted { $0.sortOrder < $1.sortOrder }
        ensureDefaultLibrary()
    }

    private func invalidateLookupCaches() {
        cachedLibraries = nil
        cachedCollections = nil
        cachedItems = nil
    }

    private func allLibraries() -> [BookLibrary] {
        if let cachedLibraries { return cachedLibraries }
        let fetched = (try? modelContext.fetch(FetchDescriptor<BookLibrary>())) ?? []
        cachedLibraries = fetched
        return fetched
    }

    private func allCollections() -> [BookCollection] {
        if let cachedCollections { return cachedCollections }
        let fetched = (try? modelContext.fetch(FetchDescriptor<BookCollection>())) ?? []
        cachedCollections = fetched
        return fetched
    }

    private func allItems() -> [CollectionItem] {
        if let cachedItems { return cachedItems }
        let fetched = (try? modelContext.fetch(FetchDescriptor<CollectionItem>())) ?? []
        cachedItems = fetched
        return fetched
    }

    /// ライブラリが1つも無ければ既定のものを1つ作る。ウェルカム画面の帯は「必ず1つ以上」を
    /// 前提に描く(空の帯には何も選べず、コレクションの作り先も無い)。
    func ensureDefaultLibrary() {
        guard allLibraries().isEmpty else { return }
        let library = BookLibrary(
            name: String(localized: "Library", language: AppLanguage.currentLocale), sortOrder: 0
        )
        modelContext.insert(library)
        invalidateLookupCaches()
        try? modelContext.save()
        libraries = [library]
    }

    // MARK: - 読み取り

    /// このライブラリのコレクション(指定した並び順)。
    func collections(in library: BookLibrary, sort: FavoritesSortOption) -> [BookCollection] {
        sorted(library.collections, sort: sort)
    }

    /// このコレクションの本(指定した並び順)。「更新日時」の基準は本の追加日時(addedAt)で
    /// 解釈する ―― 本の行には「後から更新される」情報が無いため。
    func items(in collection: BookCollection, sort: FavoritesSortOption) -> [CollectionItem] {
        sorted(collection.items, sort: sort)
    }

    func library(withID id: UUID) -> BookLibrary? {
        allLibraries().first { $0.id == id }
    }

    func collection(withID id: UUID) -> BookCollection? {
        allCollections().first { $0.id == id }
    }

    func item(withID id: UUID) -> CollectionItem? {
        allItems().first { $0.id == id }
    }

    /// このアプリのコレクションに登録されている本のbookID一覧(「このアプリが知っている本」を
    /// 横断的に集める用途。FavoritesStore.allRegisteredBookIDsと同じ役割)。
    func allRegisteredBookIDs() -> Set<String> {
        Set(allItems().map(\.bookID))
    }

    /// この本が登録されているコレクションの件数(同じ本を複数のコレクションへ入れられるため件数)。
    func membershipCount(forBookID bookID: String) -> Int {
        allItems().filter { $0.bookID == bookID }.count
    }

    /// この本を指すセキュリティスコープ付きブックマークのうち最初に見つかったもの
    /// (BookmarkStore/FavoritesStoreの同名メソッドと同じ用途)。
    func anyBookmarkData(forBookID bookID: String) -> Data? {
        allItems().first { $0.bookID == bookID }?.bookmarkData
    }

    /// 同じライブラリの中に同じ名前のコレクションが既にあるか(前後の空白を除いた完全一致)。
    /// `excluding`にはリネーム中のコレクション自身を渡す(自分の名前とは衝突させない)。
    func hasCollectionNamed(
        _ name: String, in library: BookLibrary, excluding: BookCollection? = nil
    ) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return library.collections.contains {
            $0.id != excluding?.id
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        }
    }

    /// 同じ名前のライブラリが既にあるか(ライブラリは1階層なので全体で見る)。
    func hasLibraryNamed(_ name: String, excluding: BookLibrary? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return allLibraries().contains {
            $0.id != excluding?.id
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        }
    }

    // MARK: - 並び順

    private func sorted(_ collections: [BookCollection], sort: FavoritesSortOption) -> [BookCollection] {
        switch sort {
        case .nameAscending:
            return collections.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return collections.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .dateAddedAscending:
            return collections.sorted { $0.createdAt < $1.createdAt }
        case .dateAddedDescending:
            return collections.sorted { $0.createdAt > $1.createdAt }
        case .dateUpdatedAscending:
            return collections.sorted { $0.updatedAt < $1.updatedAt }
        case .dateUpdatedDescending:
            return collections.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private func sorted(_ items: [CollectionItem], sort: FavoritesSortOption) -> [CollectionItem] {
        switch sort {
        case .nameAscending:
            return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .nameDescending:
            return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        // 本には「更新日時」に相当する情報が無いため、追加日時と同じものとして扱う
        // (items(in:sort:)のコメント参照)。
        case .dateAddedAscending, .dateUpdatedAscending:
            return items.sorted { $0.addedAt < $1.addedAt }
        case .dateAddedDescending, .dateUpdatedDescending:
            return items.sorted { $0.addedAt > $1.addedAt }
        }
    }

    // MARK: - ライブラリ

    /// 新しいライブラリを作る。名前が空・重複している場合はnil(呼び出し側のシートが
    /// hasLibraryNamedで事前に検証しているので、ここは二重の防御)。
    @discardableResult
    func createLibrary(name: String) -> BookLibrary? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hasLibraryNamed(trimmed) else { return nil }
        let library = BookLibrary(name: trimmed, sortOrder: allLibraries().count)
        modelContext.insert(library)
        invalidateLookupCaches()
        saveAndNotify()
        reload()
        return library
    }

    func rename(_ library: BookLibrary, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hasLibraryNamed(trimmed, excluding: library) else { return }
        library.name = trimmed
        saveAndNotify()
        reload()
    }

    /// ライブラリを削除する(配下のコレクション・本はカスケードで消える)。
    ///
    /// **ライブラリが1つしか無いときは何もしない。** 帯が空になると、コレクションの作り先が
    /// 無くなってウェルカム画面が操作不能になるため(ensureDefaultLibraryが次の起動で作り直す
    /// までの間、今開いている画面が壊れる)。UI側も2つ以上あるときだけ削除を出す。
    func delete(_ library: BookLibrary) {
        guard allLibraries().count > 1 else { return }
        // カスケードで消える前に、カバー画像のファイルを消すためのidを集めておく
        // (SwiftDataのcascadeはディスク上のファイルまでは面倒を見ない)。
        let itemIDs = library.collections.flatMap { $0.items.map(\.id) }
        modelContext.delete(library)
        invalidateLookupCaches()
        saveAndNotify()
        removeCovers(itemIDs)
        reload()
    }

    // MARK: - コレクション

    /// 新しいコレクションを作り、最初の本を入れる。
    ///
    /// **1冊も入らないコレクションは作らない。** 空のコレクションはタイルとして何も描けず、
    /// 「作ったのに何も起きない」ように見えるため(検討メモ §5)。名前が空・同じライブラリ内で
    /// 重複、または本が1冊も登録できなかった場合はnilを返し、行を残さない。
    @discardableResult
    func createCollection(
        name: String, in library: BookLibrary, items: [PendingItem]
    ) -> BookCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hasCollectionNamed(trimmed, in: library), !items.isEmpty else {
            return nil
        }
        let collection = BookCollection(name: trimmed, library: library)
        modelContext.insert(collection)
        invalidateLookupCaches()
        let added = insertItems(items, into: collection)
        guard !added.isEmpty else {
            // 1冊も入らなかった(ブックマークが作れない等)。作りかけの行を残さない。
            modelContext.delete(collection)
            invalidateLookupCaches()
            try? modelContext.save()
            return nil
        }
        saveAndNotify()
        reload()
        return collection
    }

    func rename(_ collection: BookCollection, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let library = collection.library,
              !hasCollectionNamed(trimmed, in: library, excluding: collection)
        else { return }
        collection.name = trimmed
        collection.updatedAt = Date()
        saveAndNotify()
        reload()
    }

    func delete(_ collection: BookCollection) {
        let itemIDs = collection.items.map(\.id)
        modelContext.delete(collection)
        invalidateLookupCaches()
        saveAndNotify()
        removeCovers(itemIDs)
        reload()
    }

    // MARK: - 本

    /// 登録しようとしている本1冊ぶんの材料。SwiftDataのモデルを作る前に、URLから取れる情報を
    /// まとめておくためのもの(ドロップ・ファイル選択・JSON取り込みの3つの入り口が同じ形で渡す)。
    struct PendingItem {
        let url: URL
        let bookmarkData: Data
        let title: String
        let identifier: FileNodeIdentifier?
    }

    /// URLから登録の材料を作る。セキュリティスコープ付きブックマークが作れなければnil
    /// (アクセス権が無いURL。FavoritesStore.makeBookmarkDataと同じ判断)。
    static func makePendingItem(for url: URL) -> PendingItem? {
        guard let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return nil }
        // タイトルの作り方はBookLoaderがMangaBook.titleを決めるのと同じ
        // (フォルダはそのまま、ファイルは拡張子を落とす)。
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let title = isDirectory.boolValue
            ? url.lastPathComponent
            : url.deletingPathExtension().lastPathComponent
        return PendingItem(
            url: url, bookmarkData: bookmarkData, title: title,
            identifier: FileNodeIdentifier.current(for: url)
        )
    }

    /// コレクションへ本をまとめて追加する。**同じコレクションに同じ本は入らない**
    /// (パス一致、またはファイルノード識別子の一致で弾く)。保存と通知は最後に1回だけ
    /// (FavoritesStore.forceAddFavoritesと同じ理由 ―― 1件ずつsaveするとJSON取り込みが
    /// 目に見えて遅くなる)。
    @discardableResult
    func add(_ items: [PendingItem], to collection: BookCollection) -> [CollectionItem] {
        let added = insertItems(items, into: collection)
        guard !added.isEmpty else { return [] }
        collection.updatedAt = Date()
        saveAndNotify()
        return added
    }

    /// save()も通知もしない、行を作るところだけ(createCollection/addが共有する)。
    private func insertItems(_ items: [PendingItem], into collection: BookCollection) -> [CollectionItem] {
        // collection.itemsはリレーションシップなので、まだsave()していないこのバッチ内の
        // 追加を反映しないことがある。重複判定と連番の材料はローカルに持っておく
        // (FavoritesStore.forceAddFavoritesのnextSortOrderByFolderIDと同じ理由)。
        var existingPaths = Set(collection.items.map(\.bookID))
        var existingIdentifiers = Set(collection.items.compactMap(\.fileNodeIdentifier))
        var nextSortOrder = collection.items.count
        var created: [CollectionItem] = []

        for pending in items {
            let bookID = pending.url.path
            if existingPaths.contains(bookID) { continue }
            if let identifier = pending.identifier, existingIdentifiers.contains(identifier) { continue }
            let item = CollectionItem(
                bookID: bookID,
                bookmarkData: pending.bookmarkData,
                title: pending.title,
                collection: collection,
                sortOrder: nextSortOrder,
                fileNodeIdentifier: pending.identifier
            )
            modelContext.insert(item)
            existingPaths.insert(bookID)
            if let identifier = pending.identifier { existingIdentifiers.insert(identifier) }
            nextSortOrder += 1
            created.append(item)
        }
        if !created.isEmpty { invalidateLookupCaches() }
        return created
    }

    /// 本をコレクションから外す(カバー画像のファイルも消す)。
    func remove(_ item: CollectionItem) {
        let itemID = item.id
        let bookID = item.bookID
        let collection = item.collection
        modelContext.delete(item)
        invalidateLookupCaches()
        collection?.updatedAt = Date()
        saveAndNotify(bookID: bookID)
        removeCovers([itemID])
        existenceByItemID.removeValue(forKey: itemID)
    }

    /// この本の登録をすべてのコレクションから外す(「本ごとの保存データを削除」から)。
    /// 1件ずつremove(_:)を呼ぶとそのたびにsave()が走るため、まとめて消して保存は1回にする。
    func removeItems(forBookID bookID: String) {
        let targets = allItems().filter { $0.bookID == bookID }
        guard !targets.isEmpty else { return }
        let itemIDs = targets.map(\.id)
        let now = Date()
        var touchedCollections: [ObjectIdentifier: BookCollection] = [:]
        for item in targets {
            if let collection = item.collection {
                touchedCollections[ObjectIdentifier(collection)] = collection
            }
            modelContext.delete(item)
        }
        for collection in touchedCollections.values { collection.updatedAt = now }
        invalidateLookupCaches()
        saveAndNotify(bookID: bookID)
        removeCovers(itemIDs)
        for itemID in itemIDs { existenceByItemID.removeValue(forKey: itemID) }
    }

    /// カバー抽出の結果を書き戻す(CollectionCoverExtractorから)。
    func setCoverStatus(
        _ status: CollectionCoverStatus, cropSide: CoverCropSide, for item: CollectionItem
    ) {
        guard item.coverState != status || item.coverCrop != cropSide else { return }
        item.coverState = status
        item.coverCrop = cropSide
        saveAndNotify(bookID: item.bookID)
    }

    /// 抽出をやり直させる(カバーの上書きが変わったとき)。`.pending`へ戻すだけで、
    /// 実際の抽出はCollectionCoverExtractorが行う。
    func markCoversPending(forBookID bookID: String) {
        let targets = allItems().filter { $0.bookID == bookID && $0.coverState != .pending }
        guard !targets.isEmpty else { return }
        for item in targets { item.coverState = .pending }
        saveAndNotify(bookID: bookID)
    }

    /// まだ抽出できていない本(coverStatus == pending)。CollectionCoverExtractor.refill()が使う。
    func itemsAwaitingCover() -> [CollectionItem] {
        allItems().filter { $0.coverState == .pending }
    }

    /// カバーの作り直しが要る本を選ぶための材料。読み方向の既定が変わったときに
    /// 「横長を切ってある本のうち、本ごとの上書きも明示的な位置指定も無いもの」を拾う
    /// (CollectionCoverExtractor参照)。
    func itemsWithCroppedCover() -> [CollectionItem] {
        allItems().filter { $0.coverCrop != .none }
    }

    /// 指定したbookIDの登録(全コレクション横断)。
    func items(forBookID bookID: String) -> [CollectionItem] {
        allItems().filter { $0.bookID == bookID }
    }

    // MARK: - 移動・リネームへの追従

    /// 同一ボリューム内での移動・リネームに追従する(FavoritesStore.reconcileBookIDIfMovedと
    /// 同じ考え方・同じ手順。AppState.open(url:)から本を開くたびに呼ばれる)。
    func reconcileBookIDIfMoved(book: MangaBook) {
        guard items(forBookID: book.id).isEmpty else { return }
        guard let identifier = FileNodeIdentifier.current(for: book.sourceURL) else { return }
        let candidates = allItems().filter {
            $0.bookID != book.id && $0.fileNodeIdentifier == identifier
        }
        guard !candidates.isEmpty else { return }
        for candidate in candidates { candidate.bookID = book.id }
        saveAndNotify(bookID: book.id)
    }

    /// 識別子を持たない古い行に、パスから取り直した識別子を補完する
    /// (FavoritesStore.backfillFileNodeIdentifierと同じ役割)。
    func backfillFileNodeIdentifier(forBookID bookID: String, identifier: FileNodeIdentifier) {
        let targets = items(forBookID: bookID).filter { $0.fileNodeIdentifier == nil }
        guard !targets.isEmpty else { return }
        for item in targets {
            item.inodeNumber = identifier.inodeNumber
            item.volumeDeviceNumber = identifier.volumeDeviceNumber
        }
        try? modelContext.save()
        cachedItems = nil
    }

    /// ファイルノード識別子が一致する登録から、現在の実際のURLを解決する
    /// (JSON取り込みが、古いパスの本を見つけ直すために使う)。
    func resolvedURL(matching identifier: FileNodeIdentifier) -> URL? {
        for item in allItems() where item.fileNodeIdentifier == identifier {
            if let url = resolvedURL(for: item) { return url }
        }
        return nil
    }

    // MARK: - 開く前のURL解決・存在確認

    /// 保存済みのブックマークからURLを解決する(実体の存在確認はしない)。
    func resolvedURL(for item: CollectionItem) -> URL? {
        FavoritesStore.resolvedURL(fromBookmark: item.bookmarkData)
    }

    /// 開く直前に使う。解決と存在確認の両方に成功したときだけURLを返す(見つからない場合、
    /// 呼び出し側は「本が見つかりません」のアラートを出す)。
    func resolvedExistingURL(for item: CollectionItem) -> URL? {
        guard let url = resolvedURL(for: item) else { return nil }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// キャッシュ済みの存在確認結果。**ファイルアクセスを一切行わない**ので、一覧の描画から
    /// 自由に呼んでよい。まだ確認できていない項目は「存在する」として扱う
    /// (FavoritesStore.cachedFileExistsと同じ理由: 起動直後に全部が消えたように見せない)。
    func cachedFileExists(for item: CollectionItem) -> Bool {
        existenceByItemID[item.id] ?? true
    }

    /// 全登録の実体確認を非同期に予約する(FavoritesStore.scheduleExistenceRefreshと同じ作り)。
    func scheduleExistenceRefresh() {
        guard !isRefreshingExistence else {
            needsAnotherExistenceRefresh = true
            return
        }
        isRefreshingExistence = true
        // SwiftDataのモデルはそのまま外へ渡せないので、メインアクターにいるうちに
        // Sendableな値(UUIDとData)へ写し取る。
        let probes = allItems().map { (id: $0.id, bookmark: $0.bookmarkData) }
        guard !probes.isEmpty else {
            isRefreshingExistence = false
            if !existenceByItemID.isEmpty { existenceByItemID = [:] }
            return
        }
        // [weak self]で受けたselfを、awaitをまたぐ前にguard letで強参照へ変換しておく
        // (理由はRecentFilesStore.scheduleRefresh()の同種のコメント参照)。
        Task.detached(priority: .utility) { [weak self] in
            var result: [UUID: Bool] = [:]
            for probe in probes {
                result[probe.id] = FavoritesStore.fileExists(bookmark: probe.bookmark)
            }
            guard let self else { return }
            await self.finishExistenceRefresh(result)
        }
    }

    private func finishExistenceRefresh(_ result: [UUID: Bool]) {
        isRefreshingExistence = false
        defer {
            if needsAnotherExistenceRefresh {
                needsAnotherExistenceRefresh = false
                scheduleExistenceRefresh()
            }
        }
        // @Publishedは値が同じでも代入のたびに発火するため、変化したときだけ代入する。
        guard result != existenceByItemID else { return }
        existenceByItemID = result
    }

    // MARK: - 一括削除

    /// ライブラリ・コレクション・本とカバー画像をすべて消す(JSONの上書き取り込みの前段、
    /// および環境設定「リセット」から)。
    ///
    /// `modelContext.delete(model:)`(述語なしの一括削除)は使わない。逆リレーションが
    /// mandatoryなモデルではバッチ削除が全件失敗し、その失敗がtry?で握り潰されて
    /// 「消したはずの行が残る」という形で表面化する(FavoritesStore.deleteAllFavoritesの
    /// コメントに実測の記録がある)。行をフェッチして1件ずつ消す。
    func deleteAll() {
        for item in (try? modelContext.fetch(FetchDescriptor<CollectionItem>())) ?? [] {
            modelContext.delete(item)
        }
        for collection in (try? modelContext.fetch(FetchDescriptor<BookCollection>())) ?? [] {
            modelContext.delete(collection)
        }
        for library in (try? modelContext.fetch(FetchDescriptor<BookLibrary>())) ?? [] {
            modelContext.delete(library)
        }
        invalidateLookupCaches()
        saveAndNotify()
        existenceByItemID = [:]
        let store = coverStore
        Task { await store.removeAll() }
        reload()
    }

    /// 起動時に一度、行の無いカバー画像を掃除する(CollectionCoverStore.sweepOrphans参照)。
    func sweepOrphanedCovers() {
        let ids = Set(allItems().map(\.id))
        let store = coverStore
        Task { await store.sweepOrphans(keeping: ids) }
    }

    // MARK: - 保存と通知

    private func removeCovers(_ itemIDs: [UUID]) {
        guard !itemIDs.isEmpty else { return }
        let store = coverStore
        Task { await store.remove(itemIDs) }
    }

    /// 保存して、変更を他のウインドウへ知らせる。`bookID`は**本に関わる変更**のときだけ渡す
    /// (Notification.Name.collectionsDidChangeのコメント参照)。
    private func saveAndNotify(bookID: String? = nil) {
        try? modelContext.save()
        // コレクションの名前・中身の変更は`libraries`配列そのものを変えないため、@Publishedの
        // 再代入だけでは画面が追随しない(SwiftDataのモデルはクラス=参照型で、SwiftUIから見た
        // 値は同じまま)。「何かが変わった」ことだけを表す通し番号を進めて描き直させる
        // (MenuBarMenuRefresher.revisionと同じ手。値そのものは誰も読まない)。
        revision &+= 1
        NotificationCenter.default.post(
            name: .collectionsDidChange, object: nil,
            userInfo: bookID.map { ["bookID": $0] }
        )
    }
}

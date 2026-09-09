import Foundation
import Combine
import CoreGraphics

/// コレクションに登録された本のカバー画像を、1冊ずつ順に抽出してディスクへ保存する司会役
/// (改善要望5)。アプリ全体で1つ(AppStoresが持つ)= ウインドウをまたいで1本の待ち行列。
///
/// ■ なぜ同時1件なのか
/// 抽出は「本を丸ごと開いて先頭ページを復号する」処理で、書庫なら展開、フォルダなら再帰走査を
/// 伴う。棚を1つドロップすると数十冊が一度に登録されるため、並列に走らせるとメモリも
/// ディスクI/Oも一気に食い、ビューアでページをめくる操作の邪魔になる。順番どおり1冊ずつ
/// 進めれば、画面の上から順にカバーが埋まっていく見え方にもなる。
///
/// ■ 抽出をやり直す契機
/// - カバーの上書き(ページ指定・外部ファイル)が変わったとき
///   → `.layoutDataDidChange`(bookID付き)で届く。自分が最後に使った値と**比べて**違うときだけ
///     やり直す(ViewerViewModel.reloadLayoutDataと同じ方式)。
///
/// 契機はこれだけ ―― **カバーの見せ方(比・切り出す位置・読み方向)では作り直さない。**
/// カバーは切らずに保存し、枠へ合わせるのは表示のたびに行うようになった
/// (CoverImageResolver.cropped(_:to:anchor:)のコメント参照)ので、抽出が気にするのは
/// 「どの画像か」だけになった。
@MainActor
final class CollectionCoverExtractor: ObservableObject {
    /// いま抽出中のitem(表示側がスピナーを出すために見る)。同時1件なので高々1つ。
    @Published private(set) var inFlightItemIDs: Set<UUID> = []

    private let collectionStore: CollectionStore
    private let coverStore: CollectionCoverStore
    private let layoutStore: LayoutStore
    /// 抽出のために読み込んだ本のページ一覧を、ディスクキャッシュへ書き戻すか
    /// (**テストのための口**。LibraryImportExportService.cachesPageListと同じ理由)。
    private let cachesPageList: Bool
    /// カバーの保存世代(migrateCoverStorageIfNeeded)の置き場所。通常はアプリの
    /// `UserDefaults.standard`で、テストだけが専用のsuiteを渡す(共有状態に触らないため。
    /// WelcomeLibraryState.defaultsと同じ理由)。
    private let defaults: UserDefaults

    /// 保存してあるカバーの作り方の世代。上げると次回の起動で全件が抽出し直される
    /// (migrateCoverStorageIfNeeded)。
    /// - 1: 抽出の時点で2:3へ切って保存していた
    /// - 2: 切らずに保存し、枠へ合わせるのは表示時(2026-09-09)
    static let coverStorageGeneration = 2

    /// 待ち行列(CollectionItem.id)。同じidを二重に積まない。
    private var queue: [UUID] = []
    private var queuedIDs: Set<UUID> = []
    private var currentTask: Task<Void, Never>?
    private var isRunning = false
    /// 走行世代。cancelAll()で進める。走り終わったループが、その後に始まった新しいループの
    /// 状態を消してしまわないようにするための番号(ThumbnailDiskCacheの
    /// lastConfigurationGenerationと同じ考え方)。
    private var runGeneration = 0

    /// bookIDごとの「最後に**見た**ときの条件」。`.layoutDataDidChange`が届いたときに、
    /// 本当にカバーが変わる変更なのかを判定するために持つ(レイアウトの通知は、ページ単位の
    /// 見開き指定など、カバーと無関係な変更でも飛んでくる)。
    ///
    /// 抽出したときだけでなく、**知った時点**(起動時とrefill)でも記録する。前回の起動で
    /// 抽出済み(ready)の本はこの起動では一度も抽出を通らないため、抽出時にしか記録しないと
    /// 「比べる相手が無い」を理由に変更を取りこぼす ―― 起動してすぐカバーのページを変えても
    /// 作り直されない、という形で出る。
    private struct CoverSignature: Equatable {
        var coverPageKey: String?
        var externalCoverFileName: String?
    }
    private var signatures: [String: CoverSignature] = [:]

    private var observers: [NSObjectProtocol] = []

    init(
        collectionStore: CollectionStore,
        coverStore: CollectionCoverStore,
        layoutStore: LayoutStore,
        cachesPageList: Bool = true,
        defaults: UserDefaults = .standard
    ) {
        self.collectionStore = collectionStore
        self.coverStore = coverStore
        self.layoutStore = layoutStore
        self.cachesPageList = cachesPageList
        self.defaults = defaults

        // queue: .mainを指定しているため実行時には必ずMainActor上で呼ばれるが、クロージャ自体の
        // 型はMainActorに分離されていないため、コンパイラは静的にそれを保証できない
        // (FavoritesStore.initの同種のコメント参照)。
        let layoutObserver = NotificationCenter.default.addObserver(
            forName: .layoutDataDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleLayoutChange(bookID: notification.userInfo?["bookID"] as? String)
            }
        }
        // 本が増えた/やり直しの印が付いた、を取りこぼさないための保険。まだ抽出していない本を
        // 拾うだけなので、自分の書き込みで呼ばれても何も起きない(収束する)。
        let collectionsObserver = NotificationCenter.default.addObserver(
            forName: .collectionsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refill() }
        }
        observers = [layoutObserver, collectionsObserver]

        // 既に登録済みの本(前回の起動で抽出を終えているもの)の条件を先に控えておく
        // (signaturesのコメント参照)。
        seedSignatures(for: collectionStore.allRegisteredBookIDs())

        migrateCoverStorageIfNeeded()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 購読を外して待ち行列を空にする。**テストのための口**(CollectionStore.releaseResourcesと
    /// 同じ理由)。
    func releaseResources() {
        cancelAll()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    // MARK: - 待ち行列

    /// 抽出を予約する。既に並んでいる/抽出中のものは無視する。
    func enqueue(_ items: [CollectionItem]) {
        var didAppend = false
        for item in items where !queuedIDs.contains(item.id) && !inFlightItemIDs.contains(item.id) {
            queue.append(item.id)
            queuedIDs.insert(item.id)
            didAppend = true
        }
        guard didAppend else { return }
        startIfNeeded()
    }

    /// まだ抽出できていない本(coverStatus == pending)をすべて予約し直す。
    /// ウェルカム画面を表示したとき、JSONを取り込んだあと、そして`.collectionsDidChange`のたび。
    func refill() {
        seedSignatures(for: collectionStore.allRegisteredBookIDs())
        enqueue(collectionStore.itemsAwaitingCover())
    }

    /// まだ控えていないbookIDの条件を、いまのDBの値で記録する(抽出はしない)。
    private func seedSignatures(for bookIDs: Set<String>) {
        for bookID in bookIDs where signatures[bookID] == nil {
            let snapshot = layoutStore.coverOverrideSnapshot(forBookID: bookID)
            signatures[bookID] = signature(forBookID: bookID, snapshot: snapshot)
        }
    }

    /// 走行中の抽出も含めて全部やめる。
    func cancelAll() {
        queue.removeAll()
        queuedIDs.removeAll()
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
        runGeneration &+= 1
        if !inFlightItemIDs.isEmpty { inFlightItemIDs = [] }
    }

    private func takeNext() -> UUID? {
        guard !queue.isEmpty else { return nil }
        let id = queue.removeFirst()
        queuedIDs.remove(id)
        return id
    }

    private func startIfNeeded() {
        guard !isRunning else { return }
        isRunning = true
        runGeneration &+= 1
        let generation = runGeneration
        currentTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let extractor = self, let itemID = extractor.takeNext() else { break }
                await extractor.extract(itemID: itemID)
            }
            guard let extractor = self, extractor.runGeneration == generation else { return }
            extractor.isRunning = false
            extractor.currentTask = nil
        }
    }

    // MARK: - 抽出

    private func extract(itemID: UUID) async {
        guard let item = collectionStore.item(withID: itemID) else { return }
        let bookID = item.bookID
        inFlightItemIDs.insert(itemID)
        defer { inFlightItemIDs.remove(itemID) }

        guard let url = collectionStore.resolvedURL(for: item) else {
            collectionStore.setCoverStatus(.failed, aspect: 0, for: item)
            return
        }
        let snapshot = layoutStore.coverOverrideSnapshot(forBookID: bookID)
        signatures[bookID] = signature(forBookID: bookID, snapshot: snapshot)

        let didAccess = url.startAccessingSecurityScopedResource()
        let image = await CoverImageResolver.coverImage(
            bookAt: url, snapshot: snapshot,
            maxPixelSize: CollectionCoverStore.maxPixelSize, cachesPageList: cachesPageList
        )
        if didAccess { url.stopAccessingSecurityScopedResource() }

        // 読み込んでいる間にコレクションから外された可能性があるので、書き戻す前に引き直す。
        guard let current = collectionStore.item(withID: itemID) else { return }
        guard let image, image.width > 0, image.height > 0 else {
            collectionStore.setCoverStatus(.failed, aspect: 0, for: current)
            return
        }
        // **切らずに**そのまま保存する。枠の比(ライブラリごと)へ合わせるのは表示側の仕事
        // (CoverImageResolver.cropped(_:to:anchor:)のコメント参照)。
        do {
            try await coverStore.write(image, for: itemID)
        } catch {
            collectionStore.setCoverStatus(.failed, aspect: 0, for: current)
            return
        }
        guard let stored = collectionStore.item(withID: itemID) else { return }
        collectionStore.setCoverStatus(
            .ready, aspect: Double(image.width) / Double(image.height), for: stored
        )
    }

    private func signature(
        forBookID bookID: String, snapshot: CoverImageResolver.OverrideSnapshot
    ) -> CoverSignature {
        CoverSignature(
            coverPageKey: snapshot.coverPageKey,
            externalCoverFileName: layoutStore.bookLayoutSettings(forBookID: bookID)?
                .externalCoverFileName
        )
    }

    // MARK: - やり直しの契機

    /// レイアウトの変更通知。カバーに関わる値が実際に変わっている本だけをやり直す。
    private func handleLayoutChange(bookID: String?) {
        guard let bookID else { return }
        let items = collectionStore.items(forBookID: bookID)
        guard !items.isEmpty else { return }
        let snapshot = layoutStore.coverOverrideSnapshot(forBookID: bookID)
        let current = signature(forBookID: bookID, snapshot: snapshot)
        // 控えが無い本は、この通知より後に登録されたもの。pendingのままなのでrefillが拾う。
        guard let previous = signatures[bookID] else {
            signatures[bookID] = current
            return
        }
        guard previous != current else { return }
        signatures[bookID] = current
        collectionStore.markCoversPending(forBookID: bookID)
        enqueue(items)
    }

    // MARK: - 保存の仕方が変わったときの一度きりの作り直し

    /// 保存してあるカバーの**作り方**が変わったときに、全件を抽出し直す。
    ///
    /// この起動で必要なのは第2世代への移行 ―― 第1世代は抽出の時点で2:3へ切ってJPEGを保存して
    /// いた(CoverImageResolver.cropped(_:to:anchor:)のコメント参照)。そのまま残すと、
    /// 1:1のライブラリで「一度2:3に切られた画像をさらに正方形へ切る」ことになり、横が二重に
    /// 失われる。世代番号をUserDefaultsに持ち、上がっていたら1回だけ`.pending`へ戻す。
    ///
    /// `qooViewer.pref.`で始まらないキーにしてあるのは、環境設定の「初期設定に戻す」で
    /// 消えないようにするため ―― 消えると起動のたびに全件を抽出し直してしまう
    /// (WelcomeLibraryStateのキーと同じ判断)。
    private func migrateCoverStorageIfNeeded() {
        let key = "qooViewer.collections.coverStorageGeneration"
        guard defaults.integer(forKey: key) < Self.coverStorageGeneration else { return }
        defaults.set(Self.coverStorageGeneration, forKey: key)
        for bookID in collectionStore.allRegisteredBookIDs() {
            collectionStore.markCoversPending(forBookID: bookID)
        }
    }
}

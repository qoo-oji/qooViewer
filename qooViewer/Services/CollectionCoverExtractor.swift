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
///
/// ■ 実体が見つからない本は`.failed`にしない(監査で指摘 2026-09-09)
/// 外付け/ネットワークボリュームが未接続のときに待ち行列が回ると、そのボリューム上の本が全冊
/// `.failed`(灰色)になり、再接続しても二度と抽出されなかった。`.failed`は「本が壊れている」
/// ときだけにして、実体が見つからない本は`.pending`のまま置く。表示側は存在確認の結果
/// (CollectionStore.cachedFileExists)で淡く描くので、灰色と見分けがつく。
/// 見つからない本を待ち行列へ入れ続けないよう、refill()は存在確認で「無い」と分かっている本を
/// 飛ばし、実体確認の結果(`locationByItemID`)が変わったとき ―― 再接続・アプリのアクティブ化
/// ―― にもう一度refill()する。
@MainActor
final class CollectionCoverExtractor: ObservableObject {
    /// いま抽出中のitem(表示側がスピナーを出すために見る)。同時1件なので高々1つ。
    @Published private(set) var inFlightItemIDs: Set<UUID> = []

    /// 本を解決しにいった回数(**テストのための口**)。実体が見つからない本を積まなくなった
    /// こと・切り出し位置の変更で抽出し直さないことを、状態ではなく回数で確かめるために持つ。
    private(set) var extractionAttemptCount = 0

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
    /// 存在確認の結果が変わったら待ち行列を組み直す(型コメント「実体が見つからない本」参照)。
    private var existenceCancellable: AnyCancellable?

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
        // `@Published`の投影はwillSetで飛ぶ(ストアの値はまだ差し替わっていない)ので、
        // 届いた値のほうで組み直す。代入はメインアクター上(finishExistenceRefresh)なので
        // ここも同期的にメインアクター上で走る(FavoritesStore.initの同種のコメント参照)。
        // Taskで1拍遅らせないのは、存在確認の待ち合わせ(CollectionStore.settleExistenceRefresh)
        // が返った時点で待ち行列が組み直されている、と言えるようにするため。
        existenceCancellable = collectionStore.$locationByItemID
            .dropFirst()
            .sink { [weak self] locations in
                MainActor.assumeIsolated { self?.refill(locations: locations) }
            }

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
        existenceCancellable = nil
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
    /// ウェルカム画面を表示したとき、JSONを取り込んだあと、`.collectionsDidChange`のたび、
    /// そして存在確認の結果が変わったとき。
    ///
    /// 存在確認で「無い」と分かっている本は積まない(型コメント「実体が見つからない本」参照)。
    /// まだ確認できていない本は「ある」として扱われる(cachedFileExistsの既定)ので、起動直後は
    /// 一度は試みる ―― 見つからなければ`.pending`のまま戻り、通知も出ないので、次に組み直す
    /// 契機まで積み直されない。
    func refill() {
        refill(locations: collectionStore.locationByItemID)
    }

    /// - Parameter locations: 判定に使う実体確認の結果(CollectionStore.locationByItemID、
    ///   またはその投影から届いた新しい値)。まだ確認していない本は「ある」として扱う
    ///   (cachedFileExistsと同じ)。
    private func refill(locations: [UUID: BookLocation]) {
        seedSignatures(for: collectionStore.allRegisteredBookIDs())
        enqueue(collectionStore.itemsAwaitingCover().filter { locations[$0.id]?.exists ?? true })
    }

    /// まだ控えていないbookIDの条件を、いまのDBの値で記録する(抽出はしない)。
    private func seedSignatures(for bookIDs: Set<String>) {
        for bookID in bookIDs where signatures[bookID] == nil {
            signatures[bookID] = signature(forBookID: bookID)
        }
    }

    /// 待ち行列が空になり、走っている抽出が終わるまで待つ(**テストのための口**。
    /// ViewerViewModel.settleと同じく、時間ではなく仕事の終わりで待つ)。
    /// 待っている間に積まれたぶんも含めて、静かになるまで繰り返す。
    func waitUntilIdle() async {
        while let task = currentTask {
            await task.value
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
        extractionAttemptCount += 1
        // ブックマークが解決できない・実体が無い本は`.pending`のまま置いて戻る
        // (型コメント「実体が見つからない本」参照)。`.failed`は本を開けなかったときだけ。
        guard let url = collectionStore.resolvedExistingURL(for: item) else { return }
        inFlightItemIDs.insert(itemID)
        defer { inFlightItemIDs.remove(itemID) }

        // 抽出に使う条件(外部カバーのURL解決を含む)はここでだけ組み立てる。控えに要るのは
        // 「どの画像か」を表す2列だけなので、控えのほうは本を解決せずにDBの値から作る
        // (signature(forBookID:)参照)。
        let snapshot = layoutStore.coverOverrideSnapshot(forBookID: bookID)
        signatures[bookID] = signature(forBookID: bookID)

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
        // 焼いてある札の絵は、この本のカバーが**差し替わった**ことを自分では知りようがない
        // (指紋にカバーの中身は入っていない)ので、ここで捨てる
        // (CollectionStore.invalidateTileImages(forItemID:)参照)。
        collectionStore.invalidateTileImages(forItemID: itemID)
        guard let stored = collectionStore.item(withID: itemID) else { return }
        collectionStore.setCoverStatus(
            .ready, aspect: Double(image.width) / Double(image.height), for: stored
        )
    }

    /// 「どの画像か」の控え。**DBの2列だけから作り、外部カバーのURLは解決しない。**
    ///
    /// 以前はcoverOverrideSnapshot(forBookID:)を経由していたが、あれは外部カバーのセキュリティ
    /// スコープ付きブックマークを解決して実体の有無まで確かめる。起動時に全登録冊ぶん
    /// (seedSignatures)、レイアウトの通知のたび(handleLayoutChange)にそれが走ると、外部カバーが
    /// 到達できない共有上にある本1冊ごとにメインが秒単位で止まる(監査で指摘 2026-09-09)。
    /// 控えの比較に要るのはファイル名で足りる。
    private func signature(forBookID bookID: String) -> CoverSignature {
        let settings = layoutStore.bookLayoutSettings(forBookID: bookID)
        return CoverSignature(
            coverPageKey: settings?.coverPageKey,
            externalCoverFileName: settings?.externalCoverFileName
        )
    }

    // MARK: - やり直しの契機

    /// レイアウトの変更通知。カバーに関わる値が実際に変わっている本だけをやり直す。
    private func handleLayoutChange(bookID: String?) {
        guard let bookID else { return }
        let items = collectionStore.items(forBookID: bookID)
        guard !items.isEmpty else { return }
        let current = signature(forBookID: bookID)
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
        // save()と通知は1回だけ(CollectionStore.markAllCoversPendingのコメント参照)。
        collectionStore.markAllCoversPending()
    }
}

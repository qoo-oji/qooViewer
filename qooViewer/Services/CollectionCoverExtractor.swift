import AppKit
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
/// ■ 何の絵を作るのか
/// **コレクション表紙**(棚・コレクションの表示に使う絵)であって、EPUB/CBZ/PDFへ書き出す
/// カバー画像ではない。2つは2026-09-11に分けた(BookLayoutSettingsの型コメント参照)ので、
/// この司会役が見るのは`shelfCover*`の列だけ ―― 書き出し用のカバー画像を変えても、ここは
/// 何もしない。
///
/// ■ 抽出をやり直す契機
/// - コレクション表紙の上書き(ページ指定・画像指定)が変わったとき
///   → `.layoutDataDidChange`(bookID付き)で届く。自分が最後に使った値と**比べて**違うときだけ
///     やり直す(ViewerViewModel.reloadLayoutDataと同じ方式)。
///
/// - 「並び順をFinderに揃える」を切り替えて、**実効1ページ目が変わる本**(ユーザー要望 2026-09-13)
///   → `.pageOrderSettingDidChange`。表紙を指定していない本だけが対象で、**表紙を出したまま**
///     裏で作り直す(handlePageOrderSettingChange)。
///
/// それ以外 ―― **カバーの見せ方(比・切り出す位置・読み方向)では作り直さない。**
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
        var shelfCoverPageKey: String?
        var shelfCoverImageFileName: String?
    }
    private var signatures: [String: CoverSignature] = [:]

    /// 抽出中にもう一度作り直しを頼まれたitem。走っている抽出は古い条件で読み始めているので、
    /// 終わったらもう一度積む(並び順の設定を続けて切り替えたとき。handlePageOrderSettingChange)。
    private var redoAfterExtraction: Set<UUID> = []
    /// 並び順の設定を変えたときの判定(ページ一覧のキャッシュを読む)。次の切り替えが来たら取り消す。
    private var pageOrderEvaluation: Task<Void, Never>?
    /// 「並び順をFinderに揃える」の現在値の読み口(**テストのための口**。既定は環境設定。
    /// PageOrder.usesFinderOrderはUserDefaults.standardを読むので、テストは差し替える)。
    private let usesFinderOrder: () -> Bool
    /// 本のページ一覧のキャッシュの読み口(**テストのための口**。既定はBookPageListCache.shared)。
    private let cachedPageList: @Sendable (String) async -> [BookPageListCache.Entry.Page]?

    /// **一時的な理由で**抽出できなかったitem。次にアプリがアクティブになるまで積み直さない。
    ///
    /// ■ なぜ`.failed`にしないのか(監査で指摘 2026-09-13)
    /// `.failed`は表紙の指定を変えるまで二度と抽出されない。以前はディスクが一杯でJPEGを
    /// 書けなかったとき・読んでいる途中で外付けを抜いたときも`.failed`にしていたので、原因が
    /// 解消しても灰色のまま戻らなかった。とはいえ`.pending`のまま置くだけだと、
    /// `.collectionsDidChange`のたび(=他の本の抽出が1冊終わるたび)にrefill()が積み直し、
    /// ディスクが一杯の間じゅう失敗を繰り返す。そこで状態は`.pending`のまま、この集合で
    /// 「いまは積まない」とし、アクティブ化(利用者が何かをしに戻ってきた)で解く。
    private var deferredItemIDs: Set<UUID> = []

    private var observers: [NSObjectProtocol] = []
    /// 存在確認の結果が変わったら待ち行列を組み直す(型コメント「実体が見つからない本」参照)。
    private var existenceCancellable: AnyCancellable?

    init(
        collectionStore: CollectionStore,
        coverStore: CollectionCoverStore,
        layoutStore: LayoutStore,
        cachesPageList: Bool = true,
        defaults: UserDefaults = .standard,
        usesFinderOrder: @escaping () -> Bool = { PageOrder.usesFinderOrder },
        cachedPageList: @escaping @Sendable (String) async -> [BookPageListCache.Entry.Page]? = {
            await BookPageListCache.shared.pageList(forBookID: $0)?.pages
        }
    ) {
        self.collectionStore = collectionStore
        self.coverStore = coverStore
        self.layoutStore = layoutStore
        self.cachesPageList = cachesPageList
        self.defaults = defaults
        self.usesFinderOrder = usesFinderOrder
        self.cachedPageList = cachedPageList

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
        // 並び順の設定が変わったら、実効1ページ目が変わる本の表紙を作り直す(型コメント参照)。
        let pageOrderObserver = NotificationCenter.default.addObserver(
            forName: .pageOrderSettingDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePageOrderSettingChange() }
        }
        // 一時的な理由で見送ったitemを、戻ってきた時点で積み直す(deferredItemIDsのコメント参照)。
        let activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.deferredItemIDs.isEmpty else { return }
                self.deferredItemIDs.removeAll()
                self.refill()
            }
        }
        observers = [layoutObserver, collectionsObserver, pageOrderObserver, activationObserver]
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

        // **控えを取る前に**分離の移行を済ませる ―― 移行はshelfCover*の列を書き換えるので、
        // 先に控えを取ると「移行によって変わった」ことを変更と見なして全件抽出し直してしまう。
        migrateShelfCoverSeparationIfNeeded()

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
        enqueue(collectionStore.itemsAwaitingCover().filter { item in
            // 一時的な理由で見送ったものは、アクティブ化まで積まない(deferredItemIDsのコメント)。
            guard !deferredItemIDs.contains(item.id) else { return false }
            // 実体が見つからない本は積まない ―― ただし、利用者が用意した画像を表紙にして
            // いる本は本を開かずに作れるので積む(extract(itemID:)のコメント参照)。
            if locations[item.id]?.exists ?? true { return true }
            return layoutStore.shelfCoverImageFileName(forBookID: item.bookID) != nil
        })
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
        redoAfterExtraction.removeAll()
        pageOrderEvaluation?.cancel()
        pageOrderEvaluation = nil
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
                // 抽出中に作り直しを頼まれていたら、もう一度積む(redoAfterExtractionのコメント)。
                if extractor.redoAfterExtraction.remove(itemID) != nil,
                   !extractor.queuedIDs.contains(itemID) {
                    extractor.queue.append(itemID)
                    extractor.queuedIDs.insert(itemID)
                }
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
        // 抽出に使う条件はここでだけ組み立てる。控えに要るのは「どの画像か」を表す2列だけなので、
        // 控えのほうは本を解決せずにDBの値から作る(signature(forBookID:)参照)。
        var snapshot = layoutStore.shelfCoverSnapshot(forBookID: bookID)
        // 並び順の設定は、作り直しの判定(handlePageOrderSettingChange)と同じ読み口から取る。
        snapshot.usesFinderOrder = usesFinderOrder()
        let url = collectionStore.resolvedExistingURL(for: item)
        // ブックマークが解決できない・実体が無い本は`.pending`のまま置いて戻る
        // (型コメント「実体が見つからない本」参照)。`.failed`は本を開けなかったときだけ。
        //
        // **ただし、利用者が用意した画像を表紙にしている本は別**(2026-09-11) ―― その絵は
        // 保管庫(CollectionCoverSourceStore)にあり、本を1バイトも読まずに作れる。未接続の
        // 外付けボリューム上の本でも表紙は出せるので、ここで弾いてはいけない。
        guard url != nil || snapshot.imageFileURL != nil else { return }
        inFlightItemIDs.insert(itemID)
        defer { inFlightItemIDs.remove(itemID) }

        signatures[bookID] = signature(forBookID: bookID)

        let didAccess = url?.startAccessingSecurityScopedResource() ?? false
        let image = await CoverImageResolver.coverImage(
            bookAt: url, snapshot: snapshot,
            maxPixelSize: CollectionCoverStore.maxPixelSize, cachesPageList: cachesPageList
        )
        if didAccess { url?.stopAccessingSecurityScopedResource() }

        // 読み込んでいる間にコレクションから外された可能性があるので、書き戻す前に引き直す。
        guard let current = collectionStore.item(withID: itemID) else { return }
        guard let image, image.width > 0, image.height > 0 else {
            // 読んでいる途中で本が見えなくなった(外付けを抜いた・共有が落ちた)なら、本が壊れて
            // いるとは言えない。`.pending`のまま置き、実体確認の結果が変われば積み直される
            // (deferredItemIDsのコメント・型コメント「実体が見つからない本」参照)。
            if url != nil, snapshot.imageFileURL == nil,
               collectionStore.resolvedExistingURL(for: current) == nil {
                return
            }
            collectionStore.setCoverStatus(.failed, aspect: 0, for: current)
            return
        }
        // **切らずに**そのまま保存する。枠の比(ライブラリごと)へ合わせるのは表示側の仕事
        // (CoverImageResolver.cropped(_:to:anchor:)のコメント参照)。
        do {
            try await coverStore.write(image, for: itemID)
        } catch {
            // 書けなかったのはこちら側の事情(ディスクが一杯など)で、本は読めている。
            // `.failed`にせず、アクティブ化まで見送る(deferredItemIDsのコメント参照)。
            NSLog("%@", "qooViewer: collection cover write failed for \(itemID): \(error)")
            deferredItemIDs.insert(itemID)
            return
        }
        // 焼いてある札の絵は、この本のカバーが**差し替わった**ことを自分では知りようがない
        // (指紋にカバーの中身は入っていない)ので、ここで捨てる
        // (CollectionStore.invalidateTileImages(forItemID:)参照)。
        await collectionStore.invalidateTileImages(forItemID: itemID)
        guard let stored = collectionStore.item(withID: itemID) else { return }
        collectionStore.setCoverReady(
            aspect: Double(image.width) / Double(image.height), for: stored
        )
    }

    /// 「どの画像か」の控え。**DBの2列だけから作り、外部カバーのURLは解決しない。**
    ///
    /// 以前はshelfCoverSnapshot(forBookID:)を経由していたが、当時のあれは外部カバーの
    /// セキュリティスコープ付きブックマークを解決して実体の有無まで確かめていた
    /// (表紙の絵はアプリの中へ複製するようになったので、今はもう解決しない)。起動時に全登録冊ぶん
    /// (seedSignatures)、レイアウトの通知のたび(handleLayoutChange)にそれが走ると、外部カバーが
    /// 到達できない共有上にある本1冊ごとにメインが秒単位で止まる(監査で指摘 2026-09-09)。
    /// 控えの比較に要るのはファイル名で足りる。
    ///
    /// 2026-09-11の分離以降、見るのは**コレクション表紙の列だけ**。書き出し用のカバー画像を
    /// 変えても棚の絵は変わらないので、あちらの変更でここが反応してはいけない。
    private func signature(forBookID bookID: String) -> CoverSignature {
        let settings = layoutStore.bookLayoutSettings(forBookID: bookID)
        return CoverSignature(
            shelfCoverPageKey: settings?.shelfCoverPageKey,
            shelfCoverImageFileName: settings?.shelfCoverImageFileName
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
        // 利用者が表紙を選び直した = いま試すべき契機。見送りは解く。
        for item in items { deferredItemIDs.remove(item.id) }
        collectionStore.markCoversPending(forBookID: bookID)
        enqueue(items)
    }

    /// 「並び順をFinderに揃える」が切り替わった(ユーザー要望 2026-09-13)。
    ///
    /// ■ 何を作り直すか
    /// 表紙を指定していない(= 実効1ページ目を表紙にしている)`.ready`の本のうち、**新旧の設定で
    /// 実効1ページ目が変わる本だけ**。並べ替え(レイアウト)で順番を固定した本・PDF/EPUBは、
    /// 判定の式(CoverImageResolver.firstPage)がそのまま「変わらない」と答える。
    /// 判定は本を開かずに、ページ一覧のキャッシュ(BookPageListCache)で行う。**キャッシュが無い本は
    /// 作り直す**(ユーザーの判断 2026-09-13 ―― 判定できないまま古い表紙を残すより、1冊ずつ
    /// 読み直して確実に合わせる。作り直した本はキャッシュが埋まるので、次からは判定できる)。
    ///
    /// ■ 表紙を出したまま作り直す
    /// `.pending`へ戻さない ―― 戻すと、作り直しが順番を待つ間ずっと表紙が下地とスピナーになる。
    /// 待ち行列へ積むだけにして、書き終えた時点で差し替える(CollectionStore.setCoverReadyが
    /// 描き直しの合図を出す)。本が見つからなければextractが何もせずに戻り、古い表紙が残る。
    func handlePageOrderSettingChange() {
        pageOrderEvaluation?.cancel()
        let newValue = usesFinderOrder()
        // SwiftDataのモデルはメインアクターの外へ渡せないので、判定に要る値へ写し取る。
        struct Candidate: Sendable {
            let bookID: String
            let isDocument: Bool
            let snapshot: CoverImageResolver.OverrideSnapshot
        }
        var seen: Set<String> = []
        var candidates: [Candidate] = []
        for item in collectionStore.allItems() where item.coverState == .ready {
            guard seen.insert(item.bookID).inserted else { continue }
            let snapshot = layoutStore.shelfCoverSnapshot(forBookID: item.bookID)
            // 表紙を指定している本は、並び順と関係が無い。
            guard snapshot.coverPageKey == nil, snapshot.imageFileURL == nil else { continue }
            candidates.append(Candidate(
                bookID: item.bookID,
                isDocument: isPDFFile(item.bookID) || isEpubFile(item.bookID),
                snapshot: snapshot
            ))
        }
        guard !candidates.isEmpty else { return }
        let cachedPageList = cachedPageList
        pageOrderEvaluation = Task { [weak self] in
            let affected = await Task.detached(priority: .utility) { () -> [String] in
                var affected: [String] = []
                for candidate in candidates {
                    if Task.isCancelled { return [] }
                    // PDF/EPUBはファイル自身のページ順なので、設定で先頭は変わらない。
                    guard !candidate.isDocument else { continue }
                    guard let pages = await cachedPageList(candidate.bookID), !pages.isEmpty else {
                        affected.append(candidate.bookID)
                        continue
                    }
                    var before = candidate.snapshot
                    before.usesFinderOrder = !newValue
                    var after = candidate.snapshot
                    after.usesFinderOrder = newValue
                    let oldFirst = CoverImageResolver.firstPage(of: pages, pageOrderSource: .fileName, snapshot: before)
                    let newFirst = CoverImageResolver.firstPage(of: pages, pageOrderSource: .fileName, snapshot: after)
                    if oldFirst?.sortKey != newFirst?.sortKey { affected.append(candidate.bookID) }
                }
                return affected
            }.value
            guard !Task.isCancelled, let self else { return }
            self.refreshCovers(forBookIDs: affected)
        }
    }

    /// 表紙を出したまま、これらの本のカバーを作り直す(handlePageOrderSettingChangeのコメント)。
    private func refreshCovers(forBookIDs bookIDs: [String]) {
        var items: [CollectionItem] = []
        for bookID in bookIDs {
            for item in collectionStore.items(forBookID: bookID) where item.coverState == .ready {
                if inFlightItemIDs.contains(item.id) {
                    redoAfterExtraction.insert(item.id)
                } else {
                    items.append(item)
                }
            }
        }
        enqueue(items)
    }

    /// 並び順の設定の判定が終わるまで待つ(**テストのための口**)。
    func settlePageOrderEvaluation() async {
        await pageOrderEvaluation?.value
    }

    // MARK: - カバー画像と表紙の分離(2026-09-11の一度きりの移行)

    /// 分離前に「カバー画像」として保存されていた指定を、コレクション表紙へ引き取る
    /// (LayoutStore.migrateCoverSeparationのコメントに、何をどちらへ寄せるかを書いてある)。
    ///
    /// ■ 抽出はし直さない
    /// 外部ファイル指定だった本の表紙の元画像として渡すのは、**その本の
    /// `CollectionCovers/<itemID>.jpg`そのもの** ―― 分離前から棚に出ていた絵だ。元ファイルは
    /// 実測で131冊すべて失われており、この768pxのJPEGがその絵の最後の1枚になっている。
    /// 焼き直さずにバイトのまま保管庫へ複製し(CollectionCoverSourceStore.storeCopy)、
    /// `CollectionCovers`側には指一本触れない ―― 棚の見え方は1枚も変わらず、JPEGの世代も
    /// 増えない。
    ///
    /// ■ 取りこぼしたら次の起動でやり直す
    /// まだ抽出できていない(`.pending`)本は複製元が無い。その1冊のために移行全体を諦めるのは
    /// もったいないので、**1冊でも取りこぼしたときだけ**済み印を立てずに戻る(既に引き取った
    /// 本は`hasShelfCoverOverride`で飛ばされるので、やり直しても二重には入らない)。
    ///
    /// キーが`qooViewer.pref.`で始まらないのはmigrateCoverStorageIfNeededと同じ理由
    /// (環境設定の「初期設定に戻す」で消えると、移行がもう一度走ってしまう)。
    private func migrateShelfCoverSeparationIfNeeded() {
        let key = "qooViewer.collections.shelfCoverSeparation"
        guard !defaults.bool(forKey: key) else { return }

        var didSkip = false
        let sourceStore = layoutStore.coverSourceStore
        let result = layoutStore.migrateCoverSeparation { [collectionStore, coverStore] bookID in
            for item in collectionStore.items(forBookID: bookID) {
                let source = coverStore.url(for: item.id)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                if let storedName = try? sourceStore.storeCopy(of: source) {
                    return storedName
                }
            }
            didSkip = true
            return nil
        }
        // 行のフェッチ・保存に失敗したときも済み印を立てない(LayoutStore.migrateCoverSeparationの
        // 戻り値のコメント参照)。
        if !didSkip, result.completed {
            defaults.set(true, forKey: key)
        }
        if result.images + result.pages > 0 || didSkip || !result.completed {
            NSLog(
                "%@",
                "qooViewer: shelf cover separation migrated images=\(result.images) "
                    + "pages=\(result.pages) skipped=\(didSkip) completed=\(result.completed)"
            )
        }
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

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
/// - 撤去した環境設定「並び順をFinderに揃える」をOFFで使っていた人の、**実効1ページ目が変わる本**
///   → 起動時に一度だけ。表紙を指定していない本だけが対象で、**表紙を出したまま**裏で作り直す
///     (refreshCoversForRetiredOrderSettingIfNeeded)。設定があった間は切り替えのたびに同じ判定を
///     していた(ユーザー要望 2026-09-13)。
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
    /// `cancelAll()`で取り消した直近のループ。取り消しても、走っていた抽出は読み込みの await から戻ってくるまで終わらない ――
    /// `waitUntilIdle()`がそこまで待てるように持っておく(**テストのための口**)。
    private var lastCancelledTask: Task<Void, Never>?
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
    /// 終わったらもう一度積む(refreshCoversForRetiredOrderSettingIfNeeded)。
    private var redoAfterExtraction: Set<UUID> = []
    /// 撤去した並び順の設定の後始末の判定(ページ一覧のキャッシュを読む)。
    private var pageOrderEvaluation: Task<Void, Never>?
    /// 表紙の読み込みを始める直前に呼ぶ(**テストのための口**)。「抽出の最中にライブラリ機能を OFF にする」を、時間に頼らずに起こす。
    var willLoadCoverImageForTesting: (@MainActor () async -> Void)?
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

    /// ライブラリ機能が有効か(環境設定「ライブラリを有効にする」。AppStores.applyLibraryFeature)。OFFの間は**何も抽出せず、待ち行列にも
    /// 積まない**。起動時の下ごしらえ(移行・登録済みの全冊の控え取り ―― 全件フェッチを伴う)も、最初にONになるまで先送りする
    /// (`prepareIfNeeded`)。
    ///
    /// ■ OFFの間に表紙の指定が変わった本(`booksChangedWhileDisabled`)
    /// コレクション表紙の指定は、ライブラリ機能がOFFでも変えられる(ファイルブラウザの「メタデータの編集…」・表紙の読み込み。
    /// 指定はファイルブラウザのアイコンにも使う)。OFFの間は控え(`signatures`)が無く、届いた通知が表紙に関わる変更かどうかを
    /// 判定できないので、**レイアウトが変わった本のパスだけ**を覚えておき、ONへ戻ったときにその本の表紙を作り直す(関係ない
    /// 変更のぶんも作り直すが、やらずに古い表紙を残すよりよい)。アプリを終えても失わないよう UserDefaults に置く。
    /// 多すぎるとき(`maxBooksChangedWhileDisabled` 超)は覚えるのをやめ、ONへ戻ったときに全冊を作り直す。
    ///
    /// **控えから外すのは、その本の抽出が終わってから**(`redoRemainingByBookID`)。最初の版は ON へ戻した時点で控えを消してから
    /// 待ち行列へ積んでいたので、作り直しの途中でもう一度 OFF にする(`cancelAll`が行列を捨てる)かアプリを終えると、残りの本は
    /// `.ready`のまま古い表紙で残り、`signatures`も今の値になっているので二度と拾われなかった(2026-09-21 の監査の L1)。
    /// 取り消されずに終わった抽出は、結果に関わらず(見つからない・書けなかったも含めて)済みと数える ―― 数えないと、届かない本の
    /// ぶんだけ起動や切り替えのたびに作り直しが繰り返される。
    private(set) var isLibraryFeatureEnabled: Bool
    private var didPrepare = false
    static let booksChangedWhileDisabledKey = "qooViewer.collections.booksChangedWhileLibraryDisabled"
    static let changedTooManyWhileDisabledKey = "qooViewer.collections.changedTooManyWhileLibraryDisabled"
    static let maxBooksChangedWhileDisabled = 500
    /// OFF の間に変わった本の作り直しで、まだ抽出が終わっていない登録(item → 本)と、本ごとの残りの数(`isLibraryFeatureEnabled`のコメント)。
    private var redoBookIDByItemID: [UUID: String] = [:]
    private var redoRemainingByBookID: [String: Int] = [:]

    private var observers: [NSObjectProtocol] = []
    /// 存在確認の結果が変わったら待ち行列を組み直す(型コメント「実体が見つからない本」参照)。
    private var existenceCancellable: AnyCancellable?

    init(
        collectionStore: CollectionStore,
        coverStore: CollectionCoverStore,
        layoutStore: LayoutStore,
        cachesPageList: Bool = true,
        defaults: UserDefaults = .standard,
        cachedPageList: @escaping @Sendable (String) async -> [BookPageListCache.Entry.Page]? = {
            await BookPageListCache.shared.pageList(forBookID: $0)?.pages
        },
        isLibraryFeatureEnabled: Bool = true
    ) {
        self.isLibraryFeatureEnabled = isLibraryFeatureEnabled
        self.collectionStore = collectionStore
        self.coverStore = coverStore
        self.layoutStore = layoutStore
        self.cachesPageList = cachesPageList
        self.defaults = defaults
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
        // 一時的な理由で見送ったitemを、戻ってきた時点で積み直す(deferredItemIDsのコメント参照)。
        let activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLibraryFeatureEnabled, !self.deferredItemIDs.isEmpty else { return }
                self.deferredItemIDs.removeAll()
                self.refill()
            }
        }
        observers = [layoutObserver, collectionsObserver, activationObserver]
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

        // ライブラリ機能がOFFなら、下ごしらえは最初にONになるまで先送り(isLibraryFeatureEnabledのコメント)。
        if isLibraryFeatureEnabled { prepareIfNeeded() }
    }

    /// 起動時の下ごしらえ(1回だけ)。
    private func prepareIfNeeded() {
        guard !didPrepare else { return }
        didPrepare = true
        // **控えを取る前に**分離の移行を済ませる ―― 移行はshelfCover*の列を書き換えるので、
        // 先に控えを取ると「移行によって変わった」ことを変更と見なして全件抽出し直してしまう。
        migrateShelfCoverSeparationIfNeeded()

        // 既に登録済みの本(前回の起動で抽出を終えているもの)の条件を先に控えておく
        // (signaturesのコメント参照)。
        seedSignatures(for: collectionStore.allRegisteredBookIDs())

        migrateCoverStorageIfNeeded()
        refreshCoversForRetiredOrderSettingIfNeeded()
        redoCoversChangedWhileDisabled()
    }

    /// ライブラリ機能のON/OFF(`isLibraryFeatureEnabled`のコメント)。OFFにしたら走っている抽出も含めて全部やめる
    /// (やめた本は`.pending`のまま残り、ONへ戻ったときの`refill()`が拾う ―― 走っていた抽出を`.pending`のまま置くのは
    /// `extract(itemID:)`の読み込みの直後の確認)。
    func setLibraryFeatureEnabled(_ isEnabled: Bool) {
        guard isEnabled != isLibraryFeatureEnabled else { return }
        isLibraryFeatureEnabled = isEnabled
        if isEnabled {
            if didPrepare { redoCoversChangedWhileDisabled() } else { prepareIfNeeded() }
            refill()
        } else {
            cancelAll()
        }
    }

    /// OFFの間にレイアウトが変わった本の表紙を作り直す(`isLibraryFeatureEnabled`のコメント)。表紙は出したまま積む
    /// (refreshCoversForRetiredOrderSettingIfNeeded と同じ ―― `.pending`へ戻すと順番を待つ間ずっと下地になる)。
    /// 抽出に失敗していた(`.failed`)登録は`.pending`へ戻して積む(`CollectionStore.markFailedCoversPending`のコメント)。
    /// 控えはここでは消さない ―― 本ごとに抽出が終わった時点で外す(`noteRedoExtractionFinished`)。
    private func redoCoversChangedWhileDisabled() {
        let changedAll = defaults.bool(forKey: Self.changedTooManyWhileDisabledKey)
        let bookIDs = defaults.stringArray(forKey: Self.booksChangedWhileDisabledKey) ?? []
        guard changedAll || !bookIDs.isEmpty else { return }
        let targets = changedAll ? Array(collectionStore.allRegisteredBookIDs()) : bookIDs
        for bookID in targets { signatures[bookID] = signature(forBookID: bookID) }
        redoBookIDByItemID = [:]
        redoRemainingByBookID = [:]
        // 表紙を出している本を先に、まだ表紙の無い本(失敗から戻すぶんを含む)を後に積む。`.pending`の本は refill も拾うが、
        // 控えを外すのはここで数えたぶんの抽出が終わったときなので、同じく数に入れる。
        var ready: [CollectionItem] = []
        var others: [CollectionItem] = []
        for bookID in targets {
            for item in collectionStore.items(forBookID: bookID) {
                if item.coverState == .ready { ready.append(item) } else { others.append(item) }
            }
        }
        let items = ready + others
        for item in items where redoBookIDByItemID[item.id] == nil {
            redoBookIDByItemID[item.id] = item.bookID
            redoRemainingByBookID[item.bookID, default: 0] += 1
        }
        // 作り直す登録が 1 つも無い本(どのコレクションにも入っていない本。OFF の間はそれも覚えている)は、ここで済みにする。
        let finished = targets.filter { redoRemainingByBookID[$0] == nil }
        removeFromChangedWhileDisabled(finished)
        enqueue(ready)
        // 失敗から戻すのは積んだ後(戻した保存の通知が、その場で refill を呼んで`.pending`の本を積む)。
        collectionStore.markFailedCoversPending(forBookIDs: targets)
        enqueue(others)
    }

    /// 作り直しの抽出が 1 件終わった(取り消されずに)。その本の残りが無くなったら控えから外す。
    private func noteRedoExtractionFinished(itemID: UUID) {
        guard let bookID = redoBookIDByItemID.removeValue(forKey: itemID) else { return }
        let remaining = (redoRemainingByBookID[bookID] ?? 1) - 1
        guard remaining <= 0 else {
            redoRemainingByBookID[bookID] = remaining
            return
        }
        redoRemainingByBookID[bookID] = nil
        removeFromChangedWhileDisabled([bookID])
    }

    /// 控えから本を外す。作り直しが全部済んだら「全冊を作り直す」の印も下ろす。
    private func removeFromChangedWhileDisabled(_ bookIDs: [String]) {
        if !bookIDs.isEmpty, var list = defaults.stringArray(forKey: Self.booksChangedWhileDisabledKey) {
            let done = Set(bookIDs)
            list.removeAll { done.contains($0) }
            if list.isEmpty {
                defaults.removeObject(forKey: Self.booksChangedWhileDisabledKey)
            } else {
                defaults.set(list, forKey: Self.booksChangedWhileDisabledKey)
            }
        }
        if redoRemainingByBookID.isEmpty, defaults.bool(forKey: Self.changedTooManyWhileDisabledKey) {
            defaults.removeObject(forKey: Self.changedTooManyWhileDisabledKey)
        }
    }

    /// OFFの間に届いたレイアウトの変更を覚える(`isLibraryFeatureEnabled`のコメント)。
    private func rememberChangeWhileDisabled(bookID: String) {
        // テストの中で走る実物のアプリの抽出役には、テストのストアが出す通知も届く(通知はアプリ全体に飛ぶ)。
        // 開発機の本物の保存先へテストの本を書かない。
        guard !(RuntimeEnvironment.isRunningTests && defaults === UserDefaults.standard) else { return }
        guard !defaults.bool(forKey: Self.changedTooManyWhileDisabledKey) else { return }
        var bookIDs = defaults.stringArray(forKey: Self.booksChangedWhileDisabledKey) ?? []
        guard !bookIDs.contains(bookID) else { return }
        guard bookIDs.count < Self.maxBooksChangedWhileDisabled else {
            defaults.removeObject(forKey: Self.booksChangedWhileDisabledKey)
            defaults.set(true, forKey: Self.changedTooManyWhileDisabledKey)
            return
        }
        bookIDs.append(bookID)
        defaults.set(bookIDs, forKey: Self.booksChangedWhileDisabledKey)
    }

    /// アプリ自身が移した・名前を変えた本の控えを、新しいパスへ付け替える(BookRecordRelocator)。控えの中身はパスなので、付け替えないと
    /// ONへ戻したときの作り直しから漏れる(2026-09-21 の監査の D2)。Finder で移した本は、開いたときの`LayoutStore.reconcileBookIDIfMoved`が
    /// 新しいパスで通知を出すので、`rememberChangeWhileDisabled`が新しいほうも覚える。
    func relocateBooksChangedWhileDisabled(_ newBookIDByOld: [String: String]) {
        guard !newBookIDByOld.isEmpty else { return }
        // 作り直しの最中なら、抽出の残りの数も新しいパスへ(控えと同じ鍵で外せるように)。
        if !redoRemainingByBookID.isEmpty {
            for (itemID, bookID) in redoBookIDByItemID {
                if let new = newBookIDByOld[bookID] { redoBookIDByItemID[itemID] = new }
            }
            var remaining: [String: Int] = [:]
            for (bookID, count) in redoRemainingByBookID { remaining[newBookIDByOld[bookID] ?? bookID, default: 0] += count }
            redoRemainingByBookID = remaining
        }
        guard let bookIDs = defaults.stringArray(forKey: Self.booksChangedWhileDisabledKey) else { return }
        var seen: Set<String> = []
        let relocated = bookIDs.map { newBookIDByOld[$0] ?? $0 }.filter { seen.insert($0).inserted }
        guard relocated != bookIDs else { return }
        defaults.set(relocated, forKey: Self.booksChangedWhileDisabledKey)
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
        // ライブラリ機能がOFFの間は積まない(本は`.pending`のまま残り、ONへ戻ったときのrefill()が拾う)。
        guard isLibraryFeatureEnabled else { return }
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
        guard isLibraryFeatureEnabled else { return }
        refill(locations: collectionStore.locationByItemID)
    }

    /// - Parameter locations: 判定に使う実体確認の結果(CollectionStore.locationByItemID、
    ///   またはその投影から届いた新しい値)。まだ確認していない本は「ある」として扱う
    ///   (cachedFileExistsと同じ)。
    private func refill(locations: [UUID: BookLocation]) {
        guard isLibraryFeatureEnabled else { return }
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
        while let task = currentTask ?? lastCancelledTask {
            await task.value
            if lastCancelledTask == task { lastCancelledTask = nil }
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
        if let currentTask { lastCancelledTask = currentTask }
        currentTask = nil
        isRunning = false
        runGeneration &+= 1
        if !inFlightItemIDs.isEmpty { inFlightItemIDs = [] }
        // 作り直しの途中なら、残りは UserDefaults の控えに残っている(外すのは抽出が終わってから)。次に ON になったとき・次の起動で拾う。
        redoBookIDByItemID = [:]
        redoRemainingByBookID = [:]
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
                // 取り消された(`cancelAll()`で世代が進んだ)抽出は、後始末に触らない。
                guard extractor.runGeneration == generation else { break }
                // 抽出中に作り直しを頼まれていたら、もう一度積む(redoAfterExtractionのコメント)。
                if extractor.redoAfterExtraction.remove(itemID) != nil,
                   !extractor.queuedIDs.contains(itemID) {
                    extractor.queue.append(itemID)
                    extractor.queuedIDs.insert(itemID)
                }
                // OFF の間に変わった本の作り直しの控え(isLibraryFeatureEnabled のコメント)。積み直したぶんは、それが終わってから。
                if !extractor.queuedIDs.contains(itemID) {
                    extractor.noteRedoExtractionFinished(itemID: itemID)
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
        let snapshot = layoutStore.shelfCoverSnapshot(forBookID: bookID)
        let url = collectionStore.resolvedExistingURL(for: item)
        // ブックマークが解決できない・実体が無い本は`.pending`のまま置いて戻る
        // (型コメント「実体が見つからない本」参照)。`.failed`は本を開けなかったときだけ。
        //
        // **ただし、利用者が用意した画像を表紙にしている本は別**(2026-09-11) ―― その絵は
        // 保管庫(CollectionCoverSourceStore)にあり、本を1バイトも読まずに作れる。未接続の
        // 外付けボリューム上の本でも表紙は出せるので、ここで弾いてはいけない。
        guard url != nil || snapshot.imageFileURL != nil else { return }
        // `cancelAll()`で世代が進んだ後は、抽出中の印に触らない(もう空にしてあり、同じ本を次の世代が抽出し始めているかもしれない)。
        let generation = runGeneration
        inFlightItemIDs.insert(itemID)
        defer { if runGeneration == generation { inFlightItemIDs.remove(itemID) } }

        signatures[bookID] = signature(forBookID: bookID)

        await willLoadCoverImageForTesting?()
        let didAccess = url?.startAccessingSecurityScopedResource() ?? false
        let image = await CoverImageResolver.coverImage(
            bookAt: url, snapshot: snapshot,
            maxPixelSize: CollectionCoverStore.maxPixelSize, cachesPageList: cachesPageList
        )
        if didAccess { url?.stopAccessingSecurityScopedResource() }

        // 読み込みの最中に取り消された(`cancelAll()` ―― ライブラリ機能を OFF にした)なら、結果を見ずに`.pending`のまま置いて戻る。
        // 取り消しは`BookLoader.load`の中まで伝わって読み込みを投げさせるので、ここへは nil が返ってくる。確認が無かったころは
        // それを「本を開けなかった」と取り違えて`.failed`にし、表紙の指定を変えるまで灰色のままになった(2026-09-21 の監査
        // docs/plans/feature-toggle-audit.md の L1)。読めていた場合も、OFF の間に JPEG を書いて`.ready`にはしない。
        guard !Task.isCancelled, runGeneration == generation, isLibraryFeatureEnabled else { return }

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
        guard isLibraryFeatureEnabled else {
            rememberChangeWhileDisabled(bookID: bookID)
            return
        }
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

    /// 撤去した環境設定「並び順をFinderに揃える」を**OFFで使っていた人**の表紙を、起動時に一度だけ
    /// 今の並び(正準順)へ合わせる(2026-09-13)。
    ///
    /// ■ なぜ要るのか
    /// 設定があった間は、切り替えのたびにこの判定をして作り直していた(ユーザー要望 2026-09-13)。
    /// 設定を撤去すると、OFFだった人の表示順は黙って正準順へ変わる ―― 本の中身はその場で
    /// 並び直るが、保存してある表紙の絵は従来順の1ページ目のまま残る。そこで「OFFから正準順へ
    /// 切り替えた」のと同じ判定を1回だけ行う。値が未設定かONの人(既定)は何もしない。
    /// UserDefaultsの値そのものは消さない(PageOrder.retiredSettingKeyのコメント参照)。
    ///
    /// ■ 何を作り直すか
    /// 表紙を指定していない(= 実効1ページ目を表紙にしている)`.ready`の本のうち、**従来順と正準順で
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
    func refreshCoversForRetiredOrderSettingIfNeeded() {
        let doneKey = "qooViewer.collections.retiredOrderSettingCovers"
        guard defaults.object(forKey: PageOrder.retiredSettingKey) as? Bool == false,
              !defaults.bool(forKey: doneKey)
        else { return }
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
        // 済み印は**待ち行列へ積んだ時点で**立てる。積んだ抽出が終わる前にアプリを終えると
        // その本は古い表紙のまま残るが、そのために毎回の起動で全冊を判定し直すほうが高くつく。
        guard !candidates.isEmpty else {
            defaults.set(true, forKey: doneKey)
            return
        }
        let cachedPageList = cachedPageList
        pageOrderEvaluation = Task { [weak self] in
            let affected = await Task.detached(priority: .utility) { () -> [String] in
                var affected: [String] = []
                for candidate in candidates {
                    if Task.isCancelled { return [] }
                    // PDF/EPUBはファイル自身のページ順なので、名前の照合で先頭は変わらない。
                    guard !candidate.isDocument else { continue }
                    guard let pages = await cachedPageList(candidate.bookID), !pages.isEmpty else {
                        affected.append(candidate.bookID)
                        continue
                    }
                    var before = candidate.snapshot
                    before.usesLegacyOrder = true
                    let after = candidate.snapshot
                    let oldFirst = CoverImageResolver.firstPage(of: pages, pageOrderSource: .fileName, snapshot: before)
                    let newFirst = CoverImageResolver.firstPage(of: pages, pageOrderSource: .fileName, snapshot: after)
                    if oldFirst?.sortKey != newFirst?.sortKey { affected.append(candidate.bookID) }
                }
                return affected
            }.value
            guard !Task.isCancelled, let self else { return }
            self.refreshCovers(forBookIDs: affected)
            self.defaults.set(true, forKey: doneKey)
        }
    }

    /// 表紙を出したまま、これらの本のカバーを作り直す(refreshCoversForRetiredOrderSettingIfNeededのコメント)。
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

    /// 撤去した並び順の設定の後始末の判定が終わるまで待つ(**テストのための口**)。
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

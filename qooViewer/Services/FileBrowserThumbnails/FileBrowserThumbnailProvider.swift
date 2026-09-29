import Combine
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ファイルブラウザのアイコン表示の絵を配る窓口(改善要望7 段階 7a、2026-09-14)。アプリで 1 つ(AppStores)。
///
/// ■ どこから絵を持ってくるか(決定事項 Q5 の 2 段構え + コレクション表紙の指定)
/// 1. その本がコレクションに登録済みで表紙ができていれば、**その表紙**(CollectionCoverStore の JPEG)。棚と同じ絵で、
///    本は 1 バイトも読まない。ディスクキャッシュには入れない(表紙そのものがディスクにある)
/// 2. コレクション表紙を指定してある本(メタデータの編集で。**登録していない本でも**指定できる。2026-09-14、ユーザー要望 ――
///    同じ本の表紙の絵がアプリの中に 2 種類あるのを避ける):
///    - 画像を指定 → 保管庫(CollectionCoverSourceStore)の画像をそのまま。本は読まない。ディスクキャッシュにも入れない
///    - 本の中のページを指定 → そのページを `CoverImageResolver` で作り、ページのキーを鍵に足してディスクキャッシュへ。
///      **登録済みの本では作らない**(抽出役がすぐ同じ絵を作るので、それまでは 3 の絵で待つ)
/// 3. 無ければディスクキャッシュ(FileBrowserThumbnailDiskCache)、それも無ければ `BookThumbnailer` で作ってキャッシュへ
///
/// 指定を変えたら(`.layoutDataDidChange`)、その本を絵にしたことがあれば頼み直させる(`shelfSignatures`)。
///
/// ■ メモリ
/// 復号した絵は `PagePixelCache`(厳密な LRU、96MB)に**表示の大きさの段ごと**に持つ。段は長辺 128 / 256 / 512px
/// (アイコンの大きさ 48〜256pt の Retina ぶん。上限の 450pt までは 512px を引き伸ばす ―― FileBrowserState.iconSizeRange)。セルへは使い捨ての CGImage(`makeImage()`)を渡す ―― CGImage を
/// キャッシュに抱えると、表示した絵が 3 倍のメモリを占め続ける(PagePixelBuffer の型コメント)。セルの側で残る絵は
/// `LazyCellImageBudget` で数える(LazyVGrid は画面外のセルの @State を手放さない)。
///
/// ■ 並べ方
/// 作る仕事は同時に `maxConcurrentJobs`(4)件まで。**ネットワーク越しの項目はそれとは別に `maxConcurrentRemoteJobs`(2)件まで**
/// (2026-09-14 の 2 回目の監査 18。枠が 1 つだったので、応答しない共有の 4 件で全ウインドウの絵が止まった ―― FileIO の上の読み取りは
/// 期限を付けても止められないので、塞がる枠を分けるしかない)。待っている仕事は**後から頼まれたものから**始める(スクロールすると
/// 画面に入ったばかりのセルが先に埋まる)。同じ絵を頼むセルが複数あれば 1 件にまとめる。頼んだセルが全部いなくなった
/// (`.task` が取り消された)仕事は、始まる前なら捨てる。始まった仕事は止めない(FileIO の上の読み取りは中断できない)
/// ―― 結果はキャッシュに入るので無駄にはならない。
///
/// ■ 作れなかった絵
/// 画像の無い書庫・壊れたファイル・読めない場所は、この起動の間は覚えて作り直さない(`failedKeys`。鍵に更新日時と
/// サイズを含むので、中身が変われば試し直す)。永続化しない ―― 外付けを抜いていただけ、は次の起動で直る。
/// 動画で絵を作れる QuickLook 拡張が無かった(mkv など)も同じで、拡張を入れたら次の起動から出る。
///
/// ■ 動画(段階 7b、2026-09-14)
/// `VideoThumbnailLoading`(既定は QuickLook → `hev1` の再タグ付け)で作り、本と同じディスクキャッシュ・同じ枠(4 件)に載せる。
/// 実体が手元に無いファイル(iCloud などに追い出されたもの)は作らない ―― 頼まれていないダウンロードを起こすので。
/// こちらは「作れなかった」とは覚えない(落としてくれば作れる)。本・画像・フォルダも同じ(`BookThumbnailer.make` が
/// `.notDownloaded` を返す。2026-09-14 の監査 6)。よく使う項目の中の動画を先に作っておくのは
/// `FileBrowserVideoThumbnailWarmer`(作ったものは同じディスクキャッシュに入り、ここはそれを読むだけ)。
///
/// ■ アプリケーション(2026-09-14、ユーザー要望)
/// `.app` は中の絵ではなく**アプリのアイコン**を `FileBrowserSystemIcon` で段の大きさに描く。ディスクキャッシュには入れない。記号リンク・
/// エイリアスは**先の項目そのものと同じ絵**(`aliasThumbnail`。本なら本棚の表紙か 1 ページ目、アプリなどは先のアイコン。2026-09-29)、
/// 矢印のバッジはセルが重ねる。
/// 読む場所の判断(ネットワーク・TCC)はフォルダと同じ。
///
/// ■ シークレットウインドウ(2026-09-14、ユーザー判断)
/// シークレットウインドウのセルは `savesToDisk: false` で頼み、**作った絵をディスクキャッシュへ書かない**(本のページの
/// サムネイルを書かないのと揃える。絵そのものが痕跡になる)。読むのは許す(何も残らない)。メモリの絵はアプリで共有する
/// (ディスクに残らない)ので、シークレットウインドウで作った絵を通常ウインドウがメモリから受け取ったときも書かない ――
/// 次の起動で作り直すだけ。同じ仕事を通常ウインドウのセルも待っていれば書く(`Job.savesToDisk` は待つセルの OR)。
@MainActor
final class FileBrowserThumbnailProvider: ObservableObject {
    /// 絵の出どころが変わった合図(コレクションの表紙ができた・変わった、キャッシュを消した)。セルの `.task(id:)` に
    /// 入れて、変わったら頼み直させる。メモリに残っていれば頼み直しは即座に返る。
    @Published private(set) var revision: UInt64 = 0
    /// 動画の絵を作るか(環境設定「動画のサムネイルを生成」の写し)。セルの種類の判定(`kind(for:...)`)に渡す。
    /// **アイコン表示に AppPreferences を観測させない**ために、ここに写して配る ―― AppPreferences はどの設定が変わっても
    /// 発火するので、観測するとグリッド全体の body がそのたびに作り直される。
    @Published private(set) var includesVideo = true
    private var preferencesSubscription: AnyCancellable?

    static let maxConcurrentJobs = 4
    static let maxConcurrentRemoteJobs = 2
    nonisolated static let memoryLimitBytes = 96 * 1024 * 1024

    /// 復号の大きさの段(長辺の画素)。
    static let pixelTiers: [CGFloat] = [128, 256, 512]

    /// 表示の大きさ(pt)から段を選ぶ。Retina ぶんの 2 倍を超えるいちばん小さい段(無ければ最大)。
    static func pixelTier(forDisplaySize points: CGFloat, scale: CGFloat = 2) -> CGFloat {
        let needed = points * scale
        return pixelTiers.first { $0 >= needed } ?? pixelTiers[pixelTiers.count - 1]
    }

    private let memory: PagePixelCache
    private let diskCache: FileBrowserThumbnailDiskCache
    /// 記号リンク・エイリアスの先を読んでよいかの規則に使う保護下の場所(`DirectoryProbe`)。**テストは空を渡す**(テストホストの一時
    /// フォルダはサンドボックスのコンテナ = `~/Library/Containers` の中で、既定の一覧では保護下)。
    private let protectedPrefixes: [String]
    private let categoryPrefixes: Set<String>
    private let videoLoader: any VideoThumbnailLoading
    private weak var collectionStore: CollectionStore?
    private let coverStore: CollectionCoverStore?
    private weak var layoutStore: LayoutStore?
    private var collectionSubscription: AnyCancellable?
    private var layoutObserver: NSObjectProtocol?

    /// コレクション表紙の指定の控え(本の id → 絵にしたときの指定)。`.layoutDataDidChange` で比べ、変わっていたら頼み直させる
    /// (レイアウトの通知はページの見開き指定など表紙と無関係な変更でも飛ぶ)。上限を超えたら丸ごと忘れる。
    private struct ShelfSignature: Equatable {
        var pageKey: String?
        var imageFileName: String?
    }
    private var shelfSignatures: [String: ShelfSignature] = [:]
    private static let shelfSignaturesLimit = 5000

    /// キャッシュを消した回数(`sourceKey` に入れて、消したらセルに頼み直させる)。
    private var purgeGeneration: UInt64 = 0

    /// 作れなかった絵(型コメント)。上限を超えたら丸ごと忘れる(試し直すだけで害は無い)。
    private var failedKeys: Set<String> = []
    private static let failedKeysLimit = 5000

    /// 1 件の仕事。同じ絵を待つセル(`waiters`)を束ねる。
    private final class Job {
        /// 段を含まない鍵(作れなかったことを覚える単位)。
        let baseKey: String
        let memoryKey: String
        let source: Source
        let pixelSize: CGFloat
        /// ネットワーク越しの項目(別の枠で走らせる)。
        let isRemote: Bool
        var waiters: [UUID: CheckedContinuation<PagePixelBuffer?, Never>] = [:]
        var isStarted = false
        /// 作った絵をディスクキャッシュへ書くか。待つセルのどれか 1 つでも通常ウインドウなら書く(型コメント「シークレットウインドウ」)。
        /// 書く直前に読むので、作っている最中に加わったセルの分も効く。
        var savesToDisk = false
        /// 呼び出し側が知っている、項目のディスクキャッシュの鍵(`thumbnail(for:...knownKey:)`)。あれば項目の今の状態を
        /// 読みに行かない。
        var knownKey: FileBrowserThumbnailKey?
        /// 利用者が見ているフォルダ(`thumbnail(for:...currentFolder:)`)。記号リンク・エイリアスの先を読んでよいかの判断に使う。
        var currentFolder: URL?

        init(baseKey: String, memoryKey: String, source: Source, pixelSize: CGFloat, isRemote: Bool) {
            self.baseKey = baseKey
            self.memoryKey = memoryKey
            self.source = source
            self.pixelSize = pixelSize
            self.isRemote = isRemote
        }
    }

    private enum Source {
        /// コレクションの表紙の JPEG・表紙に指定した画像(保管庫の中)。
        case cover(URL)
        /// 表紙に指定した本の中のページ(型コメント「どこから」の 2)。
        case shelfPage(URL, CoverImageResolver.OverrideSnapshot)
        /// 項目そのものから作る。
        case item(URL, BookThumbnailer.Kind)
    }

    private var jobs: [String: Job] = [:]
    /// 始まっていない仕事(末尾が新しい)。
    private var queue: [Job] = []
    private var runningCount = 0
    private var runningRemoteCount = 0

    /// 実際に絵を作った回数(**テストのための口**。キャッシュに当たったら数えない)。
    private(set) var generatedCount = 0
    /// ライブラリ機能が有効か(環境設定「ライブラリを有効にする」。AppStores.applyLibraryFeature)。OFFの間は**コレクションの表紙を照会しない**
    /// ―― 照会は登録した本の全件フェッチを引き起こす。本に指定したコレクション表紙(LayoutStore の側)はそのまま使う。
    private var isLibraryFeatureEnabled = true

    /// 切り替えたら頼み直させる(鍵が「表紙」と「項目」で変わる)。
    func setLibraryFeatureEnabled(_ isEnabled: Bool) {
        guard isEnabled != isLibraryFeatureEnabled else { return }
        isLibraryFeatureEnabled = isEnabled
        revision &+= 1
    }

    /// - Parameters:
    ///   - diskCache: 既定は実物のキャッシュ。**テストは一時フォルダのものを渡す。**
    ///   - collectionStore / coverStore: 表紙を探す相手。nil なら表紙を見ない(テスト)。
    ///   - layoutStore: コレクション表紙の指定を探す相手。nil なら指定を見ない(テスト)。
    ///   - videoLoader: 動画の絵の作り方。**テストは作り物を渡す**(実物は入っている QuickLook 拡張しだい)。
    ///   - protectedPrefixes / categoryPrefixes: 記号リンク・エイリアスの先の規則(`protectedPrefixes` のコメント)。
    init(
        diskCache: FileBrowserThumbnailDiskCache = .shared,
        collectionStore: CollectionStore? = nil,
        coverStore: CollectionCoverStore? = nil,
        layoutStore: LayoutStore? = nil,
        videoLoader: any VideoThumbnailLoading = CompositeVideoThumbnailLoader(),
        memoryLimitBytes: Int = FileBrowserThumbnailProvider.memoryLimitBytes,
        protectedPrefixes: [String] = DirectoryProbe.protectedPrefixes,
        categoryPrefixes: Set<String> = DirectoryProbe.categoryProtectedPrefixes
    ) {
        self.diskCache = diskCache
        self.protectedPrefixes = protectedPrefixes
        self.categoryPrefixes = categoryPrefixes
        self.videoLoader = videoLoader
        self.collectionStore = collectionStore
        self.coverStore = coverStore
        self.layoutStore = layoutStore
        memory = PagePixelCache(countLimit: 4000, totalCostLimit: memoryLimitBytes)
        // 表紙ができた・変わったら頼み直させる。`revision` はコレクションの変更のたびに進むので、ここでも間引かずに
        // 進める(メモリに残っている絵は即座に返るので、頼み直しは安い)。
        collectionSubscription = collectionStore?.$revision
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.revision &+= 1 }
            }
        if layoutStore != nil {
            layoutObserver = NotificationCenter.default.addObserver(
                forName: .layoutDataDidChange, object: nil, queue: .main
            ) { [weak self] notification in
                let bookID = notification.userInfo?["bookID"] as? String
                MainActor.assumeIsolated { self?.handleLayoutChange(bookID: bookID) }
            }
        }
    }

    deinit {
        if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver) }
    }

    /// 絵にしたことのある本の表紙の指定が変わったら頼み直させる(`shelfSignatures`)。
    private func handleLayoutChange(bookID: String?) {
        // bookID の無い知らせ(全削除・付け替え・読み込み)では、控えのある本を全部比べる(2026-09-22 の監査。以前は捨てていた)。
        guard let bookID else {
            for id in shelfSignatures.keys.sorted() where shelfSignatures[id] != shelfSignature(forBookID: id) {
                handleLayoutChange(bookID: id)
            }
            return
        }
        guard let previous = shelfSignatures[bookID] else { return }
        let current = shelfSignature(forBookID: bookID)
        guard current != previous else { return }
        shelfSignatures[bookID] = current
        revision &+= 1
    }

    private func shelfSignature(forBookID bookID: String) -> ShelfSignature {
        let settings = layoutStore?.bookLayoutSettings(forBookID: bookID)
        return ShelfSignature(pageKey: settings?.shelfCoverPageKey, imageFileName: settings?.shelfCoverImageFileName)
    }

    /// 環境設定の「動画のサムネイルを生成」を写し始める(AppStores が 1 度だけ呼ぶ)。
    func connect(preferences: AppPreferences) {
        preferencesSubscription = preferences.$fileBrowserVideoThumbnailsEnabled
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                MainActor.assumeIsolated { self?.includesVideo = isEnabled }
            }
    }

    // MARK: - 頼む

    /// この項目の絵を作る必要があるか(作れる種類か)。無ければセルは種類のアイコンのまま。
    ///
    /// フォルダは**中を読む**ので、次の場所では作らない:
    /// - ネットワーク越しのボリューム(セルの数だけ往復する。ツリーの三角と同じ判断)
    /// - TCC の保護下の場所(ホームを開いただけで「デスクトップ」の中を読むと許可のダイアログが出る)。ただし
    ///   デスクトップ・書類・ダウンロードの**中を見ている**ときの、同じ場所の中のフォルダは読む(許可は場所ごとに済んでいる。
    ///   `DirectoryProbe.categoryProtectedPrefixes`)
    ///
    /// - Parameter includesVideo: 環境設定「動画のサムネイルを生成」。OFF なら動画は種類のアイコンのまま。
    static func kind(
        for entry: FileBrowserEntry, currentFolder: URL?, mountTable: MountTable, includesVideo: Bool = true,
        protectedPrefixes: [String] = DirectoryProbe.protectedPrefixes,
        categoryPrefixes: Set<String> = DirectoryProbe.categoryProtectedPrefixes
    ) -> BookThumbnailer.Kind? {
        guard !entry.isVolume,
              let kind = BookThumbnailer.kind(
                forName: entry.url.lastPathComponent, isNavigableFolder: entry.isNavigableFolder,
                isPackage: entry.isPackage, isSymbolicLink: entry.isSymbolicLink, isAliasFile: entry.isAliasFile,
                includesVideo: includesVideo
              )
        else { return nil }
        switch kind {
        case .folder, .application:
            // フォルダは中を、アプリケーションはバンドルの中(アイコン)を読むので、同じ場所の判断をする。
            guard DirectoryProbe.mayReadUnentered(
                entry.url, from: currentFolder, mountTable: mountTable, prefixes: protectedPrefixes, categoryPrefixes: categoryPrefixes
            ) else { return nil }
        case .alias:
            // リンク自身を読む(readlink・エイリアスのファイル)ので、ネットワーク越しなら読まない。**先**を読んでよいかは、先を
            // 決めた後に描く側が同じ規則で見る(`FileBrowserSystemIcon.renderAlias`)。
            if mountTable.isRemote(entry.url) { return nil }
        default:
            break
        }
        return kind
    }

    /// 絵を返す。作れなければ nil。呼び出し側(セルの `.task`)が取り消されたら nil で戻る。
    ///
    /// - Parameters:
    ///   - pixelSize: `pixelTier(forDisplaySize:)` の段。
    ///   - savesToDisk: 作った絵をディスクキャッシュへ書くか。**シークレットウインドウは false**(型コメント)。
    ///   - knownKey: 項目のディスクキャッシュの鍵を呼び出し側が知っているなら渡す(スマートライブラリ。フォルダを探したときに
    ///     記録した鍵 ―― 2026-09-22)。渡せば、キャッシュを引く前に項目を lstat しない。**ネットワークの本では 1 冊ごとに
    ///     サーバーとの往復だった**ので、保存した一覧を出した直後に表紙が 1 枚ずつ遅れて出た(つながっていなければ出なかった)。
    ///     古い鍵なら古い絵が出るだけで、呼び出し側が探し直して鍵を新しくすれば描き直される。
    ///   - currentFolder: 利用者が見ているフォルダ(`kind(for:currentFolder:...)` に渡したもの)。記号リンク・エイリアスの先が
    ///     デスクトップ等の中なら、同じ場所の中を見ているときだけ読む。nil(「最近の項目」「コンピュータ」)なら保護下の先は読まない。
    func thumbnail(
        for entry: FileBrowserEntry, kind: BookThumbnailer.Kind, pixelSize: CGFloat, savesToDisk: Bool = true,
        knownKey: FileBrowserThumbnailKey? = nil, currentFolder: URL? = nil
    ) async -> PagePixelBuffer? {
        if kind == .alias {
            return await aliasThumbnail(for: entry, pixelSize: pixelSize, savesToDisk: savesToDisk, currentFolder: currentFolder)
        }
        let (baseKey, source) = resolveSource(for: entry, kind: kind)
        return await pixels(
            baseKey: baseKey, source: source, itemURL: entry.url, pixelSize: pixelSize, savesToDisk: savesToDisk,
            knownKey: knownKey, currentFolder: currentFolder
        )
    }

    /// 出どころが決まった絵を、メモリ → 仕事(同じ絵を待つセルを束ねる)の順で返す(`thumbnail(for:...)` の後半)。
    private func pixels(
        baseKey: String, source: Source, itemURL: URL, pixelSize: CGFloat, savesToDisk: Bool,
        knownKey: FileBrowserThumbnailKey?, currentFolder: URL?
    ) async -> PagePixelBuffer? {
        guard !failedKeys.contains(baseKey) else { return nil }
        let memoryKey = "\(baseKey)|\(Int(pixelSize))"
        if let cached = memory.object(forKey: memoryKey as NSString) { return cached }

        let job: Job
        if let existing = jobs[memoryKey] {
            job = existing
        } else {
            // 表紙(アプリの中の保管庫)はネットワークに無い。項目そのもの・指定したページは項目の場所で決める(マウント表はファイルシステムに触れない)。
            let isRemote: Bool
            switch source {
            case .cover: isRemote = false
            case .shelfPage, .item: isRemote = MountTable.current().isRemote(itemURL)
            }
            job = Job(baseKey: baseKey, memoryKey: memoryKey, source: source, pixelSize: pixelSize, isRemote: isRemote)
            jobs[memoryKey] = job
            queue.append(job)
        }
        if savesToDisk { job.savesToDisk = true }
        if let knownKey, job.knownKey == nil { job.knownKey = knownKey }
        if let currentFolder, job.currentFolder == nil { job.currentFolder = currentFolder }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PagePixelBuffer?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    dropIfUnwanted(job)
                    return
                }
                job.waiters[waiterID] = continuation
                pump()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(waiterID, of: memoryKey) }
        }
    }

    // MARK: 記号リンク・エイリアス(2026-09-29)

    /// 記号リンク・エイリアスの先(絵にしたときのもの)。`aliasThumbnail` が先を解くたびに書き、`cachedThumbnail` / `sourceKey` /
    /// セルの描き方(`aliasTargetKind`)が読む。鍵はリンク自身の項目の鍵(`itemKey`)。上限を超えたら丸ごと忘れる。
    private struct AliasTarget {
        let entry: FileBrowserEntry
        /// 先の種類(`kind(for:)`)。nil は絵にしない先(ふつうのファイル・無い先)。
        let kind: BookThumbnailer.Kind?
        /// 先のアイコン(LaunchServices)で出す: 絵にしない種類か、中の絵が作れなかった(画像の無いフォルダ・壊れた本)。
        /// 直接置かれたフォルダは絵が無ければ種類のアイコンで済むが、リンクは自分の名前の種類が白紙なので先のアイコンを出す。
        let drawsIcon: Bool
        /// 中の絵(先の項目と共有)を出す先の種類。
        var pictureKind: BookThumbnailer.Kind? { drawsIcon ? nil : kind }
    }
    private var aliasTargets: [String: AliasTarget] = [:]
    private static let aliasTargetsLimit = 2000

    /// 先の絵が「中の絵」(本・画像・画像フォルダ・動画)か。それ以外(アプリ・その他・無い先・エイリアスのエイリアス)は先のアイコン。
    private static func drawsTargetPicture(_ kind: BookThumbnailer.Kind?) -> Bool {
        guard let kind else { return false }
        return kind != .application && kind != .alias
    }

    /// 記号リンク・エイリアスの先の絵。**先の項目そのものと同じ経路**で作る(ユーザーの要望 2026-09-29: 登録済みの本なら本棚と同じ表紙、
    /// 未登録なら 1 ページ目、画像・画像フォルダ・動画も直接置かれたときと同じ)。
    ///
    /// 1. 先を決める(`FileBrowserLinkResolver.backgroundTargetInfo`。触ってよい場所か段ごとに確かめる。FileIO の上、仕事の枠の外 ―― 枠の中で
    ///    先の仕事を待つと、枠がリンクの仕事で埋まったとき先の仕事が始まれず止まる)。断られたら nil で、失敗とは覚えない。
    /// 2. 先の種類を、先の項目が直接並んでいるときと同じ規則で決める(`kind(for:)`。先がデスクトップの中なら見ているフォルダ次第)。
    /// 3. 中の絵になる種類なら、先の項目として `thumbnail(for:)` を頼む ―― 出どころ(コレクションの表紙・表紙の指定・1 ページ目)、
    ///    メモリとディスクのキャッシュ、失敗の記憶、同じ絵の束ねが**先の項目と共有**される(同じ本が直接並ぶ場所と作り直さない)。
    ///    それ以外はリンク自身の鍵で先のアイコン(LaunchServices。アプリと同じ `.item(_, .application)`)。
    /// 矢印のバッジはどちらも**セルが重ねる**(`FileBrowserIconCellView`。絵に焼き込むと先と共有できない)。
    private func aliasThumbnail(
        for entry: FileBrowserEntry, pixelSize: CGFloat, savesToDisk: Bool, currentFolder: URL?
    ) async -> PagePixelBuffer? {
        let key = Self.itemKey(for: entry)
        let mountTable = MountTable.current()
        let url = entry.url
        let (protectedPrefixes, categoryPrefixes) = (protectedPrefixes, categoryPrefixes)
        guard let info = await FileIO.perform({
            FileBrowserLinkResolver.backgroundTargetInfo(
                of: url, currentFolder: currentFolder, mountTable: mountTable,
                protectedPrefixes: protectedPrefixes, categoryPrefixes: categoryPrefixes
            )
        }) else { return nil }
        let targetEntry = info.entry
        let targetKind = info.exists
            ? Self.kind(
                for: targetEntry, currentFolder: currentFolder, mountTable: mountTable, includesVideo: includesVideo,
                protectedPrefixes: protectedPrefixes, categoryPrefixes: categoryPrefixes
            )
            : nil
        func remember(drawsIcon: Bool) {
            if aliasTargets.count >= Self.aliasTargetsLimit { aliasTargets.removeAll() }
            aliasTargets[key] = AliasTarget(entry: targetEntry, kind: targetKind, drawsIcon: drawsIcon)
        }
        if let targetKind, Self.drawsTargetPicture(targetKind) {
            remember(drawsIcon: false)
            if let picture = await thumbnail(
                for: targetEntry, kind: targetKind, pixelSize: pixelSize, savesToDisk: savesToDisk, currentFolder: currentFolder
            ) {
                return picture
            }
            // 中の絵が無い(画像の無いフォルダ・壊れた本 ―― 先の項目の失敗として覚えられている)。先のアイコンで出す。
        }
        remember(drawsIcon: true)
        // 先のアイコン。ディスクには入れない(アプリのアイコンと同じ)ので savesToDisk は要らない。
        return await pixels(
            baseKey: key, source: .item(info.url, .application), itemURL: entry.url, pixelSize: pixelSize, savesToDisk: false,
            knownKey: nil, currentFolder: currentFolder
        )
    }

    /// 記号リンク・エイリアスの先の種類(絵にしたときのもの。セルが絵の描き方 ―― ページの影・フォルダの上に重ねる ―― を決める)。
    /// まだ解いていなければ nil。先のアイコンで出すもの(アプリ・その他)は `.application`。
    func aliasTargetKind(for entry: FileBrowserEntry) -> BookThumbnailer.Kind? {
        guard let target = aliasTargets[Self.itemKey(for: entry)] else { return nil }
        return target.pictureKind ?? .application
    }

    /// 項目そのものの鍵(パス・更新日時・大きさ)。
    private static func itemKey(for entry: FileBrowserEntry) -> String {
        let modified = entry.modificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "item|\(entry.id)|\(modified)|\(entry.fileSize ?? -1)"
    }

    /// `thumbnail(for:kind:pixelSize:...)` の**メモリだけを見る**同期版。無ければ nil(作らない・ディスクもネットワークも読まない)。
    ///
    /// 2026-09-27、表示の切り替えの監査: ホームは本を開いている間は捨てられ、戻るとスマートライブラリのセル・アイコン表示の
    /// アイテムは絵を持たずに作り直される。絵がメモリに残っていても非同期の頼みが返るまでの数フレームはスピナー・種類のアイコンが
    /// 見え、戻るたびに表紙が一斉に点滅していた。作り直したセルは最初にこれを引き、当たれば最初のフレームから絵を描く。
    /// 出どころの判定(`resolveSource`)はセルが body で読む `sourceKey` と同じ仕事(メモリ上の索引を引くだけ)で、
    /// キャッシュはロック 1 回の辞書引きなので、メインから呼んでよい。
    func cachedThumbnail(for entry: FileBrowserEntry, kind: BookThumbnailer.Kind, pixelSize: CGFloat) -> PagePixelBuffer? {
        if kind == .alias {
            // 先を解いたことがあれば、先の項目の絵(共有)か、リンク自身の鍵の先のアイコン。
            let key = Self.itemKey(for: entry)
            guard let target = aliasTargets[key] else { return nil }
            if let pictureKind = target.pictureKind {
                return cachedThumbnail(for: target.entry, kind: pictureKind, pixelSize: pixelSize)
            }
            return memory.object(forKey: "\(key)|\(Int(pixelSize))" as NSString)
        }
        let (baseKey, _) = resolveSource(for: entry, kind: kind)
        guard !failedKeys.contains(baseKey) else { return nil }
        return memory.object(forKey: "\(baseKey)|\(Int(pixelSize))" as NSString)
    }

    /// この項目の絵の出どころを表す鍵(段は含まない)。**セルが「頼み直すか」を決めるのに使う。**
    ///
    /// `revision` はコレクションの変更のたびに(表紙を 1 冊抽出するたびにも)進むので、それだけを鍵にすると、見えている
    /// すべてのセルが(全ウインドウで)頼み直し・使い捨ての CGImage の作り直し・描き直しを表紙 1 枚ごとに繰り返していた
    /// (2026-09-25 の監査)。出どころ(表紙ができた・差し替わった、表紙の指定が変わった、ライブラリ機能の切り替え)が
    /// 変わったときだけ鍵が変わる。キャッシュを消した(`purgeMemory`)ときも変わる(`purgeGeneration`)。
    /// `revision` は今までどおり進む ―― セルはそれで描き直され、そのときこの鍵を読み直す。
    func sourceKey(for entry: FileBrowserEntry, kind: BookThumbnailer.Kind) -> String {
        // 記号リンク・エイリアスは先の出どころ(先の表紙ができた・変わったら頼み直す)。まだ解いていなければ自分の鍵。
        if kind == .alias, let target = aliasTargets[Self.itemKey(for: entry)], let pictureKind = target.pictureKind {
            return "alias|" + sourceKey(for: target.entry, kind: pictureKind)
        }
        return "\(resolveSource(for: entry, kind: kind).0)|\(purgeGeneration)"
    }

    /// 出どころと、段を含まない鍵(型コメント「どこから」)。表紙は項目の更新日時と無関係に、表紙の差し替え回数で鍵を変える。
    private func resolveSource(for entry: FileBrowserEntry, kind: BookThumbnailer.Kind) -> (String, Source) {
        let modified = entry.modificationDate?.timeIntervalSinceReferenceDate ?? 0
        let itemKey = Self.itemKey(for: entry)
        guard kind != .image, kind != .video, kind != .application, kind != .alias else { return (itemKey, .item(entry.url, kind)) }
        let items = isLibraryFeatureEnabled ? (collectionStore?.items(forBookID: entry.id) ?? []) : []
        if let collectionStore, let coverStore, let item = items.first(where: { $0.coverState == .ready }) {
            let revision = collectionStore.coverRevision(for: item)
            return ("cover|\(item.id.uuidString)|\(revision)", .cover(coverStore.url(for: item.id)))
        }
        if let layoutStore {
            let signature = shelfSignature(forBookID: entry.id)
            if shelfSignatures.count >= Self.shelfSignaturesLimit { shelfSignatures.removeAll() }
            shelfSignatures[entry.id] = signature
            if let fileName = signature.imageFileName, let url = layoutStore.coverSourceStore.url(forFileName: fileName) {
                return ("shelfImage|\(fileName)", .cover(url))
            }
            if let pageKey = signature.pageKey, items.isEmpty {
                return (
                    "shelfPage|\(entry.id)|\(modified)|\(entry.fileSize ?? -1)|\(pageKey)",
                    .shelfPage(entry.url, layoutStore.shelfCoverSnapshot(forBookID: entry.id))
                )
            }
        }
        return (itemKey, .item(entry.url, kind))
    }

    private func cancelWaiter(_ waiterID: UUID, of memoryKey: String) {
        guard let job = jobs[memoryKey], let continuation = job.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(returning: nil)
        dropIfUnwanted(job)
    }

    /// 待つセルがいなくなった、始まっていない仕事を捨てる。
    private func dropIfUnwanted(_ job: Job) {
        guard job.waiters.isEmpty, !job.isStarted else { return }
        jobs[job.memoryKey] = nil
        queue.removeAll { $0 === job }
    }

    private func pump() {
        // 空いている枠の仕事のうち、いちばん新しく頼まれたものから。
        while let index = queue.lastIndex(where: {
            $0.isRemote ? runningRemoteCount < Self.maxConcurrentRemoteJobs : runningCount < Self.maxConcurrentJobs
        }) {
            let job = queue.remove(at: index)
            job.isStarted = true
            if job.isRemote { runningRemoteCount += 1 } else { runningCount += 1 }
            Task { [weak self] in
                guard let self else { return }
                let result = await self.run(job)
                self.finish(job, result: result)
            }
        }
    }

    private func finish(_ job: Job, result: PagePixelBuffer?) {
        if job.isRemote { runningRemoteCount -= 1 } else { runningCount -= 1 }
        jobs[job.memoryKey] = nil
        if let result {
            memory.store(result, forKey: job.memoryKey as NSString)
        }
        let waiters = job.waiters
        job.waiters = [:]
        for continuation in waiters.values {
            continuation.resume(returning: result)
        }
        pump()
    }

    // MARK: - 作る

    private func run(_ job: Job) async -> PagePixelBuffer? {
        let pixelSize = job.pixelSize
        let baseKey = job.baseKey
        switch job.source {
        case .cover(let url):
            let pixels = await FileIO.perform { () -> PagePixelBuffer? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return ImageDecoder.decodePixels(data, maxPixelSize: pixelSize)
            }
            if pixels == nil { remember(failure: baseKey) }
            return pixels

        case .shelfPage(let url, let snapshot):
            // 表紙に指定したページ(型コメント「どこから」の 2)。本を丸ごと読むので重いが、指定した本だけ。
            guard let pageKey = snapshot.coverPageKey else { return nil }
            let mountTable = MountTable.current()
            let (fileKey, isDataless) = await FileIO.perform {
                (FileBrowserThumbnailKey.of(url, mountTable: mountTable), DatalessFiles.isDataless(url))
            }
            var key = fileKey
            key?.variant = "shelfPage:\(pageKey)"
            if let key, let data = await diskCache.data(for: key) {
                if let pixels = await Self.decode(data, maxPixelSize: pixelSize) { return pixels }
            }
            guard !isDataless else { return nil }
            generatedCount += 1
            guard let image = await CoverImageResolver.coverImage(
                bookAt: url, snapshot: snapshot, maxPixelSize: FileBrowserThumbnailDiskCache.maxPixelSize,
                // 読んだ本のページ一覧もディスクに残るので、シークレットウインドウだけの頼みでは書かない。
                cachesPageList: job.savesToDisk,
                // 表紙のページが追い出されていたら落としてこない。見分けが付かないので「作れなかった」として覚える(落としてきた後は次の起動で出る)。
                skipsNotDownloadedPages: true
            ) else {
                remember(failure: baseKey)
                return nil
            }
            let box = ImageBox(image: image)
            let made = await FileIO.perform { () -> (Data, PagePixelBuffer)? in
                guard let jpeg = Self.jpegData(from: box.image),
                      let pixels = ImageDecoder.decodePixels(jpeg, maxPixelSize: pixelSize)
                else { return nil }
                return (jpeg, pixels)
            }
            guard let made else {
                remember(failure: baseKey)
                return nil
            }
            if let key, job.savesToDisk { await diskCache.store(made.0, for: key) }
            return made.1

        case .item(let url, .application):
            // アプリのアイコン(FileBrowserSystemIcon)。LaunchServices がアイコンを覚えているので速く、
            // ディスクキャッシュには入れない(アプリを入れ替えたときに古い絵が残らないように)。
            generatedCount += 1
            let size = Int(pixelSize)
            let pixels = await FileIO.perform { FileBrowserSystemIcon.render(at: url, pixelSize: size) }
            if pixels == nil { remember(failure: baseKey) }
            return pixels

        case .item(_, .alias):
            // ここには来ない: 記号リンク・エイリアスは `aliasThumbnail` が先を解き、先の項目の出どころか `.item(先, .application)` で頼む。
            return nil

        case .item(let url, .video):
            let mountTable = MountTable.current()
            let (key, isDataless) = await FileIO.perform {
                (FileBrowserThumbnailKey.of(url, mountTable: mountTable), VideoThumbnailer.isDataless(url))
            }
            if let key, let data = await diskCache.data(for: key) {
                if let pixels = await Self.decode(data, maxPixelSize: pixelSize) { return pixels }
            }
            // 追い出されたファイルは作らない(型コメント)。「作れなかった」とも覚えない。
            guard !isDataless else { return nil }
            generatedCount += 1
            guard let jpeg = await Self.videoThumbnailJPEG(of: url, loader: videoLoader),
                  let pixels = await Self.decode(jpeg, maxPixelSize: pixelSize)
            else {
                remember(failure: baseKey)
                return nil
            }
            if let key, job.savesToDisk { await diskCache.store(jpeg, for: key) }
            return pixels

        case .item(let url, let kind):
            let key: FileBrowserThumbnailKey?
            if let knownKey = job.knownKey {
                key = knownKey
            } else {
                let mountTable = MountTable.current()
                key = await FileIO.perform { FileBrowserThumbnailKey.of(url, mountTable: mountTable) }
            }
            if let key, let data = await diskCache.data(for: key) {
                if let pixels = await Self.decode(data, maxPixelSize: pixelSize) { return pixels }
            }
            generatedCount += 1
            let made = await FileIO.perform { () -> MadeThumbnail in
                switch BookThumbnailer.make(of: url, kind: kind, maxPixelSize: FileBrowserThumbnailDiskCache.maxPixelSize) {
                case .image(let image):
                    guard let jpeg = Self.jpegData(from: image),
                          let pixels = ImageDecoder.decodePixels(jpeg, maxPixelSize: pixelSize)
                    else { return .failed }
                    return .made(jpeg: jpeg, pixels: pixels)
                case .unavailable:
                    return .failed
                case .notDownloaded:
                    return .notDownloaded
                }
            }
            switch made {
            case let .made(jpeg, pixels):
                if let key, job.savesToDisk { await diskCache.store(jpeg, for: key) }
                return pixels
            case .failed:
                remember(failure: baseKey)
                return nil
            case .notDownloaded:
                // 追い出されたファイル(型コメント「動画」と同じ)。「作れなかった」とは覚えない。
                return nil
            }
        }
    }

    /// 本・画像・フォルダの絵を作った結果(FileIO の上から持ち帰る)。
    private nonisolated enum MadeThumbnail: Sendable {
        case made(jpeg: Data, pixels: PagePixelBuffer)
        case failed
        case notDownloaded
    }

    /// 動画の絵を作ってディスクキャッシュに書く形(JPEG)にする。先に作っておく役(FileBrowserVideoThumbnailWarmer)も使う。
    @concurrent nonisolated static func videoThumbnailJPEG(of url: URL, loader: any VideoThumbnailLoading) async -> Data? {
        guard let image = await loader.makeThumbnail(
            for: url, maxPixelSize: Int(FileBrowserThumbnailDiskCache.maxPixelSize)
        ) else { return nil }
        let box = ImageBox(image: image)
        return await FileIO.perform { jpegData(from: box.image) }
    }

    /// CGImage を借りたスレッドへ渡す箱(作ったあとは誰も書き換えない)。
    private struct ImageBox: @unchecked Sendable {
        let image: CGImage
    }

    @concurrent private nonisolated static func decode(_ data: Data, maxPixelSize: CGFloat) async -> PagePixelBuffer? {
        ImageDecoder.decodePixels(data, maxPixelSize: maxPixelSize)
    }

    private func remember(failure baseKey: String) {
        if failedKeys.count >= Self.failedKeysLimit { failedKeys.removeAll() }
        failedKeys.insert(baseKey)
    }

    /// JPEG にする。**白地に描いてから**書く(JPEG は透明を持てず、透明な PNG の地が黒になる)。
    nonisolated static func jpegData(from image: CGImage) -> Data? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flattened = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, flattened,
            [kCGImageDestinationLossyCompressionQuality: FileBrowserThumbnailDiskCache.jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - キャッシュの削除

    /// メモリの絵と「作れなかった」の記憶を捨てて、セルに頼み直させる(環境設定でキャッシュを消したとき)。
    func purgeMemory() {
        memory.removeAll()
        failedKeys.removeAll()
        aliasTargets.removeAll()
        purgeGeneration &+= 1
        revision &+= 1
    }

    /// メモリの絵だけを手放す(ファイルブラウザ・スマートライブラリの両方を OFF にしたとき。AppStores)。どのセルも見えていない
    /// ので頼み直させない。ON に戻れば、ディスクキャッシュから引き直すだけ(2026-09-25 の監査 ―― 以前は OFF の間も
    /// 最大 96MB を抱えたままだった)。
    func releaseMemory() {
        memory.removeAll()
        aliasTargets.removeAll()
    }

    /// 仕事がすべて終わるまで待つ(**テストのための口**)。
    func waitUntilIdle() async {
        while runningCount > 0 || !queue.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

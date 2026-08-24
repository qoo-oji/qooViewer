import Foundation
import CoreGraphics

/// 1ページ分の画像ファイル情報(コンテキストメニュー「情報を見る」、ユーザー要望)。
/// PageLoader.pageImageInfo(at:)が、ピクセルデコードを伴わないヘッダー読み取りだけで
/// 組み立てる。PDFソースの場合はcolorModel/colorProfileName/hasAlphaChannel/fileSizeBytesが
/// 常にnilになる(独立した画像ファイルではなく、PDF自体の1ページのため。pageImageInfo(at:)の
/// コメント参照)。
struct PageImageInfo {
    let fileName: String
    /// 例: "JPEG"、"PDF"。
    let formatDescription: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// 例: "RGB"、"Gray"、"CMYK"。取得できない場合はnil。
    let colorModel: String?
    /// 画像ファイル自体のバイト数(アーカイブ内エントリは展開後のサイズ)。PDFはnil。
    let fileSizeBytes: Int64?
    /// ファイル(アーカイブ内エントリの場合はアーカイブファイル自体)が置かれている場所。
    /// アーカイブ内エントリでは、アーカイブファイルのフルパスにエントリのアーカイブ内
    /// フォルダパスを続けたもの(pageImageInfo(at:)のコメント参照)。取得できない場合はnil。
    let location: String?
    /// アーカイブ形式によっては取得できない(ArchiveReading.entryDates(at:)のコメント参照)。
    let createdDate: Date?
    let modifiedDate: Date?
    /// ICCカラープロファイル名(例: "sRGB IEC61966-2.1")。取得できない場合はnil。
    let colorProfileName: String?
    let hasAlphaChannel: Bool?
}

/// 1冊分のページ画像の読み込みを担当するactor。
///
/// - アーカイブの読み込み(ArchiveReading)はスレッドセーフではないため、
///   actorによる排他制御下でのみ触る。
/// - デコード自体(ImageDecoder.decode)はCPU負荷が高いため、actorの外の
///   バックグラウンドタスクで行い、他のページの読み込みリクエストをブロックしないようにする。
/// - 結果はPagePixelCache(上限付きの厳密なLRU)に保存する。上限を超えた分と、メモリが
///   逼迫したときは古いものから自動的に捨てるため、際限なくメモリを消費し続けない。
/// - 現在ページの前後を先読み(プリフェッチ)し、ページ送りの体感速度を上げる。
///   スクロールが速くて不要になった先読みはキャンセルする。
actor PageLoader {
    /// varなのは、updateBook(_:)でViewerViewModelから最新のbookを渡し直せるようにするため
    /// (詳細はupdateBook(_:)のコメント参照)。
    private var book: MangaBook

    /// 本単位で記憶されたコントラスト補正設定(BookLayoutSettings.contrastCorrectionEnabled)。
    /// trueの間、decodedImage(for:maxPixelSize:)がデコード直後の画像にContrastCorrector.applyを
    /// かける(カラーページの判定・除外自体はContrastCorrector側が行う)。ViewerViewModelの
    /// initで本を開いた時点の値を渡し、以後setContrastCorrectionEnabled(_:)で変更を反映する。
    private var contrastCorrectionEnabled: Bool

    private var readers: [String: ArchiveReading] = [:]
    /// PDFファイルごとにCGPDFDocumentを使い回す(アーカイブのreaders同様、actorの外から
    /// 同時に触られることはないため安全に直列化される)。
    private var pdfDocuments: [String: CGPDFDocument] = [:]
    /// 進行中の先読み。範囲外になったときに、ラッパーのTaskだけでなくその内側で走っている
    /// 実際の読み込み(inFlightTasks)も打ち切れるよう、対応するキーを一緒に覚えておく
    /// (cancellableInFlightKeysのコメント参照)。indexからその都度book.pagesを引いて求める
    /// 方式にしないのは、先読みを始めてから範囲外になるまでの間にupdateBook(_:)でページの
    /// 並びが変わりうるため。
    private struct PrefetchEntry {
        let task: Task<Void, Never>
        let inFlightKey: String
    }
    private var prefetchTasks: [Int: PrefetchEntry] = [:]
    /// 進行中の読み込み(アーカイブ展開+デコード)を、ページ+キャッシュの組ごとに覚えておく。
    /// 例えば先読み中のページへちょうどページ送りしたとき、先読みタスクの結果を待たずに
    /// 同じページをもう一度アーカイブ展開・デコードしてしまうと、無駄な二重作業になるうえ
    /// アーカイブ展開(actorで直列化される)が詰まって他のページの表示も遅れてしまう。
    /// そのため、同じページへの読み込みが既に進行中ならその結果を待ち合わせる(合流させる)。
    private var inFlightTasks: [String: Task<PagePixelBuffer?, Never>] = [:]

    /// inFlightTasksのうち、「prefetch(around:)が起点で始まり、まだ実際の表示要求が合流して
    /// いない」もののキー。この集合に含まれる読み込みだけは、途中で打ち切ってよい。
    ///
    /// バグ修正: image(at:)がinFlightTasks用に作る`Task { ... }`は非構造化タスクであり、
    /// **キャンセルを継承しない**(Swiftの仕様。実機相当の最小コードでも確認した)。そのため
    /// prefetch(around:)が先読み範囲から外れたタスクをcancel()しても、その内側で走っている
    /// decodedImage(for:maxPixelSize:)のTask.isCancelledは常にfalseのままで、
    /// 「スクロールが速くて不要になった先読みはキャンセルする」「表示されないとわかっている
    /// ページのデコードでCPUを使い切ってしまうのを防ぐ」という、このクラスが謳っている挙動は
    /// 実際にはimage(at:)冒頭の「まだ始めていない場合」にしか効いていなかった。
    ///
    /// 内側のタスクを直接cancel()すれば意図通りに効くが、そのタスクは同じページを要求した
    /// 他の呼び出しと共有される(dedup)ため、無条件に打ち切ると「実際に表示しようとしている
    /// ページ」の読み込みまで巻き込んでnilを返してしまう。そこで、打ち切ってよいのは
    /// 「先読みが始めた、かつ実表示の要求がまだ合流していない」ものだけに限定する。
    private var cancellableInFlightKeys: Set<String> = []

    /// pageSize(at:)の結果を、page.id(内容ベースの安定したキー。imageCacheと同じ)で覚えておく。
    ///
    /// pageSize(at:)はピクセルデコードこそ伴わないが、ヘッダーを読むためにrawData(for:)で
    /// 画像の生データを取り出す必要があり、アーカイブ本(zip/rar/7z)ではこれがエントリの
    /// 完全な展開になる(ZipArchiveReader.data(at:)参照)。一方、呼び出し元である
    /// ViewerViewModelの横長判定は、本を開いた直後の全ページ先読み判定
    /// (warmUpWideImageCacheForEntireBook)・表示のたびの周辺ページ判定(primeWideImageCache)・
    /// 自動レイアウト計算(wideImageAspectRatios)と、同じページへ複数の経路から到達しうる。
    /// 呼び出し側にもキャッシュ(wideImageCache)はあるが、あちらは判定結果(Bool)を持つもので、
    /// 複数の経路が同時に走った場合は同じページの展開が重複しうる。幅・高さはページの内容が
    /// 同じである限り不変なので、ここで素直に覚えておく。
    ///
    /// 画像本体と違いメモリをほとんど使わない(1ページあたり整数2つ)ため、NSCacheではなく
    /// 素のDictionaryでよい。コントラスト補正の切り替え(setContrastCorrectionEnabled)でも
    /// ピクセル寸法は変わらないため、そちらでは破棄しない。
    private var pageSizeCache: [String: (width: Int, height: Int)] = [:]

    /// 進行中のpageSize(at:)を、ページごとに覚えておく(image(at:)のinFlightTasksと同じ考え方)。
    /// pageSizeはactorの外へ処理を逃がすようになった=途中で中断点(await)を挟むため、同じページ
    /// への問い合わせが複数の経路(warmUpWideImageCacheForEntireBook / primeWideImageCache /
    /// wideImageAspectRatios)から重なると、キャッシュに入る前に二重に読み込みうる。
    private var inFlightPageSizeTasks: [String: Task<(width: Int, height: Int)?, Never>] = [:]

    /// 画像のヘッダー解析のために読む先頭バイト数。JPEGのSOFマーカー・PNGのIHDRチャンクなどは
    /// ファイル先頭のごく近くにあるが、EXIF/ICCプロファイルが大きい画像ではSOFがその後ろへ
    /// 押し出されるため、ある程度の余裕を持たせる。ここで足りずにヘッダーを読み取れなかった
    /// 場合は、呼び出し側がエントリ全体の読み込みへフォールバックする(pageSize/pageImageInfo参照)。
    private static let headerProbeByteCount = 128 * 1024

    // countLimitは64。環境設定の「先読みする画像数」は最大10まで設定できるため、
    // 前後合わせて最大22枚(2*10+見開きの2)が先読み対象になる。枚数の上限はその数倍の余裕を
    // 持たせ、実質的な上限はtotalCostLimit(メモリ量)に任せる。
    //
    // ■ 3つのキャッシュが持つのはCGImageではなくPagePixelBuffer
    // 以前はCGImage(をCGImageBoxに包んだもの)を入れていた。表示したCGImageが生きている限り
    // CoreAnimation側に同じ大きさのコピーが2つ残り続けるため、キャッシュの真のコストは
    // コスト計算の3倍になっていた(PagePixelBufferの型コメント参照)。ピクセルのバイト列だけを
    // 持ち、表示のたびに使い捨てのCGImageを作る形に変えてある。コストはbyteCount
    // (グレースケールなら1バイト/画素)で数えるので、上限の数字がそのままメモリの上限になる。
    //
    // totalCostLimitは環境設定「キャッシュ」の「メモリに残しておくページ画像」で決まる
    // (init / setImageCacheLimit参照)。
    //
    // ■ 3つともNSCacheではなくPagePixelCache(自前の厳密なLRU)
    // 以前はNSCacheだった。NSCacheは上限に達したときにどれを追い出すか約束せず、先読みした
    // ばかりの隣のページが追い出されて遠い古いページが残る現象を、サイドパネルのリソース
    // モニタで実際に観測した。また現在の合計コストも中身のキーも教えてくれないため、
    // モニタが「上限に対していま何MB・何枚」「前後何ページが残っているか」を出せなかった。
    // 詳細はPagePixelCacheの型コメント参照。
    private let imageCache = PagePixelCache(countLimit: 64)

    private let thumbnailCache = PagePixelCache(
        countLimit: 300,
        totalCostLimit: PageLoader.thumbnailCacheLimitBytes
    )

    /// ページ一覧(グリッド)専用のサムネイルキャッシュ。進捗バー用のthumbnailCache(固定240px)とは
    /// 別に持つ。グリッドはスライダーでセルを最大320ptまで拡大でき、その解像度は可変(セルの高さ×
    /// 画面倍率)。同じページでも要求サイズが違えば別物なので、キーにサイズを含める("id|px")。
    /// 1枚が大きくなりうるぶん、進捗バー用より枚数上限は控えめ・総容量は多めにしてある。
    private let gridThumbnailCache = PagePixelCache(
        countLimit: 200,
        totalCostLimit: PageLoader.gridThumbnailCacheLimitBytes
    )

    /// 進捗バー用サムネイル(thumbnailCache)の容量上限(約60MB)。リソースモニタが
    /// 「上限に対する実使用量」を出すために公開している。
    static let thumbnailCacheLimitBytes = 60 * 1024 * 1024
    /// 拡大サムネイル(gridThumbnailCache)の容量上限(約128MB)。同上。
    static let gridThumbnailCacheLimitBytes = 128 * 1024 * 1024

    /// サムネイルの永続キャッシュ(ThumbnailDiskCache)を引くためのキー。
    ///
    /// initでは作らず、最初に必要になった時点(thumbnailDiskKey()の呼び出し時)で作る。
    /// キーの生成にはソースファイルの更新日時・サイズの問い合わせ(stat)が伴い、
    /// PageLoaderのinitはactorのinitなので**呼び出し側のスレッド上で同期実行される**。
    /// ViewerViewModel.init / BookLayoutEditorViewModelはメインアクター上でPageLoaderを
    /// 作るため、initで問い合わせると、応答しないネットワークボリューム上の本を開いたときに
    /// メインスレッドがそのまま止まる。actorのメソッドの中ならメインアクターの外で動く。
    ///
    /// コントラスト補正を切り替えたら作り直す必要があるため、
    /// setContrastCorrectionEnabled(_:)でnilに戻す。
    private var cachedThumbnailDiskKeys: [CGFloat: ThumbnailDiskCache.BookKey] = [:]

    /// サムネイルのディスクキャッシュ(ThumbnailDiskCache)を読み書きするか。
    /// シークレットウインドウ(AppState.isPrivateWindow)で開いた本はfalseで、読みも書きもしない
    /// (読むだけでも、ヒットしたファイルの更新日時を触るため)。メモリ上のキャッシュは本を閉じれば
    /// 消えるので、そちらは通常どおり使う。
    private let usesThumbnailDiskCache: Bool

    /// - Parameter imageCacheLimitBytes: ページ画像のメモリキャッシュ(imageCache)の上限。
    ///   画面から作る場合は環境設定「キャッシュ」の値を渡す(AppPreferences.pageImageCacheLimitBytes)。
    ///   書き出し(CbzExporter/PDFExporter/EpubExporter)のように、ページキャッシュを実質使わず
    ///   環境設定にも触れられない(nonisolated)経路は既定値のままでよい。
    init(
        book: MangaBook,
        contrastCorrectionEnabled: Bool = false,
        usesThumbnailDiskCache: Bool = true,
        imageCacheLimitBytes: Int = Int(AppPreferences.defaultPageImageCacheLimitMB) * 1024 * 1024
    ) {
        self.book = book
        self.contrastCorrectionEnabled = contrastCorrectionEnabled
        self.usesThumbnailDiskCache = usesThumbnailDiskCache
        imageCache.totalCostLimit = imageCacheLimitBytes
    }

    /// リソースモニタ向けに、3つのメモリキャッシュの中身と先読みの状態をまとめて返す。
    /// キャッシュの中身を数えるだけで、画像には触れない。
    func cacheStatistics() -> PageCacheStatistics {
        return PageCacheStatistics(
            pageImages: imageCache.snapshot(),
            pageImageLimitBytes: imageCache.totalCostLimit,
            thumbnails: thumbnailCache.snapshot(),
            thumbnailLimitBytes: thumbnailCache.totalCostLimit,
            gridThumbnails: gridThumbnailCache.snapshot(),
            gridThumbnailLimitBytes: gridThumbnailCache.totalCostLimit,
            prefetchingIndices: Set(prefetchTasks.keys)
        )
    }

    /// 環境設定「メモリに残しておくページ画像」が変わったときにViewerViewModelから呼ぶ。
    /// 上限を下げるとその場で超過ぶんを追い出すので、効果は即座に出る。
    func setImageCacheLimit(bytes: Int) {
        imageCache.totalCostLimit = bytes
    }

    private func thumbnailDiskKey(maxPixelSize: CGFloat) -> ThumbnailDiskCache.BookKey {
        if let cached = cachedThumbnailDiskKeys[maxPixelSize] { return cached }
        // BookKeyの生成はファイルの更新日時・サイズの問い合わせ(stat)を伴うため、サイズごとに
        // 一度だけ作って使い回す(元は単一のキーをキャッシュしていた)。
        let key = ThumbnailDiskCache.BookKey(
            sourceURL: book.sourceURL,
            bookID: book.id,
            contrastCorrectionEnabled: contrastCorrectionEnabled,
            maxPixelSize: maxPixelSize
        )
        cachedThumbnailDiskKeys[maxPixelSize] = key
        return key
    }

    /// 本を閉じてこのPageLoaderが解放されるとき、まだ走っている読み込みを畳んでおく。
    ///
    /// 各タスクは[weak self]で自分を捕まえているため放置しても最終的には終わるが、それは
    /// 「次のチェックポイントまで進んでから」であり、それまでは表示されることのないページの
    /// アーカイブ展開・デコードにCPUとディスクI/Oを使い続けることになる(特に
    /// prefetch(around:)は最大21ページぶんを同時に抱えうる)。ここで明示的に打ち切る。
    deinit {
        for entry in prefetchTasks.values {
            entry.task.cancel()
        }
        for task in inFlightTasks.values {
            task.cancel()
        }
        for task in inFlightPageSizeTasks.values {
            task.cancel()
        }
    }

    /// 本を閉じた(または同じウインドウで別の本へ切り替えた)ときに、ViewerViewModelから呼ぶ。
    /// deinitと同じ後始末に加えて、3つのメモリキャッシュを空にする。
    ///
    /// deinitに任せてはいけない理由: 同じウインドウで次の本を開くと、SwiftUIが古いViewerViewの
    /// ノード(=その@StateObjectであるViewerViewModel、ひいてはこのPageLoader)を1世代ぶん
    /// 抱えたままにすることがある。実測では、前の本のPagePixelBufferが27枚(約840MB)そのまま
    /// 残り、サイドパネルのリソースモニタでも「2冊を表示中」と出ていた。
    /// 誰が参照を握っているかに関係なく中身だけは確実に空けるため、解放を「オブジェクトの寿命」
    /// ではなく「もう表示していない」という事実に紐づける
    /// (ViewerViewModel.releaseResources / ViewerView.handleOnDisappear参照)。
    ///
    /// ■ 解放後の要求は受け付けない(監査で指摘)
    /// releaseResources()はViewerViewModel側の走行中タスクも止めるが、それらは非構造化
    /// タスクで、既に`await pageImage(...)`から戻っていたものはキャンセルを見ずに
    /// `prefetch(around:)`まで進みうる。ここで`isReleased`を立て、以後の読み込み・先読みを
    /// すべて空振りにすることで、「解放したはずの旧世代のキャッシュが先読みで再び埋まる」
    /// (最大で設定上限ぶん)経路を確実に閉じる。
    ///
    /// ■ 書庫リーダー・CGPDFDocumentもここで閉じる
    /// deinitに任せると、SwiftUIが旧世代を抱えている間は書庫のファイルハンドル(7zなら索引の
    /// メモリも)が開きっぱなしになる。「もう表示していない」以上、これらも手放す。
    func releaseAllResources() {
        isReleased = true
        for entry in prefetchTasks.values {
            entry.task.cancel()
        }
        prefetchTasks.removeAll()
        for task in inFlightTasks.values {
            task.cancel()
        }
        for task in inFlightPageSizeTasks.values {
            task.cancel()
        }
        imageCache.removeAll()
        thumbnailCache.removeAll()
        gridThumbnailCache.removeAll()
        readers.removeAll()
        readerUsageOrder.removeAll()
        pdfDocuments.removeAll()
    }

    /// releaseAllResources()が呼ばれた後か。trueなら読み込み・先読みの入口はすべて何もせず
    /// nilを返す(上のコメント参照)。
    private var isReleased = false

    /// この本のコントラスト補正設定(本単位、BookLayoutSettings.contrastCorrectionEnabled)が
    /// 変わったときにViewerViewModelから呼ぶ。値が実際に変わった場合のみ、imageCache/
    /// thumbnailCacheを全消去する。既にキャッシュ済みの画像は変更前の設定で(補正あり/なしの
    /// いずれかに)デコード済みのため、消去して次回アクセス時に新しい設定で再デコードさせないと
    /// 表示に反映されない。呼び出し元(ViewerViewModel.reloadLayoutData)は、このメソッドの
    /// 完了後にloadCurrentSpread()を呼んで実際の再表示を行う想定。
    func setContrastCorrectionEnabled(_ enabled: Bool) {
        guard contrastCorrectionEnabled != enabled else { return }
        contrastCorrectionEnabled = enabled
        imageCache.removeAll()
        thumbnailCache.removeAll()
        gridThumbnailCache.removeAll()
        // 永続キャッシュ側は補正の有無をキーに含めているため、消す必要はない。キーを
        // 作り直すだけで、補正あり/なしそれぞれのサムネイルが別々に貯まる。
        cachedThumbnailDiskKeys.removeAll()
    }

    /// この本のページ構成(並び順・除外)が変わったとき、呼び出し元(ViewerViewModel)から
    /// 最新のbookを渡し直すために使う。ユーザー要望により、除外(非表示)・並べ替えの変更を
    /// この本を開き直さずに画像ビューアの表示へ即座に反映できるようにした
    /// (ViewerViewModel.reloadLayoutData参照)。
    ///
    /// 画像そのもののキャッシュ(imageCache/thumbnailCache)はpage.id(内容ベースの安定した
    /// キーで、並び順やインデックスには依存しない)をキーにしているため、ここでは無効化せず
    /// そのまま使い回せる。一方、index基準の参照(image(at:)/prefetch(around:)/
    /// rawImageData(at:))は、この呼び出し以降、新しいbook.pagesの並びに基づいて解決される
    /// ようになる。
    func updateBook(_ book: MangaBook) {
        self.book = book
    }

    /// 指定ページのフルサイズ画像を取得する(キャッシュ済みなら即座に、なければ読み込んでキャッシュする)
    func pageImage(at index: Int) async -> CGImage? {
        guard !isReleased else { return nil }
        return await pixels(at: index, cache: imageCache, maxPixelSize: ImageDecoder.pageMaxPixelSize)?.makeImage()
    }

    /// プログレスバー用の小さいサムネイルを取得する
    /// サムネイルは、メモリ上のthumbnailCacheに無ければ、まずローカルの永続
    /// キャッシュ(ThumbnailDiskCache)を見てから実デコードへ進む。
    ///
    /// これは「ブックマーク・レイアウトの編集」ウインドウのように、本を開き直すたびに
    /// PageLoaderごと作り直される画面のためのもの。本体が未接続の外付け/ネットワーク
    /// ボリューム上にあっても、2回目以降はローカルディスクから即座に返せる
    /// (詳細はThumbnailDiskCacheの型コメント参照)。
    func thumbnail(at index: Int) async -> CGImage? {
        guard !isReleased else { return nil }
        guard book.pages.indices.contains(index) else { return nil }
        let page = book.pages[index]
        let key = page.id as NSString

        if let cached = thumbnailCache.object(forKey: key) {
            return cached.makeImage()
        }

        guard usesThumbnailDiskCache else {
            return await pixels(
                at: index, cache: thumbnailCache, maxPixelSize: ImageDecoder.progressBarThumbnailMaxPixelSize
            )?.makeImage()
        }

        let diskKey = thumbnailDiskKey(maxPixelSize: ImageDecoder.progressBarThumbnailMaxPixelSize)
        if let fromDisk = await ThumbnailDiskCache.shared.thumbnail(bookKey: diskKey, pageID: page.id),
           let buffer = await Self.renderBuffer(from: fromDisk) {
            thumbnailCache.store(buffer, forKey: key)
            return buffer.makeImage()
        }

        let decoded = await pixels(
            at: index, cache: thumbnailCache, maxPixelSize: ImageDecoder.progressBarThumbnailMaxPixelSize
        )
        guard let decoded else { return nil }
        // 書き込みは待たない(次に同じページを要求されるまでに終わっていればよく、
        // 失敗しても次回またデコードするだけ)。
        let pageID = page.id
        Task.detached(priority: .background) {
            guard let image = decoded.makeImage() else { return }
            await ThumbnailDiskCache.shared.store(image, bookKey: diskKey, pageID: pageID)
        }
        return decoded.makeImage()
    }

    /// ページ一覧(グリッド)用のサムネイルを、指定した解像度(maxPixelSize)で返す。
    ///
    /// 進捗バー用のthumbnail(at:)が固定240pxなのに対し、こちらは呼び出し側(ThumbnailGridView)が
    /// セルの大きさ(高さ×画面倍率)から決めた解像度を渡す。スライダーでセルを大きくしたときに、
    /// 240pxを引き伸ばしてぼやけるのを避けるため(ユーザー報告)。
    ///
    /// 進捗バー用のパスや、フル画像(imageCache)・先読みには一切触らないよう、専用の
    /// gridThumbnailCacheと、サイズを含むキー・サイズ別のディスクキャッシュだけを使う。
    /// デコードはdecodedImage(for:maxPixelSize:)に委ねる(コントラスト補正のON/OFFも含めて、
    /// thumbnail(at:)/pageImage(at:)と同じ扱いになる)。
    ///
    /// - Parameter usesDiskCache: ディスクキャッシュ(ThumbnailDiskCache)を読み書きするか。
    ///   ホバー時の拡大プレビュー(最大1600px、PNGで1枚数MB)はfalseで呼ぶ。このサイズを
    ///   永続化すると、「表示中のサムネイルの拡大画像を先読み」で画面内のセル数ぶんのPNG
    ///   エンコードと書き込みがスクロールのたびに走り、既定200MBの上限では数十枚で、本来この
    ///   キャッシュが守りたい240px/セルサイズのサムネイルを刈り込んでしまう(監査で指摘)。
    ///   シークレットウインドウ(usesThumbnailDiskCache == false)ではこの値に関わらず使わない。
    func gridThumbnail(at index: Int, maxPixelSize: CGFloat, usesDiskCache: Bool = true) async -> CGImage? {
        guard !isReleased else { return nil }
        guard book.pages.indices.contains(index) else { return nil }
        let page = book.pages[index]
        let key = "\(page.id)|\(Int(maxPixelSize))" as NSString
        let usesDisk = usesThumbnailDiskCache && usesDiskCache

        if let cached = gridThumbnailCache.object(forKey: key) {
            return cached.makeImage()
        }

        // シークレットウインドウ(usesThumbnailDiskCache == false)ではディスクを読み書きしない。
        if usesDisk {
            let diskKey = thumbnailDiskKey(maxPixelSize: maxPixelSize)
            if let fromDisk = await ThumbnailDiskCache.shared.thumbnail(bookKey: diskKey, pageID: page.id),
               let buffer = await Self.renderBuffer(from: fromDisk) {
                gridThumbnailCache.store(buffer, forKey: key)
                return buffer.makeImage()
            }
        }

        guard let decoded = await decodedPixels(for: page.source, maxPixelSize: maxPixelSize), !isReleased else {
            return nil
        }
        gridThumbnailCache.store(decoded, forKey: key)
        if usesDisk {
            let diskKey = thumbnailDiskKey(maxPixelSize: maxPixelSize)
            let pageID = page.id
            // 書き込みは待たない(thumbnail(at:)と同じ考え方)。
            Task.detached(priority: .background) {
                guard let image = decoded.makeImage() else { return }
                await ThumbnailDiskCache.shared.store(image, bookKey: diskKey, pageID: pageID)
            }
        }
        return decoded.makeImage()
    }

    /// 生の画像データ(デコード前)を返す。EPUB書き出し(EpubExporter、7節)で、画質を落とさず
    /// 元の画像ファイルをそのまま複製するために使う。pageImage/thumbnailと異なりキャッシュは
    /// 行わない(書き出し中に一度読めば十分で、同じページへ二度アクセスすることが無いため)。
    /// PDFソースの場合は常にnil(PDFのページに「元の画像ファイル」という単位が無いため。
    /// PDFを書き出しの入力にする経路はexportableImage(at:)を使うこと)。
    func rawImageData(at index: Int) async -> Data? {
        guard book.pages.indices.contains(index) else { return nil }
        return rawData(for: book.pages[index].source)
    }

    /// 書き出し(EPUB)にそのまま使える画像データと、その拡張子。
    ///
    /// ユーザー要望により、EPUB書き出しの対象へ元がPDFの本も含めるようになったため、
    /// 「1ページ分の書き出し用データ」をソースの種類に依らず1つの窓口で得られるようにしたもの。
    /// - フォルダ・zip/cbz・rar/cbr・7z/cb7・EPUB: 元の画像ファイルのバイト列をそのまま返す
    ///   (拡張子も元のファイル名のもの)。
    /// - PDF: 埋め込まれている画像を取り出す(JPEGはそのまま、Flate等の可逆形式はPNGへ変換。
    ///   PDFImageExtractor参照)。JPEG/可逆形式以外が含まれる場合はエラーを投げる。
    ///
    /// 戻り値がnilになるのは、画像データを読み出せなかった場合(壊れた書庫など)。呼び出し側は
    /// 従来通りそのページを飛ばす。PDFで「対応していない画像形式」だった場合だけは、黙って
    /// 飛ばすとページが欠けたEPUBが出来上がってしまうため、エラーとして投げて書き出し自体を
    /// 失敗させる。
    func exportableImage(at index: Int) async throws -> (data: Data, fileExtension: String)? {
        guard book.pages.indices.contains(index) else { return nil }
        let page = book.pages[index]
        guard case .pdf(let pdfURL, let pdfPageIndex) = page.source else {
            guard let data = rawData(for: page.source) else { return nil }
            return (data, Self.fileExtension(forEntryPathOf: page))
        }
        guard let document = pdfDocument(for: pdfURL),
              let pdfPage = document.page(at: pdfPageIndex + 1)
        else { return nil }
        let extracted = try PDFImageExtractor.extractImageData(from: pdfPage, pageNumber: pdfPageIndex + 1)
        return (extracted.data, extracted.format.fileExtension)
    }

    /// exportableImage(at:)が返すであろう拡張子だけを、画像データを読まずに求める。
    ///
    /// EPUB書き出しは、実際に画像を書き込むより前に全ページ分のファイル名(=拡張子)を確定して
    /// package document(OPF)と目次を組み立てる必要があるため、その段階で使う。PDFの場合も
    /// 画像ストリームの辞書を読むだけで、画像本体の復号・コピーは行わない。
    ///
    /// PDFを開けない・そのページが取れない場合は、"jpg"を返して先へ進めるのではなくエラーを
    /// 投げる。そのまま進むと、拡張子だけは決まったのに後段のexportableImage(at:)がnilを返し、
    /// manifestに載っているのに実体の無いページが生まれる(EpubExportError.
    /// pageImageUnavailableのコメント参照)。書き出し先を作る前のこの段階で止めるほうがよい。
    func exportableImageFileExtension(at index: Int) async throws -> String {
        guard book.pages.indices.contains(index) else {
            throw PDFImageExtractor.ExtractionError.imageDataUnavailable(pageNumber: index + 1)
        }
        let page = book.pages[index]
        guard case .pdf(let pdfURL, let pdfPageIndex) = page.source else {
            return Self.fileExtension(forEntryPathOf: page)
        }
        guard let document = pdfDocument(for: pdfURL),
              let pdfPage = document.page(at: pdfPageIndex + 1)
        else {
            throw PDFImageExtractor.ExtractionError.imageDataUnavailable(pageNumber: pdfPageIndex + 1)
        }
        return try PDFImageExtractor.imageFormat(of: pdfPage, pageNumber: pdfPageIndex + 1).fileExtension
    }

    /// フォルダ内の画像・書庫内エントリの拡張子(小文字)。拡張子を持たない場合はjpgとみなす
    /// (EpubExporterが従来から使っていた既定と同じ)。
    private static func fileExtension(forEntryPathOf page: PageRef) -> String {
        switch page.source {
        case .file(let url):
            return url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
        case .zip(_, let entryPath), .sevenZip(_, let entryPath), .rar(_, let entryPath):
            let ext = (entryPath as NSString).pathExtension
            return ext.isEmpty ? "jpg" : ext.lowercased()
        case .pdf:
            // 呼び出し側でPDFを先に振り分けているため到達しない。
            return "jpg"
        }
    }

    /// 指定ページの画像サイズ(幅・高さ、ピクセル単位)だけを取得する。ピクセルデータの
    /// デコードを一切伴わないため、画像の解像度に関わらずほぼ一瞬で終わる
    /// (ViewerViewModelの横長/縦長判定(isWideImage)向け。以前はthumbnail(at:)でサムネイルを
    /// デコードして幅・高さを得ていたが、判定に必要なのは縦横比だけで実際のピクセルは
    /// 使わないため、ImageDecoder.pixelSize(of:)(フォーマットのヘッダー部分だけを読む)に
    /// 置き換えた)。
    ///
    /// PDFソースの場合は、ページ描画(renderPDFPage)と同じCGPDFPage.getBoxRect(.mediaBox)から
    /// 直接取得する(レンダリング不要)。
    ///
    /// 注意: JPEG等のEXIF回転タグが付いた画像は、この関数が返す値がタグ適用前の生の
    /// ピクセルサイズになる(thumbnail(at:)側はkCGImageSourceCreateThumbnailWithTransformで
    /// 回転を反映してから幅・高さを見ているため、回転タグ付きの画像では結果が食い違いうる)。
    /// このアプリが主に扱うマンガのスキャン・アーカイブ画像はカメラ写真と異なりEXIF回転タグを
    /// 持つことが稀なため、実用上の影響は小さいと判断している。
    func pageSize(at index: Int) async -> (width: Int, height: Int)? {
        guard !isReleased else { return nil }
        guard book.pages.indices.contains(index) else { return nil }
        let page = book.pages[index]
        if let cached = pageSizeCache[page.id] { return cached }
        if let existing = inFlightPageSizeTasks[page.id] { return await existing.value }

        // PDFはページ寸法がCGPDFPageから直接取れる(ファイルの読み込み・解析を伴わない)ため、
        // actorの外へ逃がす意味が無い。ここで完結させる。
        if case .pdf(let pdfURL, let pageIndex) = page.source {
            guard let document = pdfDocument(for: pdfURL), let pdfPage = document.page(at: pageIndex + 1) else {
                return nil
            }
            let box = pdfPage.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0 else { return nil }
            let size = (width: Int(box.width.rounded()), height: Int(box.height.rounded()))
            pageSizeCache[page.id] = size
            return size
        }

        // 以降(フォルダ内の画像・書庫内エントリ)は、ファイルの読み込みとヘッダー解析を伴う。
        // これをactorを保持したまま行うと、本を開いた直後の全ページ先読み判定
        // (warmUpWideImageCacheForEntireBook)が走っている間、ユーザーのページ送りが要求する
        // pageImage(at:)がactorの順番待ちになってしまう(タスクの優先度を下げても、actorを
        // 掴んでいる間は横取りされない)。decodedImage(for:maxPixelSize:)と同じ考え方で、
        // 重い部分はactorの外のバックグラウンドタスクへ逃がす。
        let task: Task<(width: Int, height: Int)?, Never>
        switch page.source {
        case .file(let url):
            // フォルダの本は、そもそもactorが守るべき共有状態(アーカイブのreader)を触らない。
            // ファイルを丸ごと読まずヘッダーだけを読むURL版を、そのままactor外で使う
            // (ImageDecoder.headerInfo(ofFileAt:)のコメント参照)。
            task = Task.detached(priority: .utility) {
                ImageDecoder.pixelSize(ofFileAt: url)
            }
        case .zip(let archiveURL, let entryPath),
             .sevenZip(let archiveURL, let entryPath),
             .rar(let archiveURL, let entryPath):
            // 書庫からの取り出しはreaderがスレッドセーフでないためactor上で行うほかないが、
            // エントリ全体ではなく先頭だけを伸長する(ArchiveReading.dataPrefix参照)。
            guard let prefix = try? reader(for: archiveURL)?.dataPrefix(
                at: entryPath, maxByteCount: Self.headerProbeByteCount
            ) else { return nil }
            task = Task.detached(priority: .utility) {
                ImageDecoder.pixelSize(of: prefix)
            }
        case .pdf:
            return nil // 上で早期リターン済み(switchを網羅させるためのプレースホルダー)。
        }

        inFlightPageSizeTasks[page.id] = task
        var size = await task.value
        inFlightPageSizeTasks[page.id] = nil

        // 先頭だけではヘッダーを読み取れなかった書庫エントリは、従来通りエントリ全体を読んで
        // やり直す(巨大なEXIF/ICCプロファイルがJPEGのSOFマーカーを先頭から押し出している
        // 画像など)。フォルダの本(.file)はURL版が最初からファイル全体を対象にできるので、
        // この作り直しは要らない。
        //
        // 途中で打ち切ったデータからは、誤った寸法ではなく必ずnilが返る(ヘッダーを読み切れて
        // いなければpixelWidth/pixelHeight自体が存在しないため)ので、ここで作り直すかどうかの
        // 判定にそのままnilを使ってよい。
        //
        // なお、この作り直しは上でinFlightPageSizeTasksを外した後に行うため、ちょうど同じ
        // ページを待ち合わせていた別の呼び出しにはnilが返る。その呼び出し元(横長判定の
        // 先読み)は「まだ判定できていないページ」として扱い、後で改めて問い合わせるだけなので
        // 実害は無い(キャッシュにも入っていないため、次回は正しく読み直される)。
        if size == nil, !page.source.isFile, let fullData = rawData(for: page.source) {
            size = await Task.detached(priority: .utility) {
                ImageDecoder.pixelSize(of: fullData)
            }.value
        }

        // 取得できなかった場合(未対応フォーマット等)はキャッシュしない。次回改めて試みる。
        if let size {
            pageSizeCache[page.id] = size
        }
        return size
    }

    /// コンテキストメニュー「情報を見る」(ユーザー要望)向けに、指定ページの画像ファイル情報を
    /// 取得する。pageSize(at:)と同じくヘッダー情報の読み取りのみ(ピクセルデコード無し)。
    func pageImageInfo(at index: Int) async -> PageImageInfo? {
        guard !isReleased else { return nil }
        guard book.pages.indices.contains(index) else { return nil }
        let page = book.pages[index]
        switch page.source {
        case .pdf(let pdfURL, let pageIndex):
            // PDFのページは独立した画像ファイルではない(PDF自体の1ページ)ため、色空間・
            // カラープロファイル・アルファチャンネル・ファイルサイズはページ単位では
            // 意味を持たない(nilのまま)。場所・作成日・変更日はPDFファイル自体のもの。
            guard let document = pdfDocument(for: pdfURL), let pdfPage = document.page(at: pageIndex + 1) else {
                return nil
            }
            let box = pdfPage.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0 else { return nil }
            let dates = Self.fileSystemDates(for: pdfURL)
            return PageImageInfo(
                fileName: page.displayName,
                formatDescription: "PDF",
                pixelWidth: Int(box.width.rounded()),
                pixelHeight: Int(box.height.rounded()),
                colorModel: nil,
                fileSizeBytes: nil,
                location: pdfURL.deletingLastPathComponent().path,
                createdDate: dates.created,
                modifiedDate: dates.modified,
                colorProfileName: nil,
                hasAlphaChannel: nil
            )
        case .file(let url):
            // pageSize(at:)と同じ理由で、ファイルを丸ごと読まずヘッダーだけを読む
            // (ImageDecoder.headerInfo(ofFileAt:)のコメント参照)。表示するファイルサイズは、
            // 読み込んだバイト数ではなくファイルシステムに問い合わせて得る。
            guard let header = ImageDecoder.headerInfo(ofFileAt: url) else { return nil }
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
            let dates = Self.fileSystemDates(for: url)
            return PageImageInfo(
                fileName: page.displayName,
                formatDescription: Self.imageFormatDescription(forFileName: page.displayName),
                pixelWidth: header.pixelWidth,
                pixelHeight: header.pixelHeight,
                colorModel: header.colorModel,
                fileSizeBytes: fileSize,
                location: url.deletingLastPathComponent().path,
                createdDate: dates.created,
                modifiedDate: dates.modified,
                colorProfileName: header.colorProfileName,
                hasAlphaChannel: header.hasAlpha
            )
        case .zip(let archiveURL, let entryPath), .sevenZip(let archiveURL, let entryPath), .rar(let archiveURL, let entryPath):
            guard let data = rawData(for: page.source),
                  let header = ImageDecoder.headerInfo(of: data)
            else { return nil }
            let dates = reader(for: archiveURL)?.entryDates(at: entryPath) ?? (created: nil, modified: nil)
            // アーカイブ内エントリ自身はディスク上のパスを持たないため、アーカイブファイルの
            // フルパスに、エントリのアーカイブ内フォルダパス(サブフォルダが無ければ空文字列)を
            // 続けたものを「場所」とする。
            let internalFolder = (entryPath as NSString).deletingLastPathComponent
            let location = internalFolder.isEmpty ? archiveURL.path : "\(archiveURL.path)/\(internalFolder)"
            return PageImageInfo(
                fileName: page.displayName,
                formatDescription: Self.imageFormatDescription(forFileName: page.displayName),
                pixelWidth: header.pixelWidth,
                pixelHeight: header.pixelHeight,
                colorModel: header.colorModel,
                fileSizeBytes: Int64(data.count),
                location: location,
                createdDate: dates.created,
                modifiedDate: dates.modified,
                colorProfileName: header.colorProfileName,
                hasAlphaChannel: header.hasAlpha
            )
        }
    }

    /// url自体(フォルダ内の画像ファイル、またはPDFファイル)の、ファイルシステム上の
    /// 作成日時・更新日時。取得できない場合はnil(pageImageInfo(at:)向け)。
    private static func fileSystemDates(for url: URL) -> (created: Date?, modified: Date?) {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return (values?.creationDate, values?.contentModificationDate)
    }

    /// ファイル名の拡張子から、表示用のフォーマット名を求める。EpubExporter.imageMediaType
    /// (forExtension:)と同じ発想(拡張子ベースの簡易判定で十分)。
    private static func imageFormatDescription(forFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "JPEG"
        case "png": return "PNG"
        case "gif": return "GIF"
        case "bmp": return "BMP"
        case "webp": return "WebP"
        case "heic": return "HEIC"
        case "tif", "tiff": return "TIFF"
        case "avif": return "AVIF"
        default: return ext.uppercased()
        }
    }

    /// 画像のエクスポート機能(要望)向け: 「見開きを結合してエクスポート」で、2枚の画像を
    /// 実際に合成するために使う、ダウンサンプリングしない(ImageDecoder.exportMaxPixelSize相当の
    /// 上限のみ持つ)フルサイズのCGImage。pageImage/thumbnailと異なりimageCache/thumbnailCacheには
    /// 保存しない(rawImageDataと同じ理由: エクスポート中に一度読めば十分で、通常の表示キャッシュを
    /// 圧迫したくないため)。decodedImage(for:maxPixelSize:)をそのまま再利用することで、
    /// フォルダ・アーカイブ内画像・PDFのどのソースでも同じ経路(PDFはrenderPDFPageへの描画)で
    /// 扱える。
    func fullResolutionImage(at index: Int) async -> CGImage? {
        guard book.pages.indices.contains(index) else { return nil }
        return await decodedImage(for: book.pages[index].source, maxPixelSize: ImageDecoder.exportMaxPixelSize)
    }

    /// 拡大して見るとき(拡大鏡=ルーペ、およびピンチイン・ピンチアウトによる拡大)向け:
    /// 通常の表示用(pageImage、4096px上限)より高解像度の
    /// ImageDecoder.highResolutionMaxPixelSize(8000px)を上限にデコードする。fullResolutionImage
    /// 同様imageCache/thumbnailCacheには保存しない(呼び出し側のViewerViewModelが、現在表示中の
    /// 見開き分だけを単発キャッシュとして保持する設計のため)。
    func highResolutionImage(at index: Int) async -> CGImage? {
        guard book.pages.indices.contains(index) else { return nil }
        return await decodedImage(for: book.pages[index].source, maxPixelSize: ImageDecoder.highResolutionMaxPixelSize)
    }

    /// index を中心に前後 radius ページ分を先読みする。
    /// 範囲外になった先読みタスクはキャンセルする。
    /// - Parameter displayedPageCount: いま画面に出ているページ数(見開きなら2)。radiusは
    ///   「画面に出ているページの前後に何ページ読み込むか」という意味なので、後ろ側の基点は
    ///   indexではなく**表示中の最後のページ**にする。以前はどちらもindex基準で数えていたため、
    ///   見開きでは後ろ10ページのうち1ページが「いま隣に表示している相方」で埋まり、未見の
    ///   ページは9枚しか先読みされていなかった(ユーザー指摘)。単ページ表示なら従来どおり。
    func prefetch(around index: Int, radius: Int = 3, displayedPageCount: Int = 1) {
        guard !isReleased else { return }
        guard !book.pages.isEmpty else { return }
        let lastDisplayed = index + max(displayedPageCount, 1) - 1
        let lower = max(0, index - radius)
        let upper = min(book.pages.count - 1, lastDisplayed + radius)
        guard lower <= upper else { return }

        for (existingIndex, entry) in prefetchTasks where existingIndex < lower || existingIndex > upper {
            entry.task.cancel()
            // ラッパーのTaskをキャンセルしただけでは、既に始まっている内側の読み込み
            // (アーカイブ展開+デコード)は止まらない(cancellableInFlightKeysのコメント参照)。
            // まだ実表示の要求が合流していない先読みに限り、その読み込み自体も打ち切る。
            if cancellableInFlightKeys.contains(entry.inFlightKey) {
                inFlightTasks[entry.inFlightKey]?.cancel()
            }
            prefetchTasks.removeValue(forKey: existingIndex)
        }

        // 現在ページに近い順(前後交互)に始める。デコードの同時実行数を絞っているので
        // (decodeSlotsのコメント参照)、始めた順がほぼそのまま仕上がる順になる。次に
        // 表示される可能性が高いのは隣のページなので、そこから埋める。
        var order: [Int] = (index...lastDisplayed).filter { lower...upper ~= $0 }
        var offset = 1
        while lastDisplayed + offset <= upper || index - offset >= lower {
            if lastDisplayed + offset <= upper { order.append(lastDisplayed + offset) }
            if index - offset >= lower { order.append(index - offset) }
            offset += 1
        }
        for pageIndex in order {
            guard prefetchTasks[pageIndex] == nil else { continue }
            let page = book.pages[pageIndex]
            guard imageCache.object(forKey: page.id as NSString) == nil else { continue }

            // image(at:cache:maxPixelSize:isPrefetch:)へ渡すキーの組み立て方と揃えること。
            let inFlightKey = "\(ObjectIdentifier(imageCache))#\(page.id)"
            let task = Task { [weak self] in
                guard let self else { return }
                _ = await self.prefetchImage(at: pageIndex)
                await self.clearPrefetchTask(for: pageIndex)
            }
            prefetchTasks[pageIndex] = PrefetchEntry(task: task, inFlightKey: inFlightKey)
        }
    }

    /// prefetch(around:)専用の入り口。pageImage(at:)と同じ読み込みだが、「先読みとして
    /// 始めた」ことを記録し、範囲外になった時点で打ち切れるようにする
    /// (cancellableInFlightKeysのコメント参照)。
    private func prefetchImage(at index: Int) async -> PagePixelBuffer? {
        await pixels(
            at: index, cache: imageCache, maxPixelSize: ImageDecoder.pageMaxPixelSize, isPrefetch: true
        )
    }

    private func clearPrefetchTask(for index: Int) {
        prefetchTasks.removeValue(forKey: index)
    }

    /// - Parameter isPrefetch: prefetch(around:)からの先読みとして呼ばれた場合はtrue。
    ///   この場合にかぎり、先読み範囲から外れた時点で読み込みを途中で打ち切ってよいものとして
    ///   記録する(cancellableInFlightKeysのコメント参照)。
    private func pixels(
        at index: Int,
        cache: PagePixelCache,
        maxPixelSize: CGFloat,
        isPrefetch: Bool = false
    ) async -> PagePixelBuffer? {
        guard book.pages.indices.contains(index) else { return nil }
        let page = book.pages[index]
        let key = page.id as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        // cache(フルサイズ用/サムネイル用)ごとに分けて合流させるため、キーにcacheの識別子も含める
        let inFlightKey = "\(ObjectIdentifier(cache))#\(page.id)"
        if let existingTask = inFlightTasks[inFlightKey] {
            if !isPrefetch {
                // 先読みが始めた読み込みに、実際の表示要求が合流した。もう打ち切ってはならない。
                cancellableInFlightKeys.remove(inFlightKey)
                // その読み込みがまだデコードの空き待ち(先読みの列)なら、表示要求の列へ移す
                // (promoteDecodeWaiterのコメント参照)。
                promoteDecodeWaiter(forKey: inFlightKey)
            }
            return await existingTask.value
        }

        // 呼び出し元(ViewerViewModel側)のタスクがすでにキャンセルされているなら、
        // ここから先の読み込み/デコードは無駄になるので行わない。
        // スクロールホイールなどで素早く連続してページ送りされたときに、
        // 表示されないとわかっているページのデコードでCPUを使い切ってしまい、
        // 最新のページの表示が遅れるのを防ぐための早期リターン。
        guard !Task.isCancelled else { return nil }

        let task = Task<PagePixelBuffer?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.decodedPixels(
                for: page.source, maxPixelSize: maxPixelSize, isPrefetch: isPrefetch, waiterKey: inFlightKey
            )
        }
        inFlightTasks[inFlightKey] = task
        if isPrefetch {
            cancellableInFlightKeys.insert(inFlightKey)
        }

        let decoded = await task.value
        inFlightTasks[inFlightKey] = nil
        cancellableInFlightKeys.remove(inFlightKey)

        guard let decoded, !isReleased else { return nil }
        cache.store(decoded, forKey: key)
        return decoded
    }

    /// decodedImage(for:maxPixelSize:)の結果を、キャッシュに入れる形(PagePixelBuffer)へ
    /// 描き写して返す。描き写しはデコードと同じくactorの外で行う(メモリコピー相当とはいえ
    /// 36MBで十数msあり、actorを掴んだままだと他のページの要求を待たせるため)。
    /// - Parameter waiterKey: この読み込みのinFlightKey。先読みとして空き待ちに並んでいる間に
    ///   表示要求が合流したとき、その待ちを表示要求の列へ移すための突き合わせに使う
    ///   (promoteDecodeWaiter参照)。合流の仕組みが無い経路(拡大サムネイル)はnil。
    private func decodedPixels(
        for source: PageSource, maxPixelSize: CGFloat, isPrefetch: Bool = false, waiterKey: String? = nil
    ) async -> PagePixelBuffer? {
        // フルサイズのデコードは同時実行数を絞る(decodeSlotsのコメント参照)。サムネイルは
        // 1枚の一時メモリが小さいので絞らない(ページ一覧の数十枚が直列に待たされる方が害)。
        let isFullSize = maxPixelSize >= ImageDecoder.pageMaxPixelSize
        if isFullSize {
            await acquireDecodeSlot(isPrefetch: isPrefetch, waiterKey: waiterKey)
        }
        defer { if isFullSize { releaseDecodeSlot() } }
        guard !Task.isCancelled else { return nil }

        // PDFはCGImageを経由せず、バッファへ直接描ける(コントラスト補正が要る場合だけは
        // 補正がCGImageを相手にするため、従来どおりCGImage経由にする)。
        if case .pdf(let pdfURL, let pageIndex) = source, !contrastCorrectionEnabled {
            return renderPDFPixels(pdfURL: pdfURL, pageIndex: pageIndex, maxPixelSize: maxPixelSize)
        }
        guard let decoded = await decodedImage(for: source, maxPixelSize: maxPixelSize) else { return nil }
        guard !Task.isCancelled else { return nil }
        return await Self.renderBuffer(from: decoded)
    }

    // MARK: - フルサイズデコードの同時実行数

    /// フルサイズ(ページ表示用)のデコードを同時に走らせてよい数。
    ///
    /// ■ なぜ絞るのか(リソースモニタの実測に基づく)
    /// 1枚のデコード中は、最終的にキャッシュへ入る`PagePixelBuffer`(幅×高さ×4)の**約3倍**の
    /// メモリを一時的に使う(ImageIOのデコード結果のビットマップ、描き写し中のバッファ、
    /// ImageIO内部の作業領域)。先読みは前後`prefetchPageCount`枚を一斉に始めるので、設定が
    /// 10なら21枚ぶんが同時に走り、2400×3400の本で起動直後のfootprintが2.4GBまで跳ねていた
    /// (定常は580MB。先読み3枚なら924MB、0枚なら459MB、と枚数に比例)。
    ///
    /// 同時数を絞れば、一時メモリは「この数 × 3倍」で頭打ちになる。先読みは直列に近くなるが
    /// 1枚数十msなので、21枚でも1秒程度で終わり体感には乗らない。
    ///
    /// ■ 表示要求は先読みより先に通す
    /// 待ち行列は2本(表示要求・先読み)で、空きが出たら表示要求を先に起こす。これが無いと、
    /// ページ送りの直後に表示したいページが、先に並んでいた先読み21枚の後ろで待つことになる。
    ///
    /// 3は「メモリの頭打ち(3×3倍≒300MB)」と「コアを遊ばせない」の折衷。コア数が少ない
    /// マシンではそれに合わせて減らす。
    private static let maxConcurrentDecodes = max(1, min(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    private var activeDecodes = 0
    /// 空き待ち。`key`はpixels(at:)のinFlightKey(合流の突き合わせ用。無い経路はnil)。
    private struct DecodeWaiter {
        let key: String?
        let continuation: CheckedContinuation<Void, Never>
    }
    private var urgentDecodeWaiters: [DecodeWaiter] = []
    private var prefetchDecodeWaiters: [DecodeWaiter] = []

    private func acquireDecodeSlot(isPrefetch: Bool, waiterKey: String?) async {
        if activeDecodes < Self.maxConcurrentDecodes {
            activeDecodes += 1
            return
        }
        // 空きが無ければ待つ。起こされた時点でスロットは自分のものになっている
        // (releaseDecodeSlotがactiveDecodesを減らさずに次を起こす)。キャンセルされた
        // タスクも一度は起こされ、呼び出し側のisCancelledチェックで即座に
        // releaseDecodeSlotへ進むので、スロットが漏れることはない。
        await withCheckedContinuation { continuation in
            let waiter = DecodeWaiter(key: waiterKey, continuation: continuation)
            if isPrefetch {
                prefetchDecodeWaiters.append(waiter)
            } else {
                urgentDecodeWaiters.append(waiter)
            }
        }
    }

    /// 先読みとして空き待ちに並んでいる読み込みへ表示要求が合流したとき、その待ちを
    /// 表示要求の列の末尾へ移す(監査で指摘)。
    ///
    /// これが無いと、速いページ送りの直後に表示したいページが、先に並んでいた他の先読み
    /// (最大で先読み数ぶん)の後ろで待たされる。合流の時点ではまだデコードが始まっていない
    /// (=まだ列にいる)ことも多く、その場合だけ効く。既に走っていれば何もしない。
    private func promoteDecodeWaiter(forKey key: String) {
        guard let index = prefetchDecodeWaiters.firstIndex(where: { $0.key == key }) else { return }
        urgentDecodeWaiters.append(prefetchDecodeWaiters.remove(at: index))
    }

    private func releaseDecodeSlot() {
        if !urgentDecodeWaiters.isEmpty {
            urgentDecodeWaiters.removeFirst().continuation.resume()
        } else if !prefetchDecodeWaiters.isEmpty {
            prefetchDecodeWaiters.removeFirst().continuation.resume()
        } else {
            activeDecodes -= 1
        }
    }

    /// CGImage → PagePixelBufferの描き写しをバックグラウンドタスクで行う。
    /// `nonisolated static`: actorの状態に触らないことを型で示す(actorの外で走らせるため)。
    private nonisolated static func renderBuffer(from image: CGImage) async -> PagePixelBuffer? {
        let task = Task.detached(priority: .userInitiated) { () -> PagePixelBuffer? in
            PagePixelBuffer(rendering: image)
        }
        return await task.value
    }

    /// ページ1枚分の実際の取得+デコード(またはPDFの場合は描画)を行う。このメソッド自体は
    /// actorに分離されているため、readers/pdfDocumentsなどのactor隔離プロパティへ安全に
    /// アクセスできる(image(at:)内のTaskクロージャは静的にはこのactorに分離されているとは
    /// 保証されないため、`await self.decodedImage(...)`という形でここへ入ってくる)。
    ///
    /// フォルダ内画像・アーカイブ内画像は、rawDataでバイト列を取り出したうえで、デコード自体
    /// (CPU負荷が高い)をactorの外のバックグラウンドタスクで行う。一方PDFのページ描画は、
    /// CGPDFDocument/CGPDFPageというCore Graphicsの参照型をactorの外(Task.detached、
    /// @Sendableクロージャ)へ持ち出さずに使うため、actor内で直接CGImageまで作る
    /// (1ページ分の描画は画像デコードほど重くなく、actorを長時間ブロックする心配は小さい)。
    private func decodedImage(for source: PageSource, maxPixelSize: CGFloat) async -> CGImage? {
        let decoded: CGImage?
        switch source {
        case .pdf(let pdfURL, let pageIndex):
            guard !Task.isCancelled else { return nil }
            decoded = renderPDFPage(pdfURL: pdfURL, pageIndex: pageIndex, maxPixelSize: maxPixelSize)
        case .file, .zip, .sevenZip, .rar:
            guard let data = rawData(for: source) else { return nil }
            guard !Task.isCancelled else { return nil }
            // デコードはactorの外(バックグラウンドタスク)で行い、
            // 他のページのリクエストをここで足止めしないようにする。
            // (Task.detachedのトレーリングクロージャに対する戻り値の型推論がXcodeのバージョンによって
            //  不安定なことがあるため、クロージャの戻り値の型を明示し、Taskの生成とvalueの待ち受けを
            //  分けて書くことで確実に型が決まるようにしている)
            let decodeTask = Task.detached(priority: .userInitiated) { () -> CGImage? in
                ImageDecoder.decode(data, maxPixelSize: maxPixelSize)
            }
            decoded = await decodeTask.value
        }

        guard let decoded else { return nil }
        guard contrastCorrectionEnabled else { return decoded }
        guard !Task.isCancelled else { return decoded }
        // 補正自体(ダウンサンプルでの分析+GPUでのレベル補正)も相応にCPU/GPU負荷があるため、
        // decodeTaskと同じくactorの外(バックグラウンドタスク)へ逃がし、他のページの
        // リクエストをここで足止めしないようにする。ContrastCorrector.applyはカラーページの
        // 判定・除外も内部で行うため、ここでは常に呼ぶだけでよい。
        let correctionTask = Task.detached(priority: .userInitiated) { () -> CGImage in
            ContrastCorrector.apply(to: decoded)
        }
        return await correctionTask.value
    }

    /// この本が持っている`ComicInfo.xml`を解析して返す(無ければnil)。
    ///
    /// CBZ書き出しが、元ファイルのComicInfo.xmlを引き継ぐために使う。
    ///
    /// 書庫の場合にComicInfoResolver.resolve(bookAt:)を直接呼ぶと、既にこのPageLoaderが
    /// 開いているのと同じ書庫をもう一度開き直すことになる(7zは一覧を得るだけでも重い)。
    /// ここに置くことで、開いてあるReaderをそのまま使い回せる。**Reader自体はこのactorの外へ
    /// 出さない**(CLAUDE.mdの「archive/PDFのハンドルはactor隔離のまま保つ」という制約に従い、
    /// 解析までをこの中で完結させる)。
    ///
    /// フォルダの本はこのPageLoaderが書庫を持たないため、パスから直接探す経路へ振り分ける。
    /// 「書庫だがComicInfo.xmlが無い」と「そもそも書庫ではない」を呼び出し側で区別せずに
    /// 済むよう、振り分けまでをこの1つのメソッドに閉じてある。
    ///
    /// - Parameter bookSourceURL: MangaBook.sourceURL(フォルダの本を探す場合にだけ使う)。
    func sourceComicInfo(bookSourceURL: URL) -> ComicInfo? {
        switch book.pages.first?.source {
        case .zip(let url, _), .sevenZip(let url, _), .rar(let url, _):
            guard let reader = reader(for: url) else { return nil }
            return ComicInfoResolver.resolve(reader: reader)
        case .file:
            // 画像フォルダ。
            return ComicInfoResolver.resolve(bookAt: bookSourceURL)
        case .pdf, nil:
            // PDFはComicInfo.xmlを持たない形式。
            return nil
        }
    }

    private func rawData(for source: PageSource) -> Data? {
        switch source {
        case .file(let url):
            return try? Data(contentsOf: url)
        case .zip(let archiveURL, let entryPath),
             .sevenZip(let archiveURL, let entryPath),
             .rar(let archiveURL, let entryPath):
            return try? reader(for: archiveURL)?.data(at: entryPath)
        case .pdf:
            // PDFはdecodedImage(for:maxPixelSize:)側で直接renderPDFPageに振り分けられるため、
            // ここが実際に呼ばれることはない(switchを網羅させるためのプレースホルダー)。
            return nil
        }
    }

    /// PDFファイルごとにCGPDFDocumentを使い回す。アーカイブのreader(for:)と同様の考え方。
    private func pdfDocument(for pdfURL: URL) -> CGPDFDocument? {
        if let cached = pdfDocuments[pdfURL.path] { return cached }
        guard let document = CGPDFDocument(pdfURL as CFURL) else { return nil }
        pdfDocuments[pdfURL.path] = document
        return document
    }

    /// PDFの指定ページ(0始まり)を、長辺がmaxPixelSizeに収まる解像度でCGImageとして描画する。
    /// 透過を持つPDFページ(白紙部分が透明になっている場合など)でも、他の画像ページと同様に
    /// 不透明な画像として扱えるよう、白背景の上に描画する。
    private func renderPDFPage(pdfURL: URL, pageIndex: Int, maxPixelSize: CGFloat) -> CGImage? {
        renderPDFPixels(pdfURL: pdfURL, pageIndex: pageIndex, maxPixelSize: maxPixelSize)?.makeImage()
    }

    /// renderPDFPageの本体。描画先はPagePixelBufferが確保したmmap領域で、CGImageを経由しない
    /// (PagePixelBuffer.init(width:height:grayscale:colorSpace:draw:)のコメント参照)。
    private func renderPDFPixels(pdfURL: URL, pageIndex: Int, maxPixelSize: CGFloat) -> PagePixelBuffer? {
        guard let document = pdfDocument(for: pdfURL) else { return nil }
        // CGPDFDocumentのページ番号は1始まり(pageIndexは0始まり)。
        guard let page = document.page(at: pageIndex + 1) else { return nil }

        let mediaBox = page.getBoxRect(.mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else { return nil }

        // PDFのページ寸法はpt(72dpi基準)でしか分からないため、要求された最大ピクセル数まで
        // 無条件に引き伸ばすと、中身より高い解像度で描くことになる。画像ファイルの側は
        // ImageDecoder.decodeがCGImageSourceCreateThumbnailAtIndexで**拡大はしない**ため、
        // PDFだけが「元の解像度に関わらず常に上限いっぱいまで拡大する」という非対称な扱いに
        // なっていた。拡大鏡・ピンチ拡大用のhighResolutionMaxPixelSize(8000)では、A5相当の
        // ページ1枚で5650×8000≈181MBに達し、見開き2枚とその結合画像まで同時に抱えると
        // 1GB近くを一度に確保することになる(実機でメモリ逼迫によるプロセス終了を確認)。
        //
        // 埋め込み画像の実解像度(=このPDFが実際に持っている情報量)を上限にする。
        // ただし通常表示ぶん(pageMaxPixelSize相当)は下回らせない。ベクター描画主体の
        // ページで、たまたま小さな画像(ロゴ等)しか埋め込まれていない場合に、その小ささへ
        // 引きずられて粗くなるのを防ぐため。画像を1枚も持たないページでは従来どおり
        // 要求どおりの解像度で描く。
        let requestedScale = min(maxPixelSize / mediaBox.width, maxPixelSize / mediaBox.height)
        let baselineScale = min(
            ImageDecoder.pageMaxPixelSize / mediaBox.width,
            ImageDecoder.pageMaxPixelSize / mediaBox.height
        )
        var scale = requestedScale
        if let embedded = PDFImageExtractor.largestEmbeddedImagePixelSize(of: page) {
            let naturalScale = max(
                CGFloat(embedded.width) / mediaBox.width,
                CGFloat(embedded.height) / mediaBox.height
            )
            if naturalScale > 0 {
                scale = min(requestedScale, max(naturalScale, baselineScale))
            }
        }
        let pixelWidth = max(1, Int((mediaBox.width * scale).rounded()))
        let pixelHeight = max(1, Int((mediaBox.height * scale).rounded()))

        return PagePixelBuffer(
            width: pixelWidth, height: pixelHeight, grayscale: false,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        ) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))

            context.scaleBy(x: scale, y: scale)
            // メディアボックスの原点が(0, 0)でない場合に備えて平行移動しておく。
            context.translateBy(x: -mediaBox.origin.x, y: -mediaBox.origin.y)
            context.drawPDFPage(page)
        }
    }

    /// アーカイブごとにReaderを使い回す。actorの外から同時に触られることはないので、
    /// ここでの読み込みは安全に直列化される。
    ///
    /// バグ修正(予防): 以前は一度作ったReaderを本を閉じるまで一切解放していなかった。通常の
    /// 本(1冊=1つの書庫、またはフォルダ内の画像だけ)ならReaderはたかだか1つなので問題に
    /// ならないが、BookLoaderは「フォルダの中に並んだ大量の書庫」も「書庫の中の入れ子の書庫」も
    /// 統合して1冊として開けるため(BookLoader.collectPages参照)、そうした本ではページを
    /// 読み進めるだけで開いたままのファイルハンドルが際限なく増えていく。直近に使ったものだけを
    /// 残す上限を設ける。
    ///
    /// 上限を超えて追い出したReaderは、次にそのアーカイブのページへ戻ったときに作り直される
    /// だけで、動作は変わらない。通常の本では追い出し自体が起きないため、速度への影響も無い。
    private static let maxCachedReaders = 8

    /// readersの使用順(古い順)。maxCachedReadersを超えたぶんを先頭から追い出す。
    private var readerUsageOrder: [String] = []

    private func reader(for archiveURL: URL) -> ArchiveReading? {
        let path = archiveURL.path
        if let cached = readers[path] {
            touchReaderUsage(path)
            return cached
        }
        guard let created = try? makeArchiveReader(for: archiveURL) else { return nil }
        readers[path] = created
        touchReaderUsage(path)
        while readerUsageOrder.count > Self.maxCachedReaders {
            let evicted = readerUsageOrder.removeFirst()
            readers.removeValue(forKey: evicted)
        }
        return created
    }

    /// pathを「いちばん最近使った」位置(末尾)へ移す。
    ///
    /// Readerは常にactor隔離されたメソッドの中で同期的に使い切られる(rawData/pageSize/
    /// pageImageInfoのいずれも、reader(for:)で受け取ってからawaitを挟まずに読み終える)ため、
    /// ここでの追い出しが「今まさに誰かが使っているReader」を消してしまうことはない。
    private func touchReaderUsage(_ path: String) {
        if let existing = readerUsageOrder.firstIndex(of: path) {
            readerUsageOrder.remove(at: existing)
        }
        readerUsageOrder.append(path)
    }
}

/// `PageLoader.cacheStatistics()`が返す、ある時点のメモリキャッシュと先読みの状態。
/// リソースモニタ(ResourceMonitorSnapshot)の材料で、PageLoaderの外へはこの値型だけを出す。
nonisolated struct PageCacheStatistics: Equatable, Sendable {
    /// ページ画像。`keys`は`PageRef.id`。
    var pageImages: PagePixelCache.Snapshot
    var pageImageLimitBytes: Int
    /// 進捗バー用サムネイル。`keys`は`PageRef.id`。
    var thumbnails: PagePixelCache.Snapshot
    var thumbnailLimitBytes: Int
    /// 拡大サムネイル。`keys`は`"\(PageRef.id)|\(px)"`。
    var gridThumbnails: PagePixelCache.Snapshot
    var gridThumbnailLimitBytes: Int
    /// いま先読みのタスクが走っている(まだ終わっていない)ページのインデックス。
    /// 「設定より広く先読みしていないか」の判定に使う。残留しているページとは別物
    /// (残留は上限内ならいくらあっても正常)。
    var prefetchingIndices: Set<Int>
}

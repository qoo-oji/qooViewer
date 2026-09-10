import Foundation
import CoreGraphics

/// コレクションのカバーを並べるときの縦横比(ユーザー要望 2026-09-09)。**ライブラリ単位**で選ぶ
/// (BookLibrary.coverAspectRatioRaw)。
///
/// 商業コミックのように縦長ページばかりの本は`.portrait`(2:3)でよいが、同人CG集のように
/// **横長画像だけで構成された本**では、2:3へ切ると横幅の半分以上を捨てた札が並ぶ。そのため
/// `.square`(1:1)を、さらに**このアプリを漫画ビューアではなく画像ビューアとして使う**人のために
/// `.landscape`(3:2)を選べるようにした(ユーザー指摘 2026-09-09 ―― 写真や壁紙のような素材は、
/// 横長のまま並ぶほうが素直)。
///
/// ライブラリ単位にしてあるのは、1つのグリッドに比の違う札が混ざらないようにするため
/// (同じ大きさの札が整然と並ぶことが、一覧の目的である「どの本かを見分ける」に効く)。
///
/// rawValueを明示的な文字列にしてあるのは、そのままDBとJSONに書くため
/// (ReadingDirection.stableIDと同じ理由。表示文言を変えても保存済みの値が壊れないように)。
nonisolated enum CoverAspectRatio: String, Sendable, CaseIterable {
    /// 2:3。縦長のページをそのまま並べる既定。
    case portrait
    /// 1:1。横長画像中心の本を、横を捨てずに並べる。
    case square
    /// 3:2。横長の画像そのものを見せたい使い方(画像ビューアとして)向け。
    case landscape

    /// 幅 ÷ 高さ。
    var value: CGFloat {
        switch self {
        case .portrait: 2.0 / 3.0
        case .square: 1.0
        case .landscape: 3.0 / 2.0
        }
    }

    /// コレクションのタイル(CollectionTile)の中に敷き詰めるセルの列数・行数。
    ///
    /// **札全体がほぼ正方形になる**組み合わせを選んである(セルの幅をw・間隔をsとして):
    /// - 2:3 … 3列2行。幅 = 3w + 2s / 高さ = 2 × 1.5w + s = 3w + s
    /// - 1:1 … 2列2行。幅 = 2w + s / 高さ = 2w + s
    /// - 3:2 … 2列3行(2:3の裏返し)。幅 = 2w + s / 高さ = 3 × (2w/3) + 2s = 2w + 2s
    ///
    /// 縦長・横長は間隔1本ぶん(3pt)だけ正方形からずれるが、縦横比の指定を別に書かなくても
    /// ほぼ正方形に落ち着くので、タイルの大きさはスライダーの値にそのまま従わせられる。
    var tileColumns: Int {
        switch self {
        case .portrait: 3
        case .square, .landscape: 2
        }
    }

    var tileRows: Int {
        switch self {
        case .portrait, .square: 2
        case .landscape: 3
        }
    }

    var tileCellCount: Int { tileColumns * tileRows }
}

/// 画像の比が枠の比と違うとき、**どこを残すか**という指定。切る軸(左右か上下か)は画像と枠の比から
/// 決まるので、この値自体は軸に依存しない3値にしてある(ユーザー要望 2026-09-09)。
///
/// - `.start` … 左右を切るなら左端、上下を切るなら上端を残す
/// - `.center` … 中央を残す(ライブラリの既定)
/// - `.end` … 左右を切るなら右端、上下を切るなら下端を残す
///
/// 以前は「自動 = その本の読み方向から決める(右開きなら左端)」という4つ目の状態があったが、
/// 廃止した(2026-09-09)。上下方向の切り出しには読み方向が何も言えないうえ、読み方向を変えると
/// カバーの見た目まで変わるのは予想しにくい挙動だったため。
///
/// 保存先は2か所ある。**ライブラリの既定**(BookLibrary.coverCropAnchorRaw、非Optional)と、
/// **本ごとの上書き**(BookLayoutSettings.coverCropAnchorRaw、Optional。nil = ライブラリに従う)。
///
/// rawValueを明示的な文字列にしてあるのは、そのままDBとJSONに書くため。
nonisolated enum CoverCropAnchor: String, Sendable, CaseIterable {
    case start
    case center
    case end

    /// DB/JSONに保存されている文字列を読む。
    ///
    /// 「自動」があった頃の値("left"/"right")も受ける ―― この機能が入る前のビルドで
    /// 位置を指定していた本が、未知の値として黙って既定へ落ちないようにするため
    /// (このアプリはまだ未リリースだが、開発中のDBには実際にその値が入っている)。
    static func stored(_ raw: String?) -> CoverCropAnchor? {
        guard let raw else { return nil }
        switch raw {
        case "left": return .start
        case "right": return .end
        default: return CoverCropAnchor(rawValue: raw)
        }
    }
}

/// 「この本のカバーは何か」を決める唯一の場所。
///
/// 同じ問いに答える場所が以前は2つあった ―― 書き出し(EpubExporter/CbzExporter)と、
/// EPUB/CBZ書き出しウインドウのカバー列(BookExportViewModel.resolveDefaultCoverName)。
/// コレクションのカバー抽出(改善要望5)が3つ目になるため、「上書き設定 → 実効1ページ目 →
/// 画像」の道筋をここへ集約する。書き出し側が使うのは**カバーの名前**であって画像ではないので
/// あちらはそのままだが、画像の復号はこの1本に寄せる。
///
/// nonisolated: コレクションのカバー抽出はメインアクターの外で走る(CollectionCoverExtractorが
/// `await`で呼ぶ)。プロジェクト既定の「Default Actor Isolation = MainActor」の対象外にする
/// 理由はArchiveReading.swift冒頭のコメント参照。
nonisolated enum CoverImageResolver {
    /// DB(BookLayoutSettings / PageLayoutOverride)から、メインアクターの外へ持ち出すための値の
    /// スナップショット。組み立てるのは`LayoutStore.shelfCoverSnapshot(forBookID:)`。
    ///
    /// **切り出しに関する値はここに含まれない。** カバーは切らずに保存し、表示のたびに切るように
    /// なった(cropped(_:to:anchor:)のコメント参照)ので、抽出が知る必要があるのは
    /// 「どの画像か」だけになった。
    struct OverrideSnapshot: Sendable {
        /// 本に含まれる既存ページを表紙に指定している場合、そのPageRef.sortKey。
        var coverPageKey: String?
        /// 利用者が用意した画像を表紙に指定している場合、その保管庫の中のURL
        /// (CollectionCoverSourceStore)。**アプリ自身の領域なので、セキュリティスコープの
        /// 開始は要らない。**
        var imageFileURL: URL?
        /// ページ順序の補正(未設定ならnil)。
        var pageOrderOverride: [String]?
        /// 除外されているページのキー。
        var excludedKeys: Set<String> = []

        init(
            coverPageKey: String? = nil,
            imageFileURL: URL? = nil,
            pageOrderOverride: [String]? = nil,
            excludedKeys: Set<String> = []
        ) {
            self.coverPageKey = coverPageKey
            self.imageFileURL = imageFileURL
            self.pageOrderOverride = pageOrderOverride
            self.excludedKeys = excludedKeys
        }
    }

    /// この本のコレクション表紙を、最大`maxPixelSize`で復号する。失敗した場合はnil。
    ///
    /// 呼び出し側は、サンドボックスでアクセス権が必要なURLに対して、あらかじめ
    /// `startAccessingSecurityScopedResource()`を呼んでおくこと(この関数は本体URLの
    /// アクセス権の開始/終了を行わない)。
    ///
    /// - Parameter url: 本そのものの場所。**指定した画像を表紙にしている本ではnilでよい** ――
    ///   その場合この関数は本を一切開かない。未接続のボリューム上にある本でも表紙が出せる
    ///   のはこのため(CollectionCoverExtractor.extractのコメント参照)。
    ///
    /// - Parameter cachesPageList: 読み込んだ本のページ一覧をディスクキャッシュ
    ///   (BookPageListCache)へ書き戻すか。単体テストはfalseで呼ぶ(実物のアプリと同じ
    ///   保存先へテスト用の本の痕跡を残さないため)。
    ///
    /// **`@concurrent`が要る**(監査で指摘 2026-09-09)。このプロジェクトはApproachable
    /// Concurrency(`NonisolatedNonsendingByDefault`)が有効で、`nonisolated async`関数は
    /// 呼び出し側のアクタ ―― ここではCollectionCoverExtractorのMainActor ―― を引き継いで走る。
    /// 本体を開く経路はBookLoader/PageLoaderが自分で外へ逃げるので影響が無いが、外部カバー
    /// ファイルの経路(`Data(contentsOf:)`と復号)はここで直に走るため、付けないと未接続の
    /// ボリューム上の外部カバー1枚でメインが止まる。
    @concurrent nonisolated static func coverImage(
        bookAt url: URL?, snapshot: OverrideSnapshot, maxPixelSize: CGFloat,
        cachesPageList: Bool = true
    ) async -> CGImage? {
        // 1. 利用者が用意した画像が指定されていれば、本体を開かずにそれを読む。
        //    保管庫はこのアプリ自身の領域なので、セキュリティスコープの開始は要らない。
        if let imageFileURL = snapshot.imageFileURL {
            guard let data = try? Data(contentsOf: imageFileURL) else { return nil }
            return ImageDecoder.decode(data, maxPixelSize: maxPixelSize)
        }

        // 2. 本を読み込んで、対象のページを決める。
        guard let url else { return nil }
        guard let book = try? await BookLoader.load(from: url, cachesPageList: cachesPageList),
              !book.pages.isEmpty
        else { return nil }
        guard let target = targetPage(in: book, snapshot: snapshot),
              let index = book.pages.firstIndex(where: { $0.sortKey == target.sortKey })
        else { return nil }

        // 3. 復号。カバーは1000px弱の小さな画像なので、grid用の経路をそのまま借りる。
        //    ディスクキャッシュ(ThumbnailDiskCache)は使わない ―― カバーはこの後
        //    CollectionCoverStoreへJPEGで永続化するので、同じ絵を2か所に置く意味が無い。
        let loader = PageLoader(book: book, usesThumbnailDiskCache: false)
        let image = await loader.gridThumbnail(at: index, maxPixelSize: maxPixelSize, usesDiskCache: false)
        await loader.releaseAllResources()
        return image
    }

    /// カバーにするページ。上書き指定があればそのページ、無ければ実効1ページ目
    /// (除外・並べ替えを反映した後の先頭)。
    private static func targetPage(in book: MangaBook, snapshot: OverrideSnapshot) -> PageRef? {
        if let key = snapshot.coverPageKey,
           let page = book.pages.first(where: { $0.sortKey == key }) {
            return page
        }
        // 指定されたページが本から消えている場合(中身が差し替わった等)は、既定と同じ
        // 「実効1ページ目」へ落とす ―― カバーが空になるより、先頭ページが出るほうがよい。
        return EffectivePageOrder.orderedPages(
            for: book.pages, pageOrderSource: book.pageOrderSource,
            pageOrderOverride: snapshot.pageOrderOverride, excludedKeys: snapshot.excludedKeys
        ).first
    }

    /// 画像を枠の比(`targetAspect` = 幅 ÷ 高さ)へ切り出す。はみ出す側だけを切り、`anchor`で
    /// どこを残すかを決める。
    ///
    /// ■ なぜ**表示のたびに**切るのか(2026-09-09に保存時から移した)
    /// 以前は抽出した時点で2:3へ切ってJPEGを保存していた。ライブラリごとに比を選べるように
    /// した以上、その方式だと**トグル1つでそのライブラリの全冊を読み直す**ことになる ――
    /// 書庫を展開し直すので冊数ぶんの時間がかかり、外付けボリュームが未接続なら抽出に失敗して
    /// カバーが灰色(`.failed`)へ落ちる。表示の設定を変えただけでカバーが消えるのは受け入れ難い。
    /// 保存するのは切っていない画像1枚だけにして、比も位置も表示時に効かせれば、切り替えは
    /// **即時かつ無損失**になる。`CGImage.cropping(to:)`は元画像を参照する部分画像を作るだけで、
    /// 画素のコピーは起きない。
    ///
    /// ■ 座標系
    /// `CGImage.cropping(to:)`のrectは**左上が原点**(CGContextの座標系ではない)。したがって
    /// 上下を切るときは`.start`がy=0、つまり画像の**上端**を残す。取り違えやすいので
    /// CoverImageResolverTestsで固定してある。
    static func cropped(
        _ image: CGImage, to targetAspect: CGFloat, anchor: CoverCropAnchor
    ) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, targetAspect > 0 else { return image }
        let imageAspect = CGFloat(width) / CGFloat(height)

        if imageAspect > targetAspect {
            // 相対的に横長。高さは残したまま、幅だけを詰める(極端なパノラマでも同じ計算でよい)。
            let targetWidth = max(1, Int((CGFloat(height) * targetAspect).rounded()))
            guard targetWidth < width else { return image }
            let originX: Int
            switch anchor {
            case .start: originX = 0
            case .center: originX = (width - targetWidth) / 2
            case .end: originX = width - targetWidth
            }
            let rect = CGRect(x: originX, y: 0, width: targetWidth, height: height)
            return image.cropping(to: rect) ?? image
        } else {
            // 相対的に縦長。幅は残したまま、高さだけを詰める。
            let targetHeight = max(1, Int((CGFloat(width) / targetAspect).rounded()))
            guard targetHeight < height else { return image }
            let originY: Int
            switch anchor {
            case .start: originY = 0
            case .center: originY = (height - targetHeight) / 2
            case .end: originY = height - targetHeight
            }
            let rect = CGRect(x: 0, y: originY, width: width, height: targetHeight)
            return image.cropping(to: rect) ?? image
        }
    }

    /// 枠へ切り出したあとに`croppedWidth`画素を確保するために、元のカバーを最大何画素で
    /// 復号すればよいか。
    ///
    /// **切って捨てるぶんを見込んで大きめに求める** ―― 幅を半分に切る画像を必要な幅ちょうどで
    /// 復号すると、切った後は半分になってしまう。元の比はDBに控えてある
    /// (CollectionItem.coverAspect)ので、復号する前に必要な大きさが分かる。
    ///
    /// 保存してあるカバーは長辺768px(CollectionCoverStore.maxPixelSize)までなので、それを
    /// 超える指定をしても元より大きくはならない(ImageIOは引き伸ばさない)。
    ///
    /// 表示のセル(CollectionCoverThumbnail)と、焼いた札の合成(CollectionTileImageStore.compose)の
    /// **両方がここを見る** ―― 同じ絵を2通りの見積もりで復号すると、焼いた札と生のセルで
    /// 精細さが食い違う。
    ///
    /// - Parameters:
    ///   - croppedWidth: 切り出した**後**に欲しい幅(画素)。
    ///   - targetAspect: 枠の比(幅 ÷ 高さ)。
    ///   - imageAspect: 元のカバーの比。0以下(まだ分からない)なら枠の比とみなす。
    static func decodePixelSize(
        croppedWidth: CGFloat, targetAspect: CGFloat, imageAspect: CGFloat
    ) -> CGFloat {
        let neededWidth = max(1, croppedWidth)
        guard targetAspect > 0 else { return neededWidth }
        let imageAspect = imageAspect > 0 ? imageAspect : targetAspect
        if imageAspect > targetAspect {
            // 左右を切る。切った後の幅がneededWidthになるように、元の幅を逆算する。
            return neededWidth / targetAspect * max(imageAspect, 1)
        } else {
            // 上下を切る。幅はそのまま残るので、長辺(高さ)のぶんだけ見込む。
            return neededWidth * max(1, 1 / max(imageAspect, 0.01))
        }
    }

    /// この比の画像を枠へ収めるとき、実際にどこかを切ることになるか。
    ///
    /// メタデータ編集で「残す位置」の指定を有効にするかどうかの判定に使う ―― 比がぴったり
    /// 合っている本に位置を選ばせても、選んだ結果が何も変わらない。判定は画素数ではなく比だけで
    /// 行うため、cropped(_:to:anchor:)の整数丸めと厳密に一致させる必要は無い(1%の差は
    /// 「切らない」として扱う)。
    static func cropsAnyEdge(imageAspect: CGFloat, targetAspect: CGFloat) -> Bool {
        guard imageAspect > 0, targetAspect > 0 else { return false }
        return abs(imageAspect - targetAspect) > targetAspect * 0.01
    }
}

import Foundation
import CoreGraphics

/// 横長のカバーを縦長へ切るとき、**実際にどちら側を残したか**。CollectionItem.coverCropSideに
/// 保存する。読み方向の既定が変わったときに「作り直すべき本」を選ぶために覚えておく
/// (`.none`=切っていない本は、読み方向が変わってもカバーの見た目が変わらない)。
nonisolated enum CoverCropSide: Int, Sendable {
    case none = 0
    case left = 1
    case center = 2
    case right = 3
}

/// 横長のカバーのどこを見せるか、という**ユーザーの指定**(BookLayoutSettings.coverCropAnchorRaw)。
/// nilは「自動」= 読み方向から決める(CoverImageResolver.croppedForGrid参照)。
///
/// rawValueを明示的な文字列にしてあるのは、そのままDBとJSONに書くため
/// (ReadingDirection.stableIDと同じ理由。表示文言を変えても保存済みの値が壊れないように)。
nonisolated enum CoverCropAnchor: String, Sendable, CaseIterable {
    case left
    case center
    case right
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
    /// コレクションのタイル/セルの縦横比(幅 ÷ 高さ)。横長のカバーはこの比へ切って保存する。
    /// 表示側(CollectionCoverThumbnail)も同じ値を使う。
    static let gridAspectRatio: CGFloat = 2.0 / 3.0

    /// DB(BookLayoutSettings / PageLayoutOverride / 環境設定)から、メインアクターの外へ
    /// 持ち出すための値のスナップショット。組み立てるのは
    /// `LayoutStore.coverOverrideSnapshot(forBookID:defaultReadingDirection:)`。
    struct OverrideSnapshot: Sendable {
        /// 本に含まれる既存ページをカバーに指定している場合、そのPageRef.sortKey。
        var coverPageKey: String?
        /// 本に含まれない専用ファイルをカバーに指定している場合、その解決済みURL。
        var externalCoverURL: URL?
        /// ページ順序の補正(未設定ならnil)。
        var pageOrderOverride: [String]?
        /// 除外されているページのキー。
        var excludedKeys: Set<String> = []
        /// この本の**実効の**読み方向(本ごとの上書きがあればそれ、無ければ環境設定の既定)。
        var readingDirection: ReadingDirection = .rightToLeft
        /// 横長カバーの見せ方のユーザー指定。nil = 自動(読み方向に従う)。
        var cropAnchor: CoverCropAnchor?

        init(
            coverPageKey: String? = nil,
            externalCoverURL: URL? = nil,
            pageOrderOverride: [String]? = nil,
            excludedKeys: Set<String> = [],
            readingDirection: ReadingDirection = .rightToLeft,
            cropAnchor: CoverCropAnchor? = nil
        ) {
            self.coverPageKey = coverPageKey
            self.externalCoverURL = externalCoverURL
            self.pageOrderOverride = pageOrderOverride
            self.excludedKeys = excludedKeys
            self.readingDirection = readingDirection
            self.cropAnchor = cropAnchor
        }
    }

    /// この本のカバー画像を、最大`maxPixelSize`で復号する。失敗した場合はnil。
    ///
    /// 呼び出し側は、サンドボックスでアクセス権が必要なURLに対して、あらかじめ
    /// `startAccessingSecurityScopedResource()`を呼んでおくこと(この関数は本体URLの
    /// アクセス権の開始/終了を行わない。外部カバーファイルのぶんだけはここで面倒を見る ――
    /// あちらのURLはこの関数の中で初めて出てくるため)。
    ///
    /// - Parameter cachesPageList: 読み込んだ本のページ一覧をディスクキャッシュ
    ///   (BookPageListCache)へ書き戻すか。単体テストはfalseで呼ぶ(実物のアプリと同じ
    ///   保存先へテスト用の本の痕跡を残さないため)。
    static func coverImage(
        bookAt url: URL, snapshot: OverrideSnapshot, maxPixelSize: CGFloat,
        cachesPageList: Bool = true
    ) async -> CGImage? {
        // 1. 本に含まれない専用ファイルが指定されていれば、本体を開かずにそれを読む。
        if let externalURL = snapshot.externalCoverURL {
            let didAccess = externalURL.startAccessingSecurityScopedResource()
            defer { if didAccess { externalURL.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: externalURL) else { return nil }
            return ImageDecoder.decode(data, maxPixelSize: maxPixelSize)
        }

        // 2. 本を読み込んで、対象のページを決める。
        guard let book = try? await BookLoader.load(from: url, cachesPageList: cachesPageList),
              !book.pages.isEmpty
        else { return nil }
        guard let target = targetPage(in: book, snapshot: snapshot),
              let index = book.pages.firstIndex(where: { $0.sortKey == target.sortKey })
        else { return nil }

        // 3. 復号。カバーは512px程度の小さな画像なので、grid用の経路をそのまま借りる。
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

    /// グリッド向けの整形(ユーザー要望 2026-09-09)。
    ///
    /// 横長(width > height)の画像は、左右どちらかの端を残して縦長(2:3)へ切る。
    /// `anchor`がnil(自動)のときは読み方向で決める ―― 右開きなら**左側**、左開きなら**右側**。
    /// 見開き1枚をそのままカバーにしている本で、表紙にあたる側が残る。
    /// `anchor`が指定されていれば読み方向に関わらずそれに従う。
    ///
    /// 縦長・正方形の画像はそのまま返す(`cropSide == .none`)。切った結果はそのまま保存するので、
    /// 表示のたびに切り直す処理は無い。
    static func croppedForGrid(
        _ image: CGImage, readingDirection: ReadingDirection, anchor: CoverCropAnchor?
    ) -> (image: CGImage, cropSide: CoverCropSide) {
        let width = image.width
        let height = image.height
        guard width > height else { return (image, .none) }

        // 高さは残したまま、幅だけを 2:3 に詰める。極端に横長(パノラマ)でも同じ計算でよい。
        let targetWidth = max(1, Int((CGFloat(height) * gridAspectRatio).rounded()))
        guard targetWidth < width else { return (image, .none) }

        let side: CoverCropSide
        switch anchor {
        case .left: side = .left
        case .center: side = .center
        case .right: side = .right
        case nil:
            // 自動。右開き(rightToLeft)の本は右から左へ読むので、見開きの**左端**が表紙。
            side = readingDirection == .rightToLeft ? .left : .right
        }
        let originX: Int
        switch side {
        case .left, .none: originX = 0
        case .center: originX = (width - targetWidth) / 2
        case .right: originX = width - targetWidth
        }
        let rect = CGRect(x: originX, y: 0, width: targetWidth, height: height)
        guard let cropped = image.cropping(to: rect) else { return (image, .none) }
        return (cropped, side)
    }
}

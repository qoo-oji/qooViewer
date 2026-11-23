import CoreGraphics

/// PDF の 1 ページを「Finder(PDFKit)で見たとおり」に描くための寸法と座標変換。
///
/// ■ なぜ 1 か所にまとめたか(2026-11-23)
/// 「一部の PDF が qooViewer でだけ天地逆に表示される(Finder では正しい)」という報告から。原因は、ビューアの描画
/// (PageLoader.renderPDFPixels)がページの `/Rotate`(表示するときに時計回りに何度回すか)を見ず、MediaBox をそのまま描いていた
/// こと。スキャンして天地が逆だったページをプレビュー等で「回転」して保存すると、画像はそのままで `/Rotate 180` だけが書き込まれる
/// ので、qooViewer でだけ逆さまに出ていた。一方ファイルブラウザのアイコン(BookThumbnailer.render)だけは `/Rotate` と CropBox を
/// 見ていて、アプリの中でも画面によって向きが食い違っていた。PDF のページを描く・寸法を答える所はすべてこれを通す
/// (表示・サムネイル・寸法・情報を見る・PDF 書き出し・EPUB/CBZ 書き出しの画像の向き)。
///
/// ■ 決まりごと(すべて PDFKit と突き合わせて実測、2026-11-23)
/// - 表示する枠は **CropBox と MediaBox の重なり**(PDF の仕様。ユーザー判断で Finder に揃えた)。CGPDFPage.getBoxRect(.cropBox) は
///   CropBox が無ければ MediaBox を返すが、MediaBox からはみ出した CropBox を**切らずにそのまま**返す(PDFKit は切る)。重なりが
///   無い壊れた箱なら MediaBox を使う。
/// - `rotationAngle` は親の `/Pages` から継承した値も返すが、**正規化しない**(-180 や 540 がそのまま来る)。90 の倍数でない値は
///   PDFKit がいちばん近い 90° 単位へ丸める(45 → 90、135 → 180、100 → 90)ので、同じに丸める。
/// - `/Rotate` は時計回り。90°/270° では幅と高さが入れ替わる。
nonisolated struct PDFPageGeometry: Sendable, Equatable {
    /// 描く枠(PDF のユーザー空間。CropBox ∩ MediaBox)。
    let box: CGRect
    /// 時計回りの回転。0 / 90 / 180 / 270 のどれか。
    let rotation: Int

    /// 寸法が使えないページ(壊れた・細工された箱。CGRect.hasUsablePDFPageSize)では nil。
    init?(page: CGPDFPage) {
        self.init(
            mediaBox: page.getBoxRect(.mediaBox), cropBox: page.getBoxRect(.cropBox),
            rotationAngle: Int(page.rotationAngle)
        )
    }

    init?(mediaBox: CGRect, cropBox: CGRect, rotationAngle: Int) {
        let clipped = cropBox.intersection(mediaBox)
        let box = clipped.hasUsablePDFPageSize ? clipped : mediaBox
        guard box.hasUsablePDFPageSize else { return nil }
        self.box = box
        self.rotation = Self.normalizedRotation(rotationAngle)
    }

    /// 回転だけを差し替えたもの(利用者がビューアで回したページ ―― PageRotationOverride。ファイルの `/Rotate` を**置き換える**)。
    /// nil ならそのまま。
    func overridingRotation(_ rotation: Int?) -> PDFPageGeometry {
        guard let rotation else { return self }
        return PDFPageGeometry(box: box, rotation: Self.normalizedRotation(rotation))
    }

    private init(box: CGRect, rotation: Int) {
        self.box = box
        self.rotation = rotation
    }

    /// `/Rotate` の値を 0 / 90 / 180 / 270 へ(PDFKit と同じ丸め。型のコメント)。
    static func normalizedRotation(_ angle: Int) -> Int {
        let quarterTurns = Int((Double(angle) / 90).rounded(.toNearestOrAwayFromZero))
        return ((quarterTurns % 4) + 4) % 4 * 90
    }

    /// 横倒し(90°/270°)か。幅と高さが入れ替わる。
    var isSideways: Bool { rotation == 90 || rotation == 270 }

    /// 回転を反映した、見たときの寸法(pt)。
    var displayedSize: CGSize {
        isSideways ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// 見たときの寸法を pt の整数に丸めたもの(PageLoader.pageSize・「情報を見る」が答える値)。
    var displayedPointSize: (width: Int, height: Int) {
        let size = displayedSize
        return (Int(size.width.rounded()), Int(size.height.rounded()))
    }

    /// 倍率 `scale`(pt → px)で描いたときの画素の寸法。
    func pixelSize(scale: CGFloat) -> (width: Int, height: Int) {
        let size = displayedSize
        return (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }

    /// 長辺・短辺を `maxPixelSize` に収める倍率(拡大もする)。
    func scale(fittingLongSide maxPixelSize: CGFloat) -> CGFloat {
        let size = displayedSize
        return min(maxPixelSize / size.width, maxPixelSize / size.height)
    }

    /// 原点が左下の描き先(画素で `pixelSize(scale:)` の大きさ)へ、倍率・回転・枠の原点を掛けて枠で切る。
    /// このあと `drawPDFPage` すれば、PDFKit で見たとおりの向きと範囲で描かれる。
    /// `CGPDFPage.getDrawingTransform` は拡大しない(縮小だけ)ので使わない。
    func prepare(_ context: CGContext, scale: CGFloat) {
        context.scaleBy(x: scale, y: scale)
        Self.applyClockwiseRotation(rotation, to: context, width: box.width, height: box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
    }

    /// 幅 `width`・高さ `height` のものを時計回りに `rotation` 度回して、原点が左下の描き先に収める変換を掛ける
    /// (90°/270° なら描き先は高さ×幅)。EXIF の向き 6(時計回り 90°)・3・8 と同じ変換 ―― ページから取り出した画像を回すときは
    /// その向きの指定として OrientationBaking.drawn を通す(PDFImageExtractor.rotatedClockwise)。
    static func applyClockwiseRotation(_ rotation: Int, to context: CGContext, width: CGFloat, height: CGFloat) {
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: width)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: width, y: height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: height, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
    }
}

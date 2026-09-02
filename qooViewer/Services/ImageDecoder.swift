import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// ImageIOを使った、シンプルなページ画像デコーダー。
///
/// `CGImageSourceCreateThumbnailAtIndex` を使うことで、
/// - 指定した最大ピクセルサイズへのダウンサンプリング(巨大なスキャン画像でも高速)
/// - EXIFの回転情報の自動反映
/// を1回の呼び出しで行う。ページ全体の表示にも、プログレスバーの小さいサムネイルにも
/// この同じ関数を使い、maxPixelSize だけを変える。
/// nonisolated: Xcode 26 (Swift 6.2)からの新規プロジェクトは既定で「Default Actor Isolation = MainActor」
/// になっており、注釈のない型は暗黙的にMainActor専用になる。ここはPageLoader(actor、メインスレッド外)
/// から呼ばれるため、明示的にnonisolatedを付けて「どのアクターからでも呼べる」ことを保証している。
nonisolated enum ImageDecoder {
    /// ページ表示用の最大ピクセルサイズ(Retina画面でも十分な解像度)
    static let pageMaxPixelSize: CGFloat = 4096
    /// プログレスバーのホバー時プレビュー用サムネイルの最大ピクセルサイズ
    static let progressBarThumbnailMaxPixelSize: CGFloat = 240
    /// 画像のエクスポート機能(要望)向け: 「見開きを結合してエクスポート」で使う最大ピクセルサイズ。
    /// 通常の表示用(pageMaxPixelSize、4096)のまま結合すると、それより高解像度のスキャン画像は
    /// 表示用に落とした解像度で書き出されてしまい、要望の「元の画像ファイルの解像度は維持する」
    /// を満たせない。実務上のスキャン画像がここまでの解像度に達することはまず無いという前提で、
    /// 安全のため上限だけは設けておく(無制限にすると巨大画像で不必要にメモリを消費するリスクが
    /// あるため)。
    static let exportMaxPixelSize: CGFloat = 20000
    /// 拡大して見るとき(拡大鏡=ルーペ、およびピンチイン・ピンチアウトによる拡大)のソースに使う
    /// 最大ピクセルサイズ。通常の表示用(pageMaxPixelSize、4096)より高解像度にしつつ、
    /// exportMaxPixelSize(20000、ページ全体を1枚メモリに保持すると巨大になりうる)ほどは上げない
    /// 中間の値(1枚あたり最大で8000×8000×4byte≈256MB程度)。
    /// 現在表示中の見開き分だけを対象に、ページ切替のたびに1回だけデコードする設計のため
    /// (ViewerViewModel.highResolutionSourceImages参照)、常時保持されるのは高々1〜2枚。
    static let highResolutionMaxPixelSize: CGFloat = 8000

    /// デコードを引き受ける元画像の画素数の上限(20000×20000 = 4億画素)。
    ///
    /// `CGImageSourceCreateThumbnailAtIndex`はJPEG以外(PNG/WebP/GIF/BMP/TIFF)では元画像を
    /// フル解像度で展開してから縮小するため、一時メモリは出力サイズではなく**元画像の
    /// 大きさ**で決まる。ヘッダーに巨大な寸法を書いた画像(細工されたファイル、または壊れた
    /// ファイル)を渡すと、Image I/Oがその画素数ぶんの確保を試みてアプリごと落ちうる
    /// (監査で指摘)。ヘッダーの寸法は展開せずに読めるので、先に確かめる。
    /// 上限はexportMaxPixelSize(書き出しで許している1辺)の正方形に揃えてある ―― 実在する
    /// ページ画像がこれに達することはなく、拒否によって読めなくなる本は無い。
    static let maxSourcePixelCount = Int(exportMaxPixelSize) * Int(exportMaxPixelSize)

    static func decode(_ data: Data, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        guard hasAcceptablePixelCount(source) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // ImageIO自身のキャッシュには載せない(sourceOptionsのコメント参照)。
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 元画像の画素数がmaxSourcePixelCount以下か(decodeのコメント参照)。ヘッダーの解析だけ
    /// なので、デコード本体に比べれば無視できる(かつ、この直後のデコードがImage I/Oの
    /// 内部で同じヘッダーを読む)。寸法が取れないファイルはImage I/Oの判断に任せる
    /// (=従来どおり通す。形式によってプロパティが欠けても読めなくならないように)。
    private static func hasAcceptablePixelCount(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return true }
        guard width > 0, height > 0 else { return false }
        // 溢れよけ: 一辺だけで既に上限を超える寸法は掛けずに弾く。
        let limit = Int(exportMaxPixelSize)
        if width > limit * limit || height > limit * limit { return false }
        return width * height <= maxSourcePixelCount
    }

    /// 画像全体をデコードせず、ヘッダー部分だけから読み取れる情報(ピクセルサイズ・色空間・
    /// カラープロファイル・アルファチャンネルの有無)。PageLoader.pageImageInfo(at:)
    /// (コンテキストメニュー「情報を見る」、ユーザー要望)向け。colorModel/colorProfileNameは
    /// フォーマットによっては取得できないことがある(その場合nil)。
    struct HeaderInfo {
        let pixelWidth: Int
        let pixelHeight: Int
        /// 例: "RGB"、"Gray"、"CMYK"。
        let colorModel: String?
        /// ICCカラープロファイル名(例: "sRGB IEC61966-2.1")。
        let colorProfileName: String?
        let hasAlpha: Bool
    }

    /// 画像全体をデコードせず、ヘッダー部分だけを読み取る(CGImageSourceCopyPropertiesAtIndexは
    /// フォーマットのヘッダー構造体(JPEGのSOFマーカー、PNGのIHDRチャンク等)だけを解析するため、
    /// 画像の解像度に関わらずほぼ一瞬で終わる)。
    static func headerInfo(of data: Data) -> HeaderInfo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return headerInfo(from: source)
    }

    /// headerInfo(of:)のファイルURL版。
    ///
    /// フォルダの本(PageSource.file)のように、画像が独立したファイルとして存在する場合に使う。
    /// Dataを経由する版と違い、ファイル全体をメモリへ読み込まない: CGImageSourceCreateWithURLは
    /// Image I/Oが必要な範囲だけをファイルから逐次読むため、ヘッダーの解析に必要な先頭の
    /// 数KBしか実際には触らない。
    ///
    /// 経緯: 以前はフォルダの本でも、ページの縦横比を知りたいだけの場面(横長判定。
    /// ViewerViewModel.warmUpWideImageCacheForEntireBookが本を開いた直後に全ページへ行う)で
    /// PageLoader.rawData経由のData(contentsOf:)を使っており、幅と高さを得るためだけに画像
    /// ファイルを丸ごと読み込んでいた。1冊あたりの総読み込み量がページ数×ファイルサイズに
    /// なるため、高解像度スキャンのフォルダ本を開いた直後に大量のディスクI/Oが発生していた。
    static func headerInfo(ofFileAt url: URL) -> HeaderInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return headerInfo(from: source)
    }

    /// kCGImageSourceShouldCache: false — Image I/Oにデコード結果を保持させない。
    ///
    /// ヘッダーの問い合わせ(headerInfo)では、そもそもデコード結果を持たせる意味が無い。
    /// decode(_:maxPixelSize:)でも不要で、しかも害がある: 既定(true)のままだと、Image I/Oは
    /// 作ったサムネイルを自前のキャッシュに抱え込み、呼び出し側がCGImageを手放した後も
    /// 本1冊ぶん(実測で30枚、1枚47〜59MB)が居座り続ける。大半はpurgeable(揮発)として
    /// OSが回収できる状態だが、一部は常駐のまま残り、数百MBの差になっていた。
    /// PageLoaderはデコード結果を即座にPagePixelBufferへ描き写して自分で保持するので、
    /// Image I/O側のキャッシュは二重に持つだけで役に立たない。
    private static let sourceOptions: CFDictionary =
        [kCGImageSourceShouldCache: false] as CFDictionary

    private static func headerInfo(from source: CGImageSource) -> HeaderInfo? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return HeaderInfo(
            pixelWidth: width,
            pixelHeight: height,
            colorModel: properties[kCGImagePropertyColorModel] as? String,
            colorProfileName: properties[kCGImagePropertyProfileName] as? String,
            hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        )
    }

    /// 画像全体をデコードせず、ヘッダーだけからピクセルサイズを読み取る(EPUB書き出し、
    /// EpubExporterが各ページXHTMLのviewport metaを組み立てるために使う。decode(_:maxPixelSize:)と
    /// 違いフルデコードを伴わないため、書き出し対象の全ページに対して呼んでも軽量)。
    /// headerInfo(of:)の薄いラッパー(ピクセルサイズしか要らない呼び出し元向け)。
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let info = headerInfo(of: data) else { return nil }
        return (info.pixelWidth, info.pixelHeight)
    }

    /// 画像データをPNGへ変換する(EPUB書き出し用)。
    ///
    /// EpubExporterは元の画像のバイト列をそのまま埋め込むのが基本だが、EPUBに直接入れられない
    /// 形式(WebP・HEIC・BMP・TIFF・AVIF)だけはここでPNGへ変換してから入れる。実測で、
    /// これらはKindle Previewerの変換がエラー(E21019)で失敗するか、EPUBCheckが
    /// 「コア画像形式ではないのに代替が無い」(RSC-032)としてエラーにする。PNGは可逆形式なので、
    /// 変換によって元の画像より画質が落ちることはない(ファイルサイズは大きくなりうる)。
    ///
    /// デコードにdecode(_:maxPixelSize:)を使うのは、EXIFの回転指定をここでも反映させるため。
    static func pngData(from data: Data) -> Data? {
        guard let image = decode(data, maxPixelSize: exportMaxPixelSize) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// pixelSize(of:)のファイルURL版(headerInfo(ofFileAt:)の薄いラッパー)。
    static func pixelSize(ofFileAt url: URL) -> (width: Int, height: Int)? {
        guard let info = headerInfo(ofFileAt: url) else { return nil }
        return (info.pixelWidth, info.pixelHeight)
    }
}

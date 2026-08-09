import Foundation
import ImageIO
import CoreGraphics

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

    static func decode(_ data: Data, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 画像全体をデコードせず、ヘッダーだけからピクセルサイズを読み取る(EPUB書き出し、
    /// EpubExporterが各ページXHTMLのviewport metaを組み立てるために使う。decode(_:maxPixelSize:)と
    /// 違いフルデコードを伴わないため、書き出し対象の全ページに対して呼んでも軽量)。
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}

import Foundation
import ImageIO
import CoreGraphics

/// ImageIOを使った、シンプルなページ画像デコーダー。
///
/// `CGImageSourceCreateThumbnailAtIndex` を使うことで、
/// - 指定した最大ピクセルサイズへのダウンサンプリング(巨大なスキャン画像でも高速)
/// - EXIFの回転情報の自動反映
/// を1回の呼び出しで行う。ページ全体の表示にも、スクラバーの小さいサムネイルにも
/// この同じ関数を使い、maxPixelSize だけを変える。
/// nonisolated: Xcode 26 (Swift 6.2)からの新規プロジェクトは既定で「Default Actor Isolation = MainActor」
/// になっており、注釈のない型は暗黙的にMainActor専用になる。ここはPageLoader(actor、メインスレッド外)
/// から呼ばれるため、明示的にnonisolatedを付けて「どのアクターからでも呼べる」ことを保証している。
nonisolated enum ImageDecoder {
    /// ページ表示用の最大ピクセルサイズ(Retina画面でも十分な解像度)
    static let pageMaxPixelSize: CGFloat = 4096
    /// スクラバーのホバー時プレビュー用サムネイルの最大ピクセルサイズ
    static let scrubberThumbnailMaxPixelSize: CGFloat = 240

    static func decode(_ data: Data, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

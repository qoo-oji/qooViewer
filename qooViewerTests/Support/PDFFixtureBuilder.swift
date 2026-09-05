import CoreGraphics
import Foundation
import ImageIO

/// 画像を貼った PDF をテストの中で作る(CoreGraphics の PDF コンテキスト)。
///
/// Document Catalog の項目(読み方向・見開き・アウトライン)はここでは書けない。それらの
/// 「読み取りの正解」は scripts/fixtures/make-pdf.py で作ったコミット済みの PDF が持つ。
/// ここで作るのは、ページの中身(埋め込み画像)が要るテスト ―― PDFImageExtractor と、
/// Exporter の入力になる本 ―― のためのもの。
nonisolated enum PDFFixtureBuilder {
    enum ImageFormat {
        /// JPEG のバイト列をそのまま貼る(DCTDecode として素通しされるはずの経路)。
        case jpeg
        /// 生の CGImage を貼る(Flate で再エンコードされる経路)。
        case png
    }

    static let pageSize = CGSize(width: 200, height: 300)

    /// `pageNumbers` の各番号のページ画像を 1 ページに 1 枚貼った PDF を書く。
    static func write(
        to url: URL, pageNumbers: [UInt8], imageFormat: ImageFormat = .jpeg,
        title: String? = nil, author: String? = nil
    ) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        if let author { info[kCGPDFContextAuthor] = author }
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        for number in pageNumbers {
            context.beginPDFPage(nil)
            context.draw(image(number: number, format: imageFormat), in: mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func image(number: UInt8, format: ImageFormat) -> CGImage {
        switch format {
        case .jpeg:
            let data = PageImageFactory.jpeg(number: number)
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { preconditionFailure("JPEG から CGImage を作れない") }
            return image
        case .png:
            return PageImageFactory.cgImage(number: number)
        }
    }
}

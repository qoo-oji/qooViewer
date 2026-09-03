import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 画像のエクスポート機能(要望): ビューアウインドウが表示している画像ファイルをそのまま
/// エクスポートする。
///
/// 単一ページのエクスポートは、このenum自体は関与しない(呼び出し側がPageLoader.rawImageData(at:)
/// で取得した生データ(デコード前、画質を落とさない)をそのままファイルへ書き込むだけで済むため。
/// ViewerView.exportImage(_:)参照)。このenumは主に「見開きを結合してエクスポート」(2枚の画像を
/// 実際に合成し、新しい画像データとしてエンコードし直す必要がある処理)と、両方のケースで
/// 共通に使うファイル名・拡張子の決定を担当する。
///
/// nonisolated: ViewerView(MainActor)から直接呼ばれる同期的なユーティリティのため、特定の
/// アクターに縛られない(EpubExporterと同じ考え方)。
nonisolated enum ImageExporter {
    enum ExportError: LocalizedError {
        /// 見開きの合成(結合)に失敗した(CGContext/CGImageDestinationの生成失敗など)。
        case combineFailed
        case writeFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .combineFailed:
                return String(localized: "Couldn't create the combined image.", language: AppLanguage.currentLocale)
            case .writeFailed(let underlying):
                return String(
                    format: String(localized: "Couldn't save the image: %@", language: AppLanguage.currentLocale), underlying.localizedDescription
                )
            }
        }
    }

    // MARK: - ファイル名・形式の決定

    /// このページをそのままエクスポートする場合の既定のファイル名(拡張子付き)。
    ///
    /// - Parameter fileExtension: 実際に書き出す形式の拡張子。PDFのページは中の画像の形式
    ///   (JPEG/PNG)を読むまで確定しないため、呼び出し側が
    ///   `ViewerViewModel.exportableImageFileExtension(at:)`で解決したものを渡す。
    ///   省略した場合は`fileExtension(for:)`(PDFなら常にjpg)を使う ―― 見開きの結合など、
    ///   出力形式をこちらで決める用途向け。
    static func defaultFileName(for page: PageRef, fileExtension: String? = nil) -> String {
        "\(baseName(for: page)).\(fileExtension ?? self.fileExtension(for: page))"
    }

    /// 見開きを結合してエクスポートする場合の既定のファイル名。
    /// 要望: 「(前のファイル名)-(後のファイル名).拡張子」。「前・後」は画面上の左右
    /// (読み方向によって入れ替わる)ではなく、常に読み順(ページ番号が若い方が「前」)を基準にする
    /// (呼び出し側がleading/trailingとして、読み順どおりに解決済みのPageRefを渡す)。
    static func defaultMergedFileName(leadingPage: PageRef, trailingPage: PageRef) -> String {
        let ext = mergedFileExtension(leadingPage: leadingPage, trailingPage: trailingPage)
        return "\(baseName(for: leadingPage))-\(baseName(for: trailingPage)).\(ext)"
    }

    /// 結合後に書き出すファイル形式(拡張子)。要望: 元の画像に揃える。左右で形式が異なる場合は
    /// 「前の画像」(読み順で先のページ、leadingPage)に合わせる。
    static func mergedFileExtension(leadingPage: PageRef, trailingPage: PageRef) -> String {
        fileExtension(for: leadingPage)
    }

    /// NSSavePanel.allowedContentTypesに渡すUTType。拡張子からUTTypeを解決できない
    /// (未知の拡張子)場合はJPEGにフォールバックする。
    static func contentType(forExtension ext: String) -> UTType {
        UTType(filenameExtension: ext) ?? .jpeg
    }

    static func fileExtension(for page: PageRef) -> String {
        switch page.source {
        case .file(let url):
            return url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
        case .archive(_, let entryPath):
            let ext = (entryPath as NSString).pathExtension
            return ext.isEmpty ? "jpg" : ext.lowercased()
        case .pdf:
            // PDFページ自体には元のファイル形式が無いため、結合時はJPEGとして書き出す。
            return "jpg"
        }
    }

    /// NFCへ揃えるのは、EPUB/CBZ書き出しと同じ理由(nfcNormalizedForExportのコメント参照)。
    /// 書き出し先はディスク上のフォルダだが、そのままWindowsへ渡されうるファイル名である点は
    /// 書庫の中のエントリ名と変わらない。
    private static func baseName(for page: PageRef) -> String {
        switch page.source {
        case .file(let url):
            return nfcNormalizedForExport(url.deletingPathExtension().lastPathComponent)
        case .archive(_, let entryPath):
            return nfcNormalizedForExport(((entryPath as NSString).lastPathComponent as NSString).deletingPathExtension)
        case .pdf(let pdfURL, let pageIndex):
            return nfcNormalizedForExport("\(pdfURL.deletingPathExtension().lastPathComponent)-\(pageIndex + 1)")
        }
    }

    // MARK: - 見開きの結合

    /// 見開きを構成する2枚の画像を左右に結合し、新しい画像データとしてエンコードする。
    ///
    /// - Parameters:
    ///   - leftImage: 画面上の左に表示されている側の、フルサイズ(ダウンサンプリング無し)の
    ///     CGImage(ViewerViewModel.fullResolutionImage(at:)で取得したもの)。
    ///   - rightImage: 画面上の右に表示されている側の同様の画像。
    ///     呼び出し側(ViewerView)が読み方向に応じてどちらのページを渡すかを解決済みのため、
    ///     ここでは単純に「左」「右」の位置へそのまま描画するだけでよい(要望の「２枚の画像を
    ///     左右どちらに結合するかは右開きと左開きで切り替える」は、この解決の時点で済んでいる)。
    ///   - outputExtension: 書き出すファイル形式(mergedFileExtension参照)。
    ///
    /// 結合の仕様(要望):
    ///   - 解像度は元の画像を維持する。ただし左右で縦の解像度(高さ)が異なる場合、
    ///     高さが低い方に合わせて、もう一方をアスペクト比を保ったまま縮小する
    ///     (どちらか一方だけを歪めて引き伸ばすと画質・見た目を損なうため、縮小のみで揃える)。
    ///   - 幅は、高さ調整後の左右それぞれの幅の合計。
    static func combine(leftImage: CGImage, rightImage: CGImage, outputExtension: String) throws -> Data {
        guard let combinedImage = combinedCGImage(leftImage: leftImage, rightImage: rightImage) else {
            throw ExportError.combineFailed
        }
        guard let data = encode(combinedImage, extension: outputExtension) else { throw ExportError.combineFailed }
        return data
    }

    /// combine(leftImage:rightImage:outputExtension:)からファイルエンコード部分を除いた、
    /// CGImageを直接返す版。拡大鏡(ルーペ)が見開きの境目をまたいで拡大できるよう、2枚の
    /// 高解像度画像を1枚に結合したCGImageをそのまま使いたい場合に用いる(ファイルへ書き出す
    /// 必要が無いため、エンコード・Dataへの変換は行わない。ユーザー報告: 拡大鏡が見開きの
    /// 境目をまたげない)。結合の仕様(解像度維持、高さは低い方に合わせて縮小)はcombine同様。
    static func combinedCGImage(leftImage: CGImage, rightImage: CGImage) -> CGImage? {
        let targetHeight = min(leftImage.height, rightImage.height)

        func scaledWidth(for image: CGImage) -> Int {
            guard image.height != targetHeight, image.height > 0 else { return image.width }
            let ratio = Double(targetHeight) / Double(image.height)
            return max(1, Int((Double(image.width) * ratio).rounded()))
        }

        let leftWidth = scaledWidth(for: leftImage)
        let rightWidth = scaledWidth(for: rightImage)
        let totalWidth = leftWidth + rightWidth
        guard totalWidth > 0, targetHeight > 0 else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: totalWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(totalWidth), height: CGFloat(targetHeight)))

        context.draw(leftImage, in: CGRect(x: 0, y: 0, width: CGFloat(leftWidth), height: CGFloat(targetHeight)))
        context.draw(
            rightImage,
            in: CGRect(x: CGFloat(leftWidth), y: 0, width: CGFloat(rightWidth), height: CGFloat(targetHeight))
        )

        return context.makeImage()
    }

    private static func encode(_ image: CGImage, extension ext: String) -> Data? {
        let type = contentType(forExtension: ext)
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, type.identifier as CFString, 1, nil
        ) else { return nil }

        var options: [CFString: Any] = [:]
        if type == .jpeg {
            // 元がJPEGの場合、画質劣化をできるだけ抑えつつ現実的なファイルサイズに収める。
            // (EPUB書き出しは生データをそのまま複製するため圧縮設定を持たないが、こちらは
            // 結合のため再エンコードが避けられず、初めて圧縮率の指定が必要になる箇所)
            options[kCGImageDestinationLossyCompressionQuality] = 0.92
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    // MARK: - 単一ページの書き出し

    /// このページの生データ(デコード前、画質を落とさない)をそのままファイルへ書き込む。
    static func writeSinglePage(data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(underlying: error)
        }
    }

    /// 結合後の画像データをファイルへ書き込む(writeSinglePageと処理自体は同じだが、
    /// エラーになったときの意味(元ファイルの複製 or 新規生成物)を呼び出し側で区別しやすいよう
    /// 別名で用意している)。
    static func writeCombinedImage(data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(underlying: error)
        }
    }
}

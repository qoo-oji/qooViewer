import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// PDFの1ページに埋め込まれている画像を、再エンコードせずに(または可逆に)取り出すための処理。
///
/// ユーザー要望: EPUB書き出しの対象を、元がPDFの本にも広げたい。その際、
/// - JPEG形式(`/DCTDecode`)は、元のJPEGデータをそのままjpgファイルとして書き出す
/// - Flate可逆圧縮形式(`/FlateDecode`)は、pngファイルへ変換して書き出す
/// - それ以外の形式の画像データを含むPDFは、書き出しに対応しない
///
/// PDFのページを画像としてレンダリングし直す方法(CGContextへ描画してPNG化)もあるが、
/// それでは解像度の選択が必要になり、元の画質を保てない。ここでは埋め込まれている画像
/// オブジェクトそのものを取り出すため、元の画質がそのまま維持される
/// (PDFExporter.exportが、元がJPEGのページでファイルサイズを膨らませないために
/// CGImageSourceCreateImageAtIndexによるパススルーを使っているのと同じ考え方)。
///
/// nonisolated: EpubExporter/BookLoaderと同じくメインスレッド外から呼ばれるため、
/// Xcode 26既定のMainActor自動分離の対象外にしている(ArchiveReading.swift冒頭のコメント参照)。
nonisolated enum PDFImageExtractor {

    /// 取り出せる画像の形式。
    enum ImageFormat {
        /// `/DCTDecode`。埋め込まれているJPEGのバイト列をそのまま書き出せる。
        case jpeg
        /// `/FlateDecode`など、CoreGraphicsが完全に復号してくれる可逆フィルタ。
        /// 復号後のサンプル値からCGImageを組み立て、PNGとしてエンコードし直す。
        case losslessRaw

        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .losslessRaw: return "png"
            }
        }
    }

    enum ExtractionError: LocalizedError {
        /// このページに画像オブジェクトが1つも見つからない(ベクター図形・文字だけのページなど)。
        case noEmbeddedImage(pageNumber: Int)
        /// JPEG/Flate以外の形式(JPEG 2000・CCITT G3/G4・JBIG2など)の画像が含まれている。
        case unsupportedImageFormat(pageNumber: Int)
        /// 画像は見つかったが、データの取り出し・復元に失敗した。
        case imageDataUnavailable(pageNumber: Int)

        var errorDescription: String? {
            switch self {
            case .noEmbeddedImage(let pageNumber):
                return String(
                    format: String(localized: "Page %lld of this PDF has no embedded image, so it can't be exported."),
                    pageNumber
                )
            case .unsupportedImageFormat(let pageNumber):
                return String(
                    format: String(
                        localized: "Page %lld of this PDF uses an image format other than JPEG or Flate (lossless), which isn't supported for export."
                    ),
                    pageNumber
                )
            case .imageDataUnavailable(let pageNumber):
                return String(
                    format: String(localized: "Couldn't read the image on page %lld of this PDF."),
                    pageNumber
                )
            }
        }
    }

    /// 実際にデータを取り出さずに、このページの画像形式だけを調べる。
    ///
    /// 書き出しファイル名の拡張子は、実際に書き込むより前に(ページ一覧を組み立てる段階で)
    /// 決める必要があるため、その用途に使う。ストリームの辞書だけを読むので、画像本体の
    /// 復号・コピーは発生しない。
    static func imageFormat(of page: CGPDFPage, pageNumber: Int) throws -> ImageFormat {
        let stream = try primaryImageStream(of: page, pageNumber: pageNumber)
        return try format(of: stream, pageNumber: pageNumber)
    }

    /// このページの画像を、書き出しにそのまま使えるバイト列として取り出す。
    static func extractImageData(from page: CGPDFPage, pageNumber: Int) throws -> (data: Data, format: ImageFormat) {
        let stream = try primaryImageStream(of: page, pageNumber: pageNumber)
        let imageFormat = try format(of: stream, pageNumber: pageNumber)

        var dataFormat: CGPDFDataFormat = .raw
        guard let copied = CGPDFStreamCopyData(stream, &dataFormat) else {
            throw ExtractionError.imageDataUnavailable(pageNumber: pageNumber)
        }
        let data = copied as Data

        switch imageFormat {
        case .jpeg:
            // CGPDFStreamCopyDataは、最終フィルタがDCTDecodeのストリームについては
            // 復号せずJPEGのバイト列をそのまま返す(dataFormatは.jpegEncoded)。
            // そのままjpgファイルとして書き出せる。
            guard dataFormat == .jpegEncoded else {
                throw ExtractionError.unsupportedImageFormat(pageNumber: pageNumber)
            }
            return (data, .jpeg)
        case .losslessRaw:
            // CoreGraphicsが可逆フィルタを復号済みのサンプル値を返している(.raw)。
            // ここからCGImageを組み立て、PNGとしてエンコードし直す。
            guard dataFormat == .raw,
                  let cgImage = makeImage(from: data, streamDictionary: CGPDFStreamGetDictionary(stream)),
                  let png = pngData(from: cgImage)
            else {
                throw ExtractionError.imageDataUnavailable(pageNumber: pageNumber)
            }
            return (png, .losslessRaw)
        }
    }

    // MARK: - 画像ストリームの特定

    /// Form XObjectをたどる深さの上限。壊れたPDF(自分自身を参照するFormなど)で
    /// 走査が終わらなくなるのを防ぐための保険。実在のPDFでこれほど深く入れ子になることは無い。
    private static let maxFormNestingDepth = 8

    /// 画像ストリームの探索中に結果を溜めるための箱。
    ///
    /// CGPDFDictionaryApplyBlockのブロックへSwiftの変数を直接キャプチャして書き戻すことは
    /// できないため、クラス参照を1つだけinfoポインタで渡し、その中へ結果を貯める。
    private final class Collector {
        var best: CGPDFStreamRef?
        var bestPixelCount: Int = -1
        /// bestに選ばれた画像のピクセル寸法(largestEmbeddedImagePixelSize(of:)が使う)。
        var bestWidth: Int = 0
        var bestHeight: Int = 0
        /// 現在たどっているForm XObjectの深さ(maxFormNestingDepthと比較する)。
        var depth: Int = 0
    }

    /// このページに埋め込まれた画像のうち、いちばん画素数の多いもののピクセル寸法。
    /// 画像を1枚も持たないページ(ベクター描画だけのページ)ではnil。
    ///
    /// primaryImageStream(of:pageNumber:)と同じ「ピクセル数が最大のものがページ本体」という
    /// 見方をそのまま使う(そちらのコメント参照)。ストリームの辞書の`/Width`・`/Height`を
    /// 読むだけで、画像データの復号・コピーは一切行わないため軽い。
    ///
    /// 用途はPageLoader.renderPDFPageの解像度決め。PDFのページは寸法がpt(72dpi基準)でしか
    /// 分からないため、要求された最大ピクセル数まで無条件に引き伸ばすと、実際には中身より
    /// 高い解像度で描くことになり、得るもの無くメモリだけを消費する。
    static func largestEmbeddedImagePixelSize(of page: CGPDFPage) -> (width: Int, height: Int)? {
        guard let pageDictionary = page.dictionary else { return nil }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources), let resources else {
            return nil
        }
        let collector = Collector()
        collectImageStreams(in: resources, collector: collector)
        guard collector.best != nil, collector.bestWidth > 0, collector.bestHeight > 0 else { return nil }
        return (collector.bestWidth, collector.bestHeight)
    }

    /// このページの`/Resources /XObject`から、ページ本体にあたる画像ストリームを1つ選ぶ。
    ///
    /// マンガのPDFは「1ページ = 1枚のスキャン画像」がほとんどだが、透かしや小さな装飾が
    /// 別の画像として一緒に置かれていることがある。そのため単純に最初の1つを採るのではなく、
    /// ピクセル数(幅×高さ)が最大のものをページ本体とみなす。
    ///
    /// Form XObject(`/Subtype /Form`)の中も再帰的に探す。他形式からの変換ツールが作るPDFは、
    /// ページの内容をFormで一段包んでいることが多く、ページ直下の`/XObject`には画像ではなく
    /// そのFormしか無い。以前はページ直下しか見ていなかったため、画像が入っているのに
    /// 「埋め込み画像がありません」として書き出しを断っていた。
    private static func primaryImageStream(of page: CGPDFPage, pageNumber: Int) throws -> CGPDFStreamRef {
        guard let pageDictionary = page.dictionary else {
            throw ExtractionError.noEmbeddedImage(pageNumber: pageNumber)
        }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources), let resources else {
            throw ExtractionError.noEmbeddedImage(pageNumber: pageNumber)
        }

        let collector = Collector()
        collectImageStreams(in: resources, collector: collector)

        guard let stream = collector.best else {
            throw ExtractionError.noEmbeddedImage(pageNumber: pageNumber)
        }
        return stream
    }

    /// `/Resources`の`/XObject`をなめて、画像はcollectorへ、Formはその`/Resources`を再帰で辿る。
    private static func collectImageStreams(in resources: CGPDFDictionaryRef, collector: Collector) {
        guard collector.depth < maxFormNestingDepth else { return }
        var xObjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return }

        CGPDFDictionaryApplyBlock(xObjects, { _, object, info in
            guard let info else { return true }
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream)
            else { return true }

            var subtype: UnsafePointer<Int8>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return true }

            switch String(cString: subtype) {
            case "Image":
                var width: CGPDFInteger = 0
                var height: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(dictionary, "Width", &width)
                CGPDFDictionaryGetInteger(dictionary, "Height", &height)
                let pixelCount = Int(width) * Int(height)
                if pixelCount > collector.bestPixelCount {
                    collector.bestPixelCount = pixelCount
                    collector.best = stream
                    collector.bestWidth = Int(width)
                    collector.bestHeight = Int(height)
                }
            case "Form":
                var formResources: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &formResources),
                      let formResources
                else { return true }
                collector.depth += 1
                PDFImageExtractor.collectImageStreams(in: formResources, collector: collector)
                collector.depth -= 1
            default:
                break
            }
            return true
        }, Unmanaged.passUnretained(collector).toOpaque())
    }

    /// ストリームの`/Filter`を見て、書き出せる形式かどうかを判定する。
    ///
    /// CGPDFStreamCopyDataの戻り値(CGPDFDataFormat)だけで判断しないのは、CoreGraphicsが
    /// 復号できないフィルタ(CCITTFaxDecode・JBIG2Decodeなど)について、圧縮されたままの
    /// バイト列を`.raw`として返す可能性があるため。そのまま「復号済みサンプル値」として
    /// 扱うと、意味を成さない画像が書き出されてしまう。フィルタ名を明示的に確認し、
    /// 安全に扱えるものだけを通す。
    ///
    /// `/ASCII85Decode`・`/ASCIIHexDecode`は、実データのフィルタの前段に置かれる文字符号化で
    /// あり、CoreGraphicsが必ず解いてくれるため、判定では読み飛ばす。
    private static func format(of stream: CGPDFStreamRef, pageNumber: Int) throws -> ImageFormat {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else {
            throw ExtractionError.imageDataUnavailable(pageNumber: pageNumber)
        }
        let filters = filterNames(in: dictionary)
            .filter { $0 != "ASCII85Decode" && $0 != "ASCIIHexDecode" }

        // フィルタが無い = 非圧縮のサンプル値がそのまま入っている。可逆側として扱える。
        guard let terminal = filters.last else { return .losslessRaw }
        switch terminal {
        case "DCTDecode":
            return .jpeg
        case "FlateDecode", "LZWDecode", "RunLengthDecode":
            // いずれもCoreGraphicsが完全に復号する可逆フィルタ。ユーザー指定はFlateのみだが、
            // 同じ経路で正しくPNG化できるうえ、対応しないと拒否する理由が無いため一緒に通す。
            return .losslessRaw
        default:
            // JPXDecode(JPEG 2000)、CCITTFaxDecode、JBIG2Decodeなど。
            throw ExtractionError.unsupportedImageFormat(pageNumber: pageNumber)
        }
    }

    /// `/Filter`は単一の名前、または名前の配列で書かれる。両方の形に対応して名前の並びを返す。
    private static func filterNames(in dictionary: CGPDFDictionaryRef) -> [String] {
        var name: UnsafePointer<Int8>?
        if CGPDFDictionaryGetName(dictionary, "Filter", &name), let name {
            return [String(cString: name)]
        }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Filter", &array), let array else { return [] }
        var names: [String] = []
        for index in 0..<CGPDFArrayGetCount(array) {
            var element: UnsafePointer<Int8>?
            if CGPDFArrayGetName(array, index, &element), let element {
                names.append(String(cString: element))
            }
        }
        return names
    }

    // MARK: - 復号済みサンプル値 → CGImage

    /// 復号済みのサンプル値と画像ストリームの辞書から、CGImageを組み立てる。
    ///
    /// 対応する色空間はDeviceGray/DeviceRGB/DeviceCMYK、CalGray/CalRGB(それぞれGray/RGB相当
    /// として扱う)、ICCBased(`/N`の成分数から相当する色空間を選ぶ)、Indexed(パレット)。
    /// `/ImageMask true`のステンシルマスクは1bitのグレースケールとして扱う。
    ///
    /// `/SMask`(別ストリームで持つアルファチャンネル)は反映しない。マンガのページ画像で
    /// アルファが使われることは実質的に無く、対応すると復号経路がもう1本必要になるため。
    /// 反映しない場合でも、書き出される画像は元の色そのままの不透明な画像になる。
    private static func makeImage(from data: Data, streamDictionary: CGPDFDictionaryRef?) -> CGImage? {
        guard let dictionary = streamDictionary else { return nil }

        var width: CGPDFInteger = 0
        var height: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width),
              CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              width > 0, height > 0
        else { return nil }

        var isImageMask: CGPDFBoolean = 0
        CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &isImageMask)

        var bitsPerComponent: CGPDFInteger = 0
        if !CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bitsPerComponent) {
            // ImageMaskは仕様上必ず1bit。BitsPerComponent自体が省略されていることがある。
            bitsPerComponent = isImageMask != 0 ? 1 : 8
        }

        let colorSpace: CGColorSpace?
        let componentCount: Int
        if isImageMask != 0 {
            colorSpace = CGColorSpaceCreateDeviceGray()
            componentCount = 1
        } else {
            guard let resolved = resolveColorSpace(in: dictionary) else { return nil }
            colorSpace = resolved.colorSpace
            componentCount = resolved.componentCount
        }
        guard let colorSpace else { return nil }

        let bitsPerPixel = componentCount * Int(bitsPerComponent)
        let bytesPerRow = (Int(width) * bitsPerPixel + 7) / 8
        guard data.count >= bytesPerRow * Int(height) else { return nil }

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: Int(width),
            height: Int(height),
            bitsPerComponent: Int(bitsPerComponent),
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// `/ColorSpace`を解決する。名前(DeviceRGBなど)と配列(ICCBased・Indexedなど)の両方に対応する。
    private static func resolveColorSpace(
        in dictionary: CGPDFDictionaryRef
    ) -> (colorSpace: CGColorSpace, componentCount: Int)? {
        var name: UnsafePointer<Int8>?
        if CGPDFDictionaryGetName(dictionary, "ColorSpace", &name), let name {
            return colorSpace(forName: String(cString: name))
        }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "ColorSpace", &array), let array,
              CGPDFArrayGetCount(array) > 0
        else { return nil }

        var familyName: UnsafePointer<Int8>?
        guard CGPDFArrayGetName(array, 0, &familyName), let familyName else { return nil }
        switch String(cString: familyName) {
        case "ICCBased":
            // [/ICCBased ストリーム]。ストリームの`/N`が成分数(1=Gray, 3=RGB, 4=CMYK)。
            var stream: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, 1, &stream), let stream,
                  let streamDictionary = CGPDFStreamGetDictionary(stream)
            else { return nil }
            var componentCount: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(streamDictionary, "N", &componentCount) else { return nil }
            switch componentCount {
            case 1: return (CGColorSpaceCreateDeviceGray(), 1)
            case 3: return (CGColorSpaceCreateDeviceRGB(), 3)
            case 4: return (CGColorSpaceCreateDeviceCMYK(), 4)
            default: return nil
            }
        case "CalRGB":
            return (CGColorSpaceCreateDeviceRGB(), 3)
        case "CalGray":
            return (CGColorSpaceCreateDeviceGray(), 1)
        case "Indexed", "I":
            // [/Indexed 基底色空間 最大インデックス パレット]。1サンプル=1インデックス。
            return indexedColorSpace(from: array)
        case let deviceName:
            return colorSpace(forName: deviceName)
        }
    }

    private static func colorSpace(forName name: String) -> (colorSpace: CGColorSpace, componentCount: Int)? {
        switch name {
        case "DeviceGray", "G", "CalGray": return (CGColorSpaceCreateDeviceGray(), 1)
        case "DeviceRGB", "RGB", "CalRGB": return (CGColorSpaceCreateDeviceRGB(), 3)
        case "DeviceCMYK", "CMYK": return (CGColorSpaceCreateDeviceCMYK(), 4)
        default: return nil
        }
    }

    /// `[/Indexed 基底色空間 最大インデックス パレット]`からインデックス色空間を作る。
    /// パレットは文字列オブジェクトかストリームのどちらでも書けるため、両方に対応する。
    private static func indexedColorSpace(from array: CGPDFArrayRef) -> (colorSpace: CGColorSpace, componentCount: Int)? {
        guard CGPDFArrayGetCount(array) >= 4 else { return nil }

        // 基底色空間(名前で書かれている場合のみ対応。入れ子のICCBasedなどは扱わない)。
        var baseName: UnsafePointer<Int8>?
        guard CGPDFArrayGetName(array, 1, &baseName), let baseName,
              let base = colorSpace(forName: String(cString: baseName))
        else { return nil }

        var lastIndex: CGPDFInteger = 0
        guard CGPDFArrayGetInteger(array, 2, &lastIndex), lastIndex >= 0 else { return nil }

        var paletteData: Data?
        var paletteString: CGPDFStringRef?
        if CGPDFArrayGetString(array, 3, &paletteString), let paletteString,
           let bytes = CGPDFStringGetBytePtr(paletteString) {
            paletteData = Data(bytes: bytes, count: CGPDFStringGetLength(paletteString))
        } else {
            var paletteStream: CGPDFStreamRef?
            var streamFormat: CGPDFDataFormat = .raw
            if CGPDFArrayGetStream(array, 3, &paletteStream), let paletteStream,
               let copied = CGPDFStreamCopyData(paletteStream, &streamFormat), streamFormat == .raw {
                paletteData = copied as Data
            }
        }
        guard let paletteData,
              paletteData.count >= (Int(lastIndex) + 1) * base.componentCount
        else { return nil }

        let indexed = paletteData.withUnsafeBytes { buffer -> CGColorSpace? in
            guard let baseAddress = buffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return CGColorSpace(
                indexedBaseSpace: base.colorSpace, last: Int(lastIndex), colorTable: baseAddress
            )
        }
        guard let indexed else { return nil }
        return (indexed, 1)
    }

    // MARK: - PNGエンコード

    private static func pngData(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

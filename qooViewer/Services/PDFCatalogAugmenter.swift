import Foundation
import CoreGraphics

/// 書き出し済みのPDFへ、Document Catalogにしか置けない情報を後から書き加える。
///
/// ■ なぜこんなものが必要なのか
/// PDFの生成に使っているCoreGraphicsのPDFコンテキスト(`CGContext(_:mediaBox:_:)`)が
/// `auxiliaryInfo`で受け付けるのはDocument Info辞書の項目(Title/Author/Keywords等)だけで、
/// 以下はCoreGraphicsにもPDFKitにも**書き込むための公式APIが存在しない**:
///
/// - `/Metadata` — XMPメタデータ(シリーズ名・巻数。PDFXMPMetadata参照)
/// - `/ViewerPreferences << /Direction … >>` — 読み方向
/// - `/PageLayout` — 見開き強制
///
/// いずれも読み取り側のAPIはある(PDFStructureResolver.resolveLayoutHintが実際に使っている)
/// ため、以前は「読めるが書けない」状態で、PDF書き出しでは読み方向・見開きが失われていた。
///
/// ■ やっていること: 増分更新(incremental update)
/// PDFは仕様上、ファイル末尾に「変更したオブジェクトと新しい相互参照表」を**追記**するだけで
/// 内容を更新できる(ISO 32000-1 §7.5.6)。既存のバイトは1バイトも書き換えないため、
/// ページの内容・しおり・Info辞書はそのまま残る。ここではCatalogオブジェクトの複製に上記の
/// キーを足したものと、XMPを収めたストリームオブジェクトを追記している。
///
/// この方法が現実的なのは、CoreGraphicsの出力が
/// 「`%PDF-1.3` / 古典的な相互参照表 / 非圧縮のCatalog / 暗号化なし」という最も単純な構成に
/// 限られるため(実測で確認)。オブジェクトストリームや相互参照ストリームを使うPDFは扱わず、
/// 構造が想定と違えば何も書かずにunsupportedStructureを投げる(下のapply参照)。
/// **このためこの型は、qooViewer自身がCGPDFContextで書き出した直後のファイル専用**であり、
/// 任意のPDFを編集する汎用機能ではない。
///
/// nonisolated: PDFExporterと同じくメインスレッド外から呼ばれるため
/// (詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated enum PDFCatalogAugmenter {

    /// Catalogへ書き加える内容。すべてnilなら何もしない。
    struct Augmentation {
        /// `/Metadata`が指すストリームへ収めるXMPパケット(PDFXMPMetadata.packetの戻り値)。
        var xmpPacket: Data?
        /// `/ViewerPreferences`の`/Direction`へ書く名前オブジェクト名("R2L"/"L2R")。
        /// 値はPDFStructureResolver.catalogDirectionNameが決める(読み取りと対)。
        var viewerPreferencesDirection: String?
        /// `/PageLayout`へ書く名前オブジェクト名("TwoPageRight"等)。
        /// 値はPDFStructureResolver.catalogPageLayoutNameが決める(読み取りと対)。
        var pageLayout: String?

        var isEmpty: Bool {
            xmpPacket == nil && viewerPreferencesDirection == nil && pageLayout == nil
        }
    }

    enum AugmentError: LocalizedError {
        /// PDFの構造が想定(CoreGraphicsの出力)と違い、安全に追記できなかった。
        case unsupportedStructure
        /// 追記した結果が正しいPDFとして読み戻せなかった。この場合ファイルは追記前へ戻す。
        case verificationFailed
        case ioFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedStructure, .verificationFailed:
                return String(localized: "Couldn't embed the series and layout information into the PDF file.")
            case .ioFailed(let underlying):
                return String(
                    format: String(localized: "Couldn't write the PDF file: %@"),
                    underlying.localizedDescription
                )
            }
        }
    }

    // MARK: - 本体

    /// `url`のPDFへ増分更新を追記する。
    ///
    /// 失敗した場合、ファイルは**呼び出し前とまったく同じ内容へ戻したうえで**エラーを投げる
    /// (追記しかしていないので、元の長さへ切り詰めれば元に戻る。ヘッダのバージョン表記だけは
    /// 上書きするため、元のバイトを控えておいて書き戻す)。中途半端なPDFを残さないための扱いで、
    /// PDFExporterが「書き出しに失敗すると壊れたファイルだけが残る」不具合を直したときと
    /// 同じ考え方。呼び出し元(BookExportViewModel.exportOne)は一時ファイルへ書き出してから
    /// 出力先を置き換えるため、ここで投げても利用者の既存ファイルは失われない。
    static func apply(_ augmentation: Augmentation, to url: URL) throws {
        guard !augmentation.isEmpty else { return }

        let originalLength: UInt64
        let originalHeaderVersionBytes: [UInt8]
        do {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }

            originalLength = try handle.seekToEnd()
            let layout = try readLayout(handle: handle, fileLength: originalLength)
            originalHeaderVersionBytes = layout.headerVersionBytes

            let update = try makeIncrementalUpdate(
                augmentation, layout: layout, appendingAt: originalLength
            )
            try handle.seek(toOffset: originalLength)
            try handle.write(contentsOf: update)
            // `/Metadata`はPDF 1.4で追加された項目。CoreGraphicsは`%PDF-1.3`と宣言するため、
            // 追記した内容に見合うようヘッダも引き上げる(桁数が同じなので既存のオフセットは
            // 1つもずれない)。厳密な1.3リーダーは/Metadataごと無視するだけで壊れはしないが、
            // 宣言と中身は揃えておく。
            if layout.needsVersionBump {
                try handle.seek(toOffset: layout.headerVersionOffset)
                try handle.write(contentsOf: Data(Self.minimumVersionBytes))
            }
            // ここでsynchronize()(fsync)はしない。書き込んだ内容は閉じた時点でOSから見えており、
            // 下の読み直しにはそれで足りる。1冊が数百MBになりうるPDFでディスクへの同期を待つと、
            // 得るもの無く書き出しが目に見えて遅くなる。
        } catch let error as AugmentError {
            throw error
        } catch {
            throw AugmentError.ioFailed(underlying: error)
        }

        // 追記した結果を読み戻して確かめる。ここを通ってはじめて成功とみなす
        // (万一CoreGraphicsの出力形式が変わって解析を誤っても、壊れたPDFを利用者へ
        //  渡さないため。想定外の構造は上のreadLayoutで弾いているので、通常ここは必ず通る)。
        if !verify(augmentation, at: url) {
            restore(url: url, toLength: originalLength, headerVersionBytes: originalHeaderVersionBytes)
            throw AugmentError.verificationFailed
        }
    }

    /// 追記前の状態へ戻す。ここでの失敗はもう報告しようがない(呼び出し元は元のエラーを投げる)。
    private static func restore(url: URL, toLength length: UInt64, headerVersionBytes: [UInt8]) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        try? handle.truncate(atOffset: length)
        if headerVersionBytes.count == minimumVersionBytes.count {
            try? handle.seek(toOffset: headerVersionOffset)
            try? handle.write(contentsOf: Data(headerVersionBytes))
        }
    }

    private static func verify(_ augmentation: Augmentation, at url: URL) -> Bool {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0,
              let catalog = document.catalog
        else { return false }

        if augmentation.xmpPacket != nil {
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream) else { return false }
        }
        if let expected = augmentation.pageLayout {
            guard name(inCatalog: catalog, key: "PageLayout") == expected else { return false }
        }
        if let expected = augmentation.viewerPreferencesDirection {
            var preferences: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(catalog, "ViewerPreferences", &preferences),
                  let preferences, name(inCatalog: preferences, key: "Direction") == expected
            else { return false }
        }
        return true
    }

    private static func name(inCatalog dictionary: CGPDFDictionaryRef, key: String) -> String? {
        var value: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    // MARK: - 追記するバイト列の組み立て

    private static func makeIncrementalUpdate(
        _ augmentation: Augmentation, layout: FileLayout, appendingAt fileOffset: UInt64
    ) throws -> Data {
        var update = Data()
        // 直前が改行で終わっていなければ、追記するオブジェクトの前を区切る。
        if layout.lastByte != 0x0A, layout.lastByte != 0x0D {
            update.append(0x0A)
        }

        /// これから足すオブジェクト番号 -> ファイル先頭からのオフセット。相互参照表に載せる。
        var newObjectOffsets: [Int: UInt64] = [:]

        var catalogEntries: [String] = []
        if let packet = augmentation.xmpPacket {
            let metadataObjectNumber = layout.nextObjectNumber
            newObjectOffsets[metadataObjectNumber] = fileOffset + UInt64(update.count)
            // `/Filter`は付けない。XMPパケットはPDFを解釈しないツールからも素のXMLとして
            // 拾えるよう、非圧縮で置くことがXMP仕様で推奨されている。
            update.append(ascii("""
                \(metadataObjectNumber) 0 obj
                << /Type /Metadata /Subtype /XML /Length \(packet.count) >>
                stream

                """))
            update.append(packet)
            update.append(ascii("\nendstream\nendobj\n"))
            catalogEntries.append("/Metadata \(metadataObjectNumber) 0 R")
        }
        if let pageLayout = augmentation.pageLayout {
            catalogEntries.append("/PageLayout /\(pageLayout)")
        }
        if let direction = augmentation.viewerPreferencesDirection {
            catalogEntries.append("/ViewerPreferences << /Direction /\(direction) >>")
        }

        // Catalogは「元の内容 + 足す項目」で作り直す。元の内容をバイト列のまま持ち回るので、
        // qooViewerが解釈しない項目(/Outlines等)も確実にそのまま引き継がれる。
        newObjectOffsets[layout.catalogObjectNumber] = fileOffset + UInt64(update.count)
        update.append(ascii("\(layout.catalogObjectNumber) 0 obj\n<<"))
        update.append(layout.catalogBody)
        update.append(ascii(" \(catalogEntries.joined(separator: " ")) >>\nendobj\n"))

        let xrefOffset = fileOffset + UInt64(update.count)
        update.append(ascii(makeCrossReferenceSection(newObjectOffsets: newObjectOffsets)))
        update.append(ascii(makeTrailer(layout: layout, newObjectOffsets: newObjectOffsets)))
        update.append(ascii("startxref\n\(xrefOffset)\n%%EOF\n"))
        return update
    }

    /// 追記したオブジェクトだけを載せた相互参照表。
    ///
    /// 先頭の`0 1`(解放オブジェクトの連結リストの先頭)は増分更新でも慣例的に必ず載せる。
    /// 残りはオブジェクト番号ごとに独立した小節にする(番号が連続していなくても構わない)。
    private static func makeCrossReferenceSection(newObjectOffsets: [Int: UInt64]) -> String {
        var section = "xref\n0 1\n0000000000 65535 f \n"
        for objectNumber in newObjectOffsets.keys.sorted() {
            let offset = String(format: "%010llu", newObjectOffsets[objectNumber]!)
            section += "\(objectNumber) 1\n\(offset) 00000 n \n"
        }
        return section
    }

    /// 追記した相互参照表に付けるトレーラ。`/Prev`で元の相互参照表へ繋ぐ。
    private static func makeTrailer(layout: FileLayout, newObjectOffsets: [Int: UInt64]) -> String {
        let size = max(layout.nextObjectNumber, (newObjectOffsets.keys.max() ?? 0) + 1)
        var trailer = "trailer\n<< /Size \(size) /Root \(layout.catalogObjectNumber) 0 R"
        if let info = layout.infoObjectNumber {
            trailer += " /Info \(info) 0 R"
        }
        if let identifier = layout.updatedIdentifier {
            trailer += " /ID \(identifier)"
        }
        trailer += " /Prev \(layout.previousCrossReferenceOffset) >>\n"
        return trailer
    }

    private static func ascii(_ text: String) -> Data {
        Data(text.utf8)
    }

    // MARK: - 既存ファイルの構造の読み取り

    /// 追記に必要な、元のファイルの構造。
    private struct FileLayout {
        /// 元の相互参照表の位置(新しいトレーラの`/Prev`に書く)。
        let previousCrossReferenceOffset: UInt64
        let catalogObjectNumber: Int
        /// Catalog辞書の`<<`と`>>`の間のバイト列(前後の空白も含めそのまま)。
        let catalogBody: Data
        let infoObjectNumber: Int?
        /// 新しいトレーラへ書く`/ID`の配列("[ <…> <…> ]")。元に`/ID`が無ければnil。
        let updatedIdentifier: String?
        /// 次に使えるオブジェクト番号(= 元の`/Size`)。
        let nextObjectNumber: Int
        /// ヘッダのバージョン表記("1.3"など)の3バイト。
        let headerVersionBytes: [UInt8]
        let needsVersionBump: Bool
        /// ファイルの最後の1バイト(区切りの改行が要るかの判定に使う)。
        let lastByte: UInt8

        var headerVersionOffset: UInt64 { PDFCatalogAugmenter.headerVersionOffset }
    }

    /// `%PDF-1.3`の"1.3"が始まる位置。PDFのヘッダは必ずこの並びで始まる(ISO 32000-1 §7.5.2)。
    private static let headerVersionOffset: UInt64 = 5
    /// `/Metadata`を置くために最低限必要なバージョン表記。
    private static let minimumVersionBytes: [UInt8] = Array("1.4".utf8)
    /// 相互参照表とトレーラを読むために末尾から読む最大量。相互参照表は1オブジェクトあたり
    /// 20バイトなので、極端に大きな本(数万オブジェクト)でも十分収まる。
    private static let maximumCrossReferenceLength = 8 * 1024 * 1024
    /// Catalogオブジェクトを読むために読む最大量。Catalogは数十バイトから数百バイト。
    private static let maximumCatalogLength = 64 * 1024
    /// 末尾の`startxref`を探すために読む量。
    private static let trailerSearchLength = 2048

    private static func readLayout(handle: FileHandle, fileLength: UInt64) throws -> FileLayout {
        guard fileLength > headerVersionOffset + 3 else { throw AugmentError.unsupportedStructure }

        let header = try read(handle: handle, at: 0, count: Int(headerVersionOffset) + 3)
        guard Array(header.prefix(5)) == Array("%PDF-".utf8) else {
            throw AugmentError.unsupportedStructure
        }
        let headerVersionBytes = Array(header.suffix(3))

        // 1. 末尾のstartxrefから、最後の相互参照表の位置を得る。
        let tailLength = Int(min(fileLength, UInt64(trailerSearchLength)))
        let tail = try read(handle: handle, at: fileLength - UInt64(tailLength), count: tailLength)
        guard let startxrefRange = lastRange(of: Array("startxref".utf8), in: tail),
              let crossReferenceOffset = integer(in: tail, from: startxrefRange.upperBound)?.value,
              crossReferenceOffset >= 0, UInt64(crossReferenceOffset) < fileLength
        else { throw AugmentError.unsupportedStructure }

        // 2. 相互参照表とトレーラを読む。オブジェクトストリーム/相互参照ストリームを使うPDFでは
        //    ここが`xref`で始まらないため、そこで諦める(型のコメント参照)。
        let crossReferenceLength = Int(min(
            fileLength - UInt64(crossReferenceOffset), UInt64(maximumCrossReferenceLength)
        ))
        let crossReference = try read(
            handle: handle, at: UInt64(crossReferenceOffset), count: crossReferenceLength
        )
        let (objectOffsets, trailerStart) = try parseCrossReferenceTable(crossReference)
        guard let trailerBody = dictionaryBody(in: crossReference, searchingFrom: trailerStart) else {
            throw AugmentError.unsupportedStructure
        }

        // 3. トレーラから、Catalog(/Root)・Info・/ID・/Sizeを取り出す。
        //    暗号化されたPDFは文字列・ストリームの暗号化まで面倒を見る必要があるため扱わない
        //    (PDFExporterはパスワードを設定しないので、自前の出力がこうなることはない)。
        guard find(key: "Encrypt", in: trailerBody) == nil else { throw AugmentError.unsupportedStructure }
        guard let catalogObjectNumber = indirectReference(forKey: "Root", in: trailerBody),
              let size = integerValue(forKey: "Size", in: trailerBody),
              let catalogOffset = objectOffsets[catalogObjectNumber]
        else { throw AugmentError.unsupportedStructure }

        // 4. Catalog辞書の中身をバイト列のまま取り出す。
        guard catalogOffset < fileLength else { throw AugmentError.unsupportedStructure }
        let catalogLength = Int(min(fileLength - catalogOffset, UInt64(maximumCatalogLength)))
        let catalogChunk = try read(handle: handle, at: catalogOffset, count: catalogLength)
        guard let objectHeader = objectHeaderRange(in: catalogChunk, expecting: catalogObjectNumber),
              let catalogBody = dictionaryBody(in: catalogChunk, searchingFrom: objectHeader.upperBound)
        else { throw AugmentError.unsupportedStructure }

        // 既にこれらの項目を持つCatalogは、単純に足すと重複した項目になってしまう。
        // CoreGraphicsの出力には決して現れないため、現れたら想定外として扱う
        // (Catalogは名前と間接参照しか含まない小さな辞書なので、この単純な検査で誤検出しない)。
        for key in ["Metadata", "PageLayout", "ViewerPreferences"] where find(key: key, in: catalogBody) != nil {
            throw AugmentError.unsupportedStructure
        }

        return FileLayout(
            previousCrossReferenceOffset: UInt64(crossReferenceOffset),
            catalogObjectNumber: catalogObjectNumber,
            catalogBody: Data(catalogBody),
            infoObjectNumber: indirectReference(forKey: "Info", in: trailerBody),
            updatedIdentifier: updatedIdentifier(in: trailerBody),
            nextObjectNumber: max(size, (objectOffsets.keys.max() ?? 0) + 1),
            headerVersionBytes: headerVersionBytes,
            needsVersionBump: headerVersionBytes.lexicographicallyPrecedes(minimumVersionBytes),
            lastByte: tail.last ?? 0x0A
        )
    }

    private static func read(handle: FileHandle, at offset: UInt64, count: Int) throws -> [UInt8] {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw AugmentError.unsupportedStructure
        }
        return Array(data)
    }

    /// 古典的な相互参照表を読み、オブジェクト番号 -> オフセットの対応と、`trailer`の位置を返す。
    ///
    /// 項目は仕様上ちょうど20バイト固定だが、19バイトで書く実装も実在するため、
    /// 桁数ではなく「数・数・n/f」というトークンの並びとして読む。
    private static func parseCrossReferenceTable(
        _ bytes: [UInt8]
    ) throws -> (offsets: [Int: UInt64], trailerStart: Int) {
        guard bytes.starts(with: Array("xref".utf8)) else { throw AugmentError.unsupportedStructure }

        var offsets: [Int: UInt64] = [:]
        var position = skipWhitespace(in: bytes, from: 4)
        let trailerKeyword = Array("trailer".utf8)

        while position < bytes.count {
            if matches(trailerKeyword, in: bytes, at: position) {
                return (offsets, position)
            }
            guard let first = integer(in: bytes, from: position),
                  let count = integer(in: bytes, from: first.end), count.value >= 0
            else { throw AugmentError.unsupportedStructure }

            position = count.end
            for index in 0..<count.value {
                guard let offset = integer(in: bytes, from: position),
                      let generation = integer(in: bytes, from: offset.end)
                else { throw AugmentError.unsupportedStructure }
                position = skipWhitespace(in: bytes, from: generation.end)
                guard position < bytes.count else { throw AugmentError.unsupportedStructure }
                let kind = bytes[position]
                position += 1
                guard kind == UInt8(ascii: "n") || kind == UInt8(ascii: "f") else {
                    throw AugmentError.unsupportedStructure
                }
                if kind == UInt8(ascii: "n"), offset.value >= 0 {
                    offsets[first.value + index] = UInt64(offset.value)
                }
            }
            position = skipWhitespace(in: bytes, from: position)
        }
        throw AugmentError.unsupportedStructure
    }

    // MARK: - PDFのバイト列を読むための小道具

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x0C || byte == 0x00
    }

    private static func skipWhitespace(in bytes: [UInt8], from index: Int) -> Int {
        var index = index
        while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
        return index
    }

    /// `index`以降の最初の整数を読む。符号は扱わない(PDFのオフセット・オブジェクト番号は非負)。
    private static func integer(in bytes: [UInt8], from index: Int) -> (value: Int, end: Int)? {
        var position = skipWhitespace(in: bytes, from: index)
        let start = position
        var value = 0
        while position < bytes.count, bytes[position] >= UInt8(ascii: "0"), bytes[position] <= UInt8(ascii: "9") {
            // 桁あふれを避ける(壊れたファイルで極端な桁数が書かれている場合)。
            guard value < Int.max / 16 else { return nil }
            value = value * 10 + Int(bytes[position] - UInt8(ascii: "0"))
            position += 1
        }
        return position > start ? (value, position) : nil
    }

    private static func matches(_ needle: [UInt8], in haystack: [UInt8], at index: Int) -> Bool {
        guard index >= 0, index + needle.count <= haystack.count else { return false }
        return Array(haystack[index..<(index + needle.count)]) == needle
    }

    private static func lastRange(of needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in stride(from: haystack.count - needle.count, through: 0, by: -1)
        where matches(needle, in: haystack, at: start) {
            return start..<(start + needle.count)
        }
        return nil
    }

    /// `N G obj`という並びを読み飛ばす。オブジェクト番号が期待と違えばnil
    /// (相互参照表のオフセットが正しくCatalogを指していることの確認になる)。
    private static func objectHeaderRange(in bytes: [UInt8], expecting objectNumber: Int) -> Range<Int>? {
        guard let number = integer(in: bytes, from: 0), number.value == objectNumber,
              let generation = integer(in: bytes, from: number.end)
        else { return nil }
        let keywordStart = skipWhitespace(in: bytes, from: generation.end)
        guard matches(Array("obj".utf8), in: bytes, at: keywordStart) else { return nil }
        return 0..<(keywordStart + 3)
    }

    /// `index`以降の最初の辞書(`<<` … `>>`)を探し、その**中身**(`<<`と`>>`の間)を返す。
    ///
    /// 入れ子の辞書、文字列リテラル(`(…)`。`\`によるエスケープと括弧の入れ子がある)、
    /// 16進文字列(`<…>`)、注釈(`%`から行末まで)を正しく読み飛ばす。これらを見ないと、
    /// 値の中に現れた`>>`で辞書が終わったと誤認しうる。
    private static func dictionaryBody(in bytes: [UInt8], searchingFrom index: Int) -> [UInt8]? {
        var position = index
        while position + 1 < bytes.count,
              !(bytes[position] == UInt8(ascii: "<") && bytes[position + 1] == UInt8(ascii: "<")) {
            position += 1
        }
        guard position + 1 < bytes.count else { return nil }

        let bodyStart = position + 2
        position = bodyStart
        var depth = 1
        while position < bytes.count {
            let byte = bytes[position]
            if byte == UInt8(ascii: "<"), position + 1 < bytes.count, bytes[position + 1] == UInt8(ascii: "<") {
                depth += 1
                position += 2
            } else if byte == UInt8(ascii: ">"), position + 1 < bytes.count, bytes[position + 1] == UInt8(ascii: ">") {
                depth -= 1
                position += 2
                if depth == 0 { return Array(bytes[bodyStart..<(position - 2)]) }
            } else if byte == UInt8(ascii: "<") {
                // 16進文字列。閉じる`>`まで読み飛ばす。
                position += 1
                while position < bytes.count, bytes[position] != UInt8(ascii: ">") { position += 1 }
                position += 1
            } else if byte == UInt8(ascii: "(") {
                position = skipLiteralString(in: bytes, from: position + 1)
            } else if byte == UInt8(ascii: "%") {
                while position < bytes.count, bytes[position] != 0x0A, bytes[position] != 0x0D { position += 1 }
            } else {
                position += 1
            }
        }
        return nil
    }

    /// `(`の次から始まる文字列リテラルを読み飛ばし、閉じる`)`の次の位置を返す。
    private static func skipLiteralString(in bytes: [UInt8], from index: Int) -> Int {
        var position = index
        var depth = 1
        while position < bytes.count {
            switch bytes[position] {
            case UInt8(ascii: "\\"): position += 2
            case UInt8(ascii: "("): depth += 1; position += 1
            case UInt8(ascii: ")"):
                depth -= 1
                position += 1
                if depth == 0 { return position }
            default: position += 1
            }
        }
        return position
    }

    /// 辞書の中身から`/Key`という名前の位置を探す。値そのものは呼び出し側が読む。
    ///
    /// 名前の直後が区切り(空白・`/`・`[`・`<`・`(`・数字など)であることまでは見ないが、
    /// ここで扱うのはトレーラとCatalogという小さく定型的な辞書に限られる(型のコメント参照)。
    private static func find(key: String, in bytes: [UInt8]) -> Int? {
        let needle = Array("/\(key)".utf8)
        guard bytes.count >= needle.count else { return nil }
        for start in 0...(bytes.count - needle.count) where matches(needle, in: bytes, at: start) {
            // "/Size"が"/SizeExtra"のような別の名前の先頭に一致してしまわないようにする。
            let next = start + needle.count
            if next < bytes.count, isRegularCharacter(bytes[next]) { continue }
            return next
        }
        return nil
    }

    /// PDFの名前を構成しうる文字(区切り文字でも空白でもない文字)か。
    private static func isRegularCharacter(_ byte: UInt8) -> Bool {
        if isWhitespace(byte) { return false }
        return !"()<>[]{}/%".utf8.contains(byte)
    }

    private static func integerValue(forKey key: String, in bytes: [UInt8]) -> Int? {
        guard let valueStart = find(key: key, in: bytes) else { return nil }
        return integer(in: bytes, from: valueStart)?.value
    }

    /// `/Key N G R`という間接参照の、オブジェクト番号Nを返す。
    private static func indirectReference(forKey key: String, in bytes: [UInt8]) -> Int? {
        guard let valueStart = find(key: key, in: bytes),
              let number = integer(in: bytes, from: valueStart),
              let generation = integer(in: bytes, from: number.end)
        else { return nil }
        let keywordStart = skipWhitespace(in: bytes, from: generation.end)
        guard matches([UInt8(ascii: "R")], in: bytes, at: keywordStart) else { return nil }
        return number.value
    }

    /// 新しいトレーラへ書く`/ID`の配列。
    ///
    /// `/ID`は2つの文字列の配列で、1つ目は「そのファイルが最初に作られたときの識別子」、
    /// 2つ目は「最後に更新したときの識別子」と定められている(ISO 32000-1 §14.4)。
    /// 増分更新はまさに「更新」なので、1つ目はそのまま引き継ぎ、2つ目だけを作り直す。
    /// 解析できない書かれ方をしていた場合は、元の配列をそのまま書き写す。
    private static func updatedIdentifier(in trailerBody: [UInt8]) -> String? {
        guard let valueStart = find(key: "ID", in: trailerBody) else { return nil }
        var position = skipWhitespace(in: trailerBody, from: valueStart)
        guard position < trailerBody.count, trailerBody[position] == UInt8(ascii: "[") else { return nil }
        let arrayStart = position
        position += 1

        var hexStrings: [String] = []
        while position < trailerBody.count, trailerBody[position] != UInt8(ascii: "]") {
            if trailerBody[position] == UInt8(ascii: "<") {
                let start = position
                position += 1
                while position < trailerBody.count, trailerBody[position] != UInt8(ascii: ">") { position += 1 }
                position += 1
                hexStrings.append(String(decoding: trailerBody[start..<min(position, trailerBody.count)], as: UTF8.self))
            } else {
                position += 1
            }
        }
        guard position < trailerBody.count else { return nil }

        guard hexStrings.count == 2 else {
            return String(decoding: trailerBody[arrayStart...position], as: UTF8.self)
        }
        return "[ \(hexStrings[0]) <\(randomIdentifier())> ]"
    }

    private static func randomIdentifier() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

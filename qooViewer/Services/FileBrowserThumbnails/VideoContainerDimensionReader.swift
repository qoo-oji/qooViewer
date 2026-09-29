import CoreGraphics
import Foundation

/// AVI / ASF(wmv)/ FLV / Ogg(Theora)/ RealMedia の先頭だけを読み、映像の**表示の縦横**を取り出す(2026-09-29)。
///
/// ■ なぜ要るのか
/// QLMedia(動画の絵を作る QuickLook 拡張)は**要求した大きさへそのまま引き伸ばして**返す。mkv だけでなく、QLMedia が入っている機では
/// mp4 / mov を含む**すべての動画**の絵を QLMedia が作る(2026-09-29 実測: 640×360 の動画に正方形を頼むと、どの形式でも中の円が
/// 0.56 倍の楕円になった)。縦横比を先に読んで要求の大きさを合わせる(`VideoDimensionReader`)。mp4 / mov / ts / mpg などは
/// AVFoundation が読めるが、ここの 5 つは読めない(`AVFoundationErrorDomain -11828`)ので、自分で読む。
///
/// ■ 読むのは寸法のある場所だけ
/// どれも先頭のヘッダにあり、動画の中身は復号しない。形式の仕様全体を実装するものではない ―― 読めなければ nil で、呼び出し側は
/// 正方形で頼む(今までどおり伸びた絵になるだけ)。**ファイルから読んだ値は信用しない**: 位置と大きさは足す前に範囲を確かめ、
/// 寸法は 1〜99,999 の外なら捨てる。
///
/// ■ 確かめた形式(ffmpeg 7.1 で作った実物。`qooViewerTests/Fixtures/video/`)
/// | 形式 | 寸法の場所 | 画素の縦横比 |
/// |---|---|---|
/// | AVI | `avih` の `dwWidth` / `dwHeight`(無ければ映像の `strf`) | `vprp` の `dwFrameAspectRatio`(あれば) |
/// | ASF | 映像の Stream Properties Object の `EncodedImageWidth` / `Height` | Metadata Object の `AspectRatioX` / `Y`(あれば) |
/// | FLV | 先頭のスクリプトタグ `onMetaData` の `width` / `height` | ― |
/// | Ogg | Theora の識別ヘッダの `PICW` / `PICH` | 同じヘッダの `PARN` / `PARD` |
/// | RealMedia | 映像の `MDPR` の型ごとのデータ(`VIDO`)の幅・高さ | ― |
///
/// 読めないもの: `onMetaData` の無い FLV、Theora 以外の Ogg(OGM の映像ヘッダ・VP8 など。作れる道具が無く実物で確かめられなかった)、
/// 映像のビットストリームの中にだけ画素の縦横比を持つもの(MPEG-4 Part 2 の AVI など)。
nonisolated enum VideoContainerDimensionReader {
    /// 読む上限。ヘッダはふつう先頭の数 KB にある。
    static let maxScanBytes = 1024 * 1024

    /// 映像の表示の縦横。対象外の形式・読めない・壊れている、のどれでも nil。**ブロッキングするので FileIO の上で呼ぶ。**
    static func displaySize(of url: URL, container: MediaContainer, maxScanBytes: Int = maxScanBytes) -> CGSize? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxScanBytes), !data.isEmpty else { return nil }
        return displaySize(in: [UInt8](data), container: container)
    }

    static func displaySize(in bytes: [UInt8], container: MediaContainer) -> CGSize? {
        switch container {
        case .avi: avi(bytes)
        case .asf: asf(bytes)
        case .flv: flv(bytes)
        case .ogg: ogg(bytes)
        case .realMedia: realMedia(bytes)
        case .isoBMFF, .matroska: nil
        }
    }

    // MARK: - AVI(RIFF)

    private static func avi(_ bytes: [UInt8]) -> CGSize? {
        guard ascii(bytes, at: 0) == "RIFF", ascii(bytes, at: 8) == "AVI " else { return nil }
        var offset = 12
        var header: CGSize?
        var format: CGSize?
        var aspect: (x: Int, y: Int)?
        var isVideoStream = false
        while let id = ascii(bytes, at: offset), let size = le32(bytes, at: offset + 4) {
            let content = offset + 8
            if id == "LIST" {
                guard let type = ascii(bytes, at: content) else { break }
                // フレームの本体。ヘッダはここまで。
                if type == "movi" { break }
                // `hdrl` / `strl` は中へ降りる(中のチャンクは続けて並んでいるので、入れ子の終わりは追わなくてよい)。
                if type == "hdrl" || type == "strl" {
                    offset = content + 4
                    continue
                }
            }
            switch id {
            case "avih":
                header = validated(width: le32(bytes, at: content + 32), height: le32(bytes, at: content + 36))
            case "strh":
                isVideoStream = ascii(bytes, at: content) == "vids"
            case "strf" where isVideoStream && format == nil:
                // BITMAPINFOHEADER。高さは上下の向きを符号で表す。
                let height = le32(bytes, at: content + 8).map { abs(Int(Int32(truncatingIfNeeded: $0))) }
                format = validated(width: le32(bytes, at: content + 4), height: height)
            case "vprp" where aspect == nil:
                // 上位 16 ビットが横、下位 16 ビットが縦。
                if let packed = le32(bytes, at: content + 20), packed >> 16 > 0, packed & 0xFFFF > 0 {
                    aspect = (packed >> 16, packed & 0xFFFF)
                }
            default:
                break
            }
            // チャンクは偶数の境界に揃える。
            guard let next = advance(content, by: size + (size & 1), limit: bytes.count) else { break }
            offset = next
        }
        guard let size = header ?? format else { return nil }
        guard let aspect else { return size }
        return validated(width: size.height * Double(aspect.x) / Double(aspect.y), height: size.height)
    }

    // MARK: - ASF(wmv)

    private static let asfHeaderObject: [UInt8] = [
        0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
    ]
    private static let asfStreamProperties: [UInt8] = [
        0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65,
    ]
    private static let asfVideoStream: [UInt8] = [
        0xC0, 0xEF, 0x19, 0xBC, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B,
    ]
    private static let asfHeaderExtension: [UInt8] = [
        0xB5, 0x03, 0xBF, 0x5F, 0x2E, 0xA9, 0xCF, 0x11, 0x8E, 0xE3, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65,
    ]
    private static let asfMetadata: [UInt8] = [
        0xEA, 0xCB, 0xF8, 0xC5, 0xAF, 0x5B, 0x77, 0x48, 0x84, 0x67, 0xAA, 0x8C, 0x44, 0xFA, 0x4C, 0xCA,
    ]

    private static func asf(_ bytes: [UInt8]) -> CGSize? {
        guard matches(bytes, at: 0, asfHeaderObject), let headerSize = le64(bytes, at: 16) else { return nil }
        // Header Object: GUID(16) 大きさ(8) 個数(4) 予約(2)。中のオブジェクトは 30 バイト目から。
        let end = min(bytes.count, clamped(headerSize))
        var encoded: CGSize?
        var aspect: (x: Int, y: Int)?
        walkASFObjects(bytes, from: 30, to: end) { start, objectEnd in
            if matches(bytes, at: start, asfStreamProperties), matches(bytes, at: start + 24, asfVideoStream), encoded == nil {
                // 型ごとのデータは 78 バイト目から。先頭が `EncodedImageWidth` / `EncodedImageHeight`。
                encoded = validated(width: le32(bytes, at: start + 78), height: le32(bytes, at: start + 82))
            } else if matches(bytes, at: start, asfHeaderExtension) {
                // Header Extension Object: GUID(16) 大きさ(8) 予約(16 + 2) データの大きさ(4)。中のオブジェクトは 46 バイト目から。
                walkASFObjects(bytes, from: start + 46, to: objectEnd) { inner, innerEnd in
                    if matches(bytes, at: inner, asfMetadata), aspect == nil {
                        aspect = asfAspect(bytes, from: inner + 24, to: innerEnd)
                    }
                }
            }
        }
        guard let encoded else { return nil }
        guard let aspect else { return encoded }
        // `AspectRatioX` / `Y` は画素の縦横比。
        return validated(width: encoded.width * Double(aspect.x) / Double(aspect.y), height: encoded.height)
    }

    /// `from`〜`to` に並ぶ ASF のオブジェクト(GUID 16 + 大きさ 8 + 中身)を順に渡す。
    private static func walkASFObjects(_ bytes: [UInt8], from: Int, to: Int, _ body: (_ start: Int, _ end: Int) -> Void) {
        var offset = from
        let limit = min(to, bytes.count)
        while offset >= 0, offset + 24 <= limit, let size = le64(bytes, at: offset + 16), size >= 24,
              let next = advance(offset, by: clamped(size), limit: limit) {
            body(offset, next)
            offset = next
        }
    }

    /// Metadata Object の記録から `AspectRatioX` / `AspectRatioY`(DWORD)を探す。
    private static func asfAspect(_ bytes: [UInt8], from: Int, to: Int) -> (x: Int, y: Int)? {
        guard let count = le16(bytes, at: from) else { return nil }
        var offset = from + 2
        var x: Int?
        var y: Int?
        for _ in 0..<min(count, 256) {
            // 記録: 予約(2) ストリーム番号(2) 名前の長さ(2) 型(2) データの長さ(4) 名前(UTF-16LE) データ。
            guard let nameLength = le16(bytes, at: offset + 4), let type = le16(bytes, at: offset + 6),
                  let dataLength = le32(bytes, at: offset + 8),
                  let nameEnd = advance(offset + 12, by: nameLength, limit: to),
                  let dataEnd = advance(nameEnd, by: dataLength, limit: to)
            else { break }
            let name = String(decoding: stride(from: offset + 12, to: nameEnd - 1, by: 2).map {
                UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
            }, as: UTF16.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            // 型 3 は DWORD。
            if type == 3, dataLength == 4, let value = le32(bytes, at: nameEnd), value > 0 {
                if name == "AspectRatioX" { x = value }
                if name == "AspectRatioY" { y = value }
            }
            offset = dataEnd
        }
        guard let x, let y else { return nil }
        return (x, y)
    }

    // MARK: - FLV

    /// 見るタグの数の上限。`onMetaData` はふつう最初のタグ。
    private static let flvTagLimit = 8

    private static func flv(_ bytes: [UInt8]) -> CGSize? {
        guard ascii(bytes, at: 0, length: 3) == "FLV", let headerSize = be32(bytes, at: 5) else { return nil }
        // ヘッダの後ろに、直前のタグの大きさ(4 バイト)が挟まる。
        guard var offset = advance(0, by: headerSize, limit: bytes.count).flatMap({ advance($0, by: 4, limit: bytes.count) })
        else { return nil }
        for _ in 0..<flvTagLimit {
            // タグ: 種類(1) データの大きさ(3) 時刻(3 + 1) ストリーム ID(3)。
            guard offset + 11 <= bytes.count, let dataSize = be24(bytes, at: offset + 1) else { return nil }
            let dataStart = offset + 11
            let dataEnd = min(bytes.count, dataStart + dataSize)
            if bytes[offset] & 0x1F == 18, let size = flvMetadataSize(bytes, from: dataStart, to: dataEnd) { return size }
            guard let next = advance(dataStart, by: dataSize + 4, limit: bytes.count) else { return nil }
            offset = next
        }
        return nil
    }

    /// スクリプトタグ(AMF0)の `onMetaData` から `width` / `height` を読む。入れ子の値に出会ったら、そこで止める。
    private static func flvMetadataSize(_ bytes: [UInt8], from: Int, to: Int) -> CGSize? {
        var offset = from
        // 文字列 "onMetaData"。
        guard offset < to, bytes[offset] == 0x02, let nameLength = be16(bytes, at: offset + 1),
              let nameEnd = advance(offset + 3, by: nameLength, limit: to),
              ascii(bytes, at: offset + 3, length: nameLength) == "onMetaData"
        else { return nil }
        offset = nameEnd
        // ECMA 配列(0x08、個数 4 バイト)か、オブジェクト(0x03)。
        guard offset < to else { return nil }
        switch bytes[offset] {
        case 0x08: offset += 5
        case 0x03: offset += 1
        default: return nil
        }
        var width: Double?
        var height: Double?
        while width == nil || height == nil {
            guard let keyLength = be16(bytes, at: offset), let keyEnd = advance(offset + 2, by: keyLength, limit: to),
                  keyEnd < to, let key = ascii(bytes, at: offset + 2, length: keyLength)
            else { break }
            let type = bytes[keyEnd]
            let value = keyEnd + 1
            var next: Int?
            switch type {
            case 0x00:
                // 数(8 バイトの倍精度、ビッグエンディアン)。
                next = advance(value, by: 8, limit: to)
                if next != nil, let bits = be64(bytes, at: value) {
                    let number = Double(bitPattern: bits)
                    if key == "width" { width = number }
                    if key == "height" { height = number }
                }
            case 0x01: next = advance(value, by: 1, limit: to)
            case 0x02: next = be16(bytes, at: value).flatMap { advance(value + 2, by: $0, limit: to) }
            case 0x05, 0x06: next = value
            case 0x0B: next = advance(value, by: 10, limit: to)
            case 0x0C: next = be32(bytes, at: value).flatMap { advance(value + 4, by: $0, limit: to) }
            default: next = nil
            }
            guard let next else { break }
            offset = next
        }
        guard let width, let height, width.isFinite, height.isFinite, width >= 1, height >= 1 else { return nil }
        return validated(width: width, height: height)
    }

    // MARK: - Ogg(Theora)

    /// 見るページの数の上限。ストリームの先頭のページ(BOS)は、ファイルの先頭に 1 本ずつ並ぶ。
    private static let oggPageLimit = 16

    private static func ogg(_ bytes: [UInt8]) -> CGSize? {
        var offset = 0
        for _ in 0..<oggPageLimit {
            // ページ: "OggS" 版(1) 種類(1) 位置(8) 通し番号(4) 順番(4) CRC(4) 区切りの数(1) 区切りの表。
            guard ascii(bytes, at: offset) == "OggS", offset + 27 <= bytes.count else { return nil }
            let isFirstPageOfStream = bytes[offset + 5] & 0x02 != 0
            let segmentCount = Int(bytes[offset + 26])
            guard let payload = advance(offset + 27, by: segmentCount, limit: bytes.count) else { return nil }
            let payloadSize = bytes[(offset + 27)..<payload].reduce(0) { $0 + Int($1) }
            // 先頭のページが終わったら、もう識別ヘッダは来ない。
            guard isFirstPageOfStream else { return nil }
            if let size = theoraSize(bytes, at: payload) { return size }
            guard let next = advance(payload, by: payloadSize, limit: bytes.count) else { return nil }
            offset = next
        }
        return nil
    }

    /// Theora の識別ヘッダ: 0x80 "theora" 版(3) FMBW(2) FMBH(2) PICW(3) PICH(3) PICX(1) PICY(1) FRN(4) FRD(4) PARN(3) PARD(3)。
    private static func theoraSize(_ bytes: [UInt8], at offset: Int) -> CGSize? {
        guard offset < bytes.count, bytes[offset] == 0x80, ascii(bytes, at: offset + 1, length: 6) == "theora",
              let width = be24(bytes, at: offset + 14), let height = be24(bytes, at: offset + 17),
              let size = validated(width: width, height: height)
        else { return nil }
        // 画素の縦横比。0 は「指定なし」。
        guard let numerator = be24(bytes, at: offset + 30), let denominator = be24(bytes, at: offset + 33),
              numerator > 0, denominator > 0
        else { return size }
        return validated(width: size.width * Double(numerator) / Double(denominator), height: size.height) ?? size
    }

    // MARK: - RealMedia

    /// 見るチャンクの数の上限。
    private static let realMediaChunkLimit = 64

    private static func realMedia(_ bytes: [UInt8]) -> CGSize? {
        guard ascii(bytes, at: 0) == ".RMF" else { return nil }
        var offset = 0
        for _ in 0..<realMediaChunkLimit {
            // チャンク: 名前(4) 大きさ(4。この 10 バイトのヘッダを含む) 版(2)。
            guard let id = ascii(bytes, at: offset), let size = be32(bytes, at: offset + 4), size >= 10 else { return nil }
            // フレームの本体。ヘッダはここまで。
            if id == "DATA" { return nil }
            let end = min(bytes.count, offset + size)
            if id == "MDPR", let found = realMediaVideoSize(bytes, from: offset + 10, to: end) { return found }
            guard let next = advance(offset, by: size, limit: bytes.count) else { return nil }
            offset = next
        }
        return nil
    }

    /// `MDPR` の中身: ストリーム番号(2) 数値 7 つ(各 4) 名前(長さ 1 + 文字) MIME(長さ 1 + 文字) 型ごとのデータ(長さ 4 + 中身)。
    /// 映像の型ごとのデータ: 大きさ(4) "VIDO" コーデック(4) 幅(2) 高さ(2)。
    private static func realMediaVideoSize(_ bytes: [UInt8], from: Int, to: Int) -> CGSize? {
        let name = from + 30
        guard name < to, let mime = advance(name + 1, by: Int(bytes[name]), limit: to), mime < to,
              let specific = advance(mime + 1, by: Int(bytes[mime]), limit: to),
              let length = be32(bytes, at: specific), length >= 16,
              advance(specific + 4, by: 16, limit: to) != nil,
              ascii(bytes, at: specific + 8) == "VIDO"
        else { return nil }
        return validated(width: be16(bytes, at: specific + 16), height: be16(bytes, at: specific + 18))
    }

    // MARK: - 読み取りの基礎(範囲を確かめてから読む)

    /// `offset + size` が `limit` を超えない整数なら返す(細工された大きさで溢れないように)。
    private static func advance(_ offset: Int, by size: Int, limit: Int) -> Int? {
        guard offset >= 0, size >= 0 else { return nil }
        let (next, overflow) = offset.addingReportingOverflow(size)
        return !overflow && next <= limit ? next : nil
    }

    private static func clamped(_ value: UInt64) -> Int {
        value > UInt64(Int.max) ? Int.max : Int(value)
    }

    private static func unsigned(_ bytes: [UInt8], at offset: Int, length: Int, bigEndian: Bool) -> UInt64? {
        guard offset >= 0, length > 0, length <= 8, offset <= bytes.count - length else { return nil }
        var value: UInt64 = 0
        for index in 0..<length {
            let byte = UInt64(bytes[offset + (bigEndian ? index : length - 1 - index)])
            value = (value << 8) | byte
        }
        return value
    }

    private static func le16(_ bytes: [UInt8], at offset: Int) -> Int? {
        unsigned(bytes, at: offset, length: 2, bigEndian: false).map(Int.init)
    }

    private static func le32(_ bytes: [UInt8], at offset: Int) -> Int? {
        unsigned(bytes, at: offset, length: 4, bigEndian: false).map(Int.init)
    }

    private static func le64(_ bytes: [UInt8], at offset: Int) -> UInt64? {
        unsigned(bytes, at: offset, length: 8, bigEndian: false)
    }

    private static func be16(_ bytes: [UInt8], at offset: Int) -> Int? {
        unsigned(bytes, at: offset, length: 2, bigEndian: true).map(Int.init)
    }

    private static func be24(_ bytes: [UInt8], at offset: Int) -> Int? {
        unsigned(bytes, at: offset, length: 3, bigEndian: true).map(Int.init)
    }

    private static func be32(_ bytes: [UInt8], at offset: Int) -> Int? {
        unsigned(bytes, at: offset, length: 4, bigEndian: true).map(Int.init)
    }

    private static func be64(_ bytes: [UInt8], at offset: Int) -> UInt64? {
        unsigned(bytes, at: offset, length: 8, bigEndian: true)
    }

    private static func ascii(_ bytes: [UInt8], at offset: Int, length: Int = 4) -> String? {
        guard offset >= 0, length > 0, offset <= bytes.count - length else { return nil }
        return String(bytes: bytes[offset..<(offset + length)], encoding: .ascii)
    }

    private static func matches(_ bytes: [UInt8], at offset: Int, _ signature: [UInt8]) -> Bool {
        guard offset >= 0, offset <= bytes.count - signature.count else { return false }
        return Array(bytes[offset..<(offset + signature.count)]) == signature
    }

    private static func validated(width: Int?, height: Int?) -> CGSize? {
        guard let width, let height else { return nil }
        return validated(width: Double(width), height: Double(height))
    }

    private static func validated(width: Double, height: Double) -> CGSize? {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1, width < 100_000, height < 100_000 else { return nil }
        return CGSize(width: width, height: height)
    }
}

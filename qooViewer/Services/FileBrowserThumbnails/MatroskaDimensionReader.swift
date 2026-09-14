import CoreGraphics
import Foundation

/// Matroska(EBML)の先頭だけを読み、映像トラックの `PixelWidth` / `PixelHeight` を取り出す(改善要望7 段階 7b、
/// 2026-09-14。qooLibrary の同名の型を写したもの)。
///
/// ■ なぜ要るのか
/// mkv の絵を作れる QuickLook 拡張のうち、qooLibrary の実測で採用できたのは QLMedia だけで、QLMedia は**要求した大きさへ
/// そのまま引き伸ばして**返す(正方形を頼めば正方形に潰れる)。そこで動画の縦横比を先に読み、要求の大きさを合わせる。
///
/// 読むのは `Segment > Tracks > TrackEntry > Video > PixelWidth/PixelHeight` の経路だけ。動画の中身は復号しない
/// (数 GB のファイルでも先頭の数 KB で済む)。Matroska の仕様全体を実装するものではない。
nonisolated enum MatroskaDimensionReader {
    /// 読む上限。Tracks はふつう先頭の数 KB にある。
    static let maxScanBytes = 8 * 1024 * 1024

    private static let ebmlHeaderID: UInt64 = 0x1A45_DFA3
    private static let segmentID: UInt64 = 0x1853_8067
    /// フレームの本体。ここまで来たら Tracks は無かった。
    private static let clusterID: UInt64 = 0x1F43_B675
    private static let tracksID: UInt64 = 0x1654_AE6B
    private static let trackEntryID: UInt64 = 0xAE
    private static let trackTypeID: UInt64 = 0x83
    private static let videoID: UInt64 = 0xE0
    private static let pixelWidthID: UInt64 = 0xB0
    private static let pixelHeightID: UInt64 = 0xBA
    private static let trackTypeVideo: UInt64 = 1

    /// 映像の縦横。mkv でない・上限の中に Tracks が無い・壊れている、のどれでも nil(呼び出し側は正方形で頼む)。
    /// **ブロッキングするので FileIO の上で呼ぶ。**
    static func dimensions(of url: URL, maxScanBytes: Int = maxScanBytes) -> CGSize? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxScanBytes), data.count > 8 else { return nil }
        return dimensions(in: [UInt8](data))
    }

    static func dimensions(in bytes: [UInt8]) -> CGSize? {
        var offset = 0
        guard let headerID = readElementID(bytes, &offset), headerID == ebmlHeaderID,
              let headerSize = readVINTSize(bytes, &offset), !headerSize.isUnknownSize,
              let afterHeader = advance(offset, by: headerSize.value, limit: bytes.count)
        else { return nil }
        offset = afterHeader

        while offset < bytes.count {
            guard let id = readElementID(bytes, &offset), let size = readVINTSize(bytes, &offset) else { return nil }
            if id == segmentID {
                let end = size.isUnknownSize ? bytes.count : min(bytes.count, offset.addingClamped(size.value))
                return dimensionsInSegment(bytes, offset: offset, end: end)
            }
            guard !size.isUnknownSize, let next = advance(offset, by: size.value, limit: bytes.count) else { return nil }
            offset = next
        }
        return nil
    }

    private static func dimensionsInSegment(_ bytes: [UInt8], offset start: Int, end: Int) -> CGSize? {
        var offset = start
        while offset < end {
            guard let id = readElementID(bytes, &offset), let size = readVINTSize(bytes, &offset), !size.isUnknownSize
            else { return nil }
            let contentEnd = min(end, offset.addingClamped(size.value))
            if id == tracksID { return dimensionsInTracks(bytes, offset: offset, end: contentEnd) }
            if id == clusterID { return nil }
            offset = contentEnd
        }
        return nil
    }

    private static func dimensionsInTracks(_ bytes: [UInt8], offset start: Int, end: Int) -> CGSize? {
        var offset = start
        while offset < end {
            guard let id = readElementID(bytes, &offset), let size = readVINTSize(bytes, &offset), !size.isUnknownSize
            else { return nil }
            let contentEnd = min(end, offset.addingClamped(size.value))
            if id == trackEntryID, let found = dimensionsInTrackEntry(bytes, offset: offset, end: contentEnd) {
                return found
            }
            offset = contentEnd
        }
        return nil
    }

    private static func dimensionsInTrackEntry(_ bytes: [UInt8], offset start: Int, end: Int) -> CGSize? {
        var offset = start
        var isVideo = false
        var videoRange: (Int, Int)?
        while offset < end {
            guard let id = readElementID(bytes, &offset), let size = readVINTSize(bytes, &offset), !size.isUnknownSize
            else { return nil }
            let contentEnd = min(end, offset.addingClamped(size.value))
            if id == trackTypeID {
                isVideo = readUInt(bytes, offset: offset, length: contentEnd - offset) == trackTypeVideo
            } else if id == videoID {
                videoRange = (offset, contentEnd)
            }
            offset = contentEnd
        }
        guard isVideo, let (videoStart, videoEnd) = videoRange else { return nil }
        return dimensionsInVideo(bytes, offset: videoStart, end: videoEnd)
    }

    private static func dimensionsInVideo(_ bytes: [UInt8], offset start: Int, end: Int) -> CGSize? {
        var offset = start
        var width: UInt64?
        var height: UInt64?
        while offset < end {
            guard let id = readElementID(bytes, &offset), let size = readVINTSize(bytes, &offset), !size.isUnknownSize
            else { return nil }
            let contentEnd = min(end, offset.addingClamped(size.value))
            if id == pixelWidthID {
                width = readUInt(bytes, offset: offset, length: contentEnd - offset)
            } else if id == pixelHeightID {
                height = readUInt(bytes, offset: offset, length: contentEnd - offset)
            }
            offset = contentEnd
            if let width, let height {
                guard width > 0, height > 0, width < 100_000, height < 100_000 else { return nil }
                return CGSize(width: Double(width), height: Double(height))
            }
        }
        return nil
    }

    // MARK: - EBML の基礎(VINT: 可変長の整数)

    /// `offset + size` が `limit` を超えない整数なら返す(細工された巨大なサイズで Int が溢れないように)。
    private static func advance(_ offset: Int, by size: UInt64, limit: Int) -> Int? {
        let next = offset.addingClamped(size)
        return next <= limit ? next : nil
    }

    private static func vintLength(_ firstByte: UInt8) -> Int {
        var mask: UInt8 = 0x80
        for length in 1...8 {
            if firstByte & mask != 0 { return length }
            mask >>= 1
        }
        return 0
    }

    /// 要素の ID は目印のビットを剥がさず、そのままの値を ID とする。
    private static func readElementID(_ bytes: [UInt8], _ offset: inout Int) -> UInt64? {
        guard offset >= 0, offset < bytes.count, bytes[offset] != 0 else { return nil }
        let length = vintLength(bytes[offset])
        guard length > 0, length <= 4, offset + length <= bytes.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<length {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        offset += length
        return value
    }

    private struct VINTSize {
        let value: UInt64
        let isUnknownSize: Bool
    }

    /// サイズの VINT は目印のビットを剥がして数にする。値のビットがすべて 1 なら「大きさ不明」(ストリーミングなど)。
    private static func readVINTSize(_ bytes: [UInt8], _ offset: inout Int) -> VINTSize? {
        guard offset >= 0, offset < bytes.count, bytes[offset] != 0 else { return nil }
        let first = bytes[offset]
        let length = vintLength(first)
        guard length > 0, offset + length <= bytes.count else { return nil }
        let marker: UInt8 = 0x80 >> (length - 1)
        var value = UInt64(first & (marker - 1))
        var isMaxValue = value == UInt64(marker - 1)
        for index in 1..<length {
            let byte = bytes[offset + index]
            value = (value << 8) | UInt64(byte)
            if byte != 0xFF { isMaxValue = false }
        }
        offset += length
        return VINTSize(value: value, isUnknownSize: isMaxValue)
    }

    /// EBML の符号なし整数(ビッグエンディアン、可変長)。
    private static func readUInt(_ bytes: [UInt8], offset: Int, length: Int) -> UInt64? {
        guard length > 0, length <= 8, offset >= 0, offset + length <= bytes.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<length {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        return value
    }
}

private extension Int {
    /// 符号なしの大きさを足す。溢れるなら `Int.max`(範囲の検査で必ず外れる)。
    nonisolated func addingClamped(_ size: UInt64) -> Int {
        guard size <= UInt64(Int.max) else { return Int.max }
        let (sum, overflow) = addingReportingOverflow(Int(size))
        return overflow ? Int.max : sum
    }
}

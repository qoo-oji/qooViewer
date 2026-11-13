import Foundation
import ZIPFoundation

/// ファイル名のバイト列と拡張欄を自分で決めて zip を組み立てる(テストの中で、メモリ上に)。
///
/// `ZipFixtureBuilder`(ZIPFoundation で書く)は名前を常に UTF-8 + フラグ bit 11 にするので、UTF-8 フラグの無いレガシーな
/// 名前は作れない。コミット済みのフィクスチャ(scripts/fixtures/make-legacy-zip.py)は拡張欄を書かないので、Info-ZIP Unicode
/// Path 拡張欄(0x7075)の試験はこちらで作る。形は make-legacy-zip.py と同じ(無圧縮・日時固定・作成 OS は MS-DOS)。
nonisolated struct LegacyZipBuilder {
    struct Entry {
        let rawName: Data
        let data: Data
        let utf8Flag: Bool
        /// 中央ディレクトリとローカルヘッダーの両方に入れる拡張欄(ヘッダー ID・大きさ込みのバイト列)。
        let extra: Data
    }

    private(set) var entries: [Entry] = []

    init() {}

    /// `name` を `encoding` のバイト列にして入れる。
    mutating func add(_ name: String, encoding: String.Encoding, data: Data, utf8Flag: Bool = false, extra: Data = Data()) {
        add(rawName: name.data(using: encoding)!, data: data, utf8Flag: utf8Flag, extra: extra)
    }

    mutating func add(rawName: Data, data: Data, utf8Flag: Bool = false, extra: Data = Data()) {
        entries.append(Entry(rawName: rawName, data: data, utf8Flag: utf8Flag, extra: extra))
    }

    /// Info-ZIP Unicode Path 拡張欄(APPNOTE 4.6.9)。`crcOf` は欄に書く CRC の元(普通はそのエントリの生の名前)。
    static func unicodePathField(_ name: String, crcOf rawName: Data, version: UInt8 = 1) -> Data {
        let utf8 = Data(name.utf8)
        var body = Data([version])
        body.appendLE32(rawName.crc32(checksum: 0))
        body.append(utf8)
        var field = Data()
        field.appendLE16(0x7075)
        field.appendLE16(UInt16(body.count))
        field.append(body)
        return field
    }

    func build() -> Data {
        let dosDate: UInt16 = UInt16((2026 - 1980) << 9 | 1 << 5 | 1)
        var local = Data()
        var central = Data()
        for entry in entries {
            let flags: UInt16 = entry.utf8Flag ? 1 << 11 : 0
            let crc = entry.data.crc32(checksum: 0)
            let offset = UInt32(local.count)
            local.appendLE32(0x0403_4b50)
            local.appendLE16(20); local.appendLE16(flags); local.appendLE16(0)
            local.appendLE16(0); local.appendLE16(dosDate)
            local.appendLE32(crc); local.appendLE32(UInt32(entry.data.count)); local.appendLE32(UInt32(entry.data.count))
            local.appendLE16(UInt16(entry.rawName.count)); local.appendLE16(UInt16(entry.extra.count))
            local.append(entry.rawName); local.append(entry.extra); local.append(entry.data)

            central.appendLE32(0x0201_4b50)
            central.appendLE16(20); central.appendLE16(20); central.appendLE16(flags); central.appendLE16(0)
            central.appendLE16(0); central.appendLE16(dosDate)
            central.appendLE32(crc); central.appendLE32(UInt32(entry.data.count)); central.appendLE32(UInt32(entry.data.count))
            central.appendLE16(UInt16(entry.rawName.count)); central.appendLE16(UInt16(entry.extra.count))
            central.appendLE16(0); central.appendLE16(0); central.appendLE16(0)
            central.appendLE32(entry.rawName.last == 0x2F ? 0x10 : 0)
            central.appendLE32(offset)
            central.append(entry.rawName); central.append(entry.extra)
        }
        var eocd = Data()
        eocd.appendLE32(0x0605_4b50)
        eocd.appendLE16(0); eocd.appendLE16(0)
        eocd.appendLE16(UInt16(entries.count)); eocd.appendLE16(UInt16(entries.count))
        eocd.appendLE32(UInt32(central.count)); eocd.appendLE32(UInt32(local.count))
        eocd.appendLE16(0)
        return local + central + eocd
    }
}

private extension Data {
    nonisolated mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8(value >> 8))
    }

    nonisolated mutating func appendLE32(_ value: UInt32) {
        appendLE16(UInt16(value & 0xFFFF)); appendLE16(UInt16(value >> 16))
    }
}

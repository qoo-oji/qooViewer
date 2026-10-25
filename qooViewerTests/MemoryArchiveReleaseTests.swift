import Foundation
import Synchronization
import Testing

@testable import qooViewer

/// メモリ上の書庫(入れ子の書庫は予算に収まればメモリから開く ―― `NestedArchiveResolver`)を開けなかったとき、
/// 渡したバイト列が解放されることを確かめる(2026-10-25 のリークの点検)。
///
/// ZIPFoundation 0.9.20 の `Archive(data:)` は、終端レコード(EOCD)が見つからないと `funopen` した FILE* を閉じずに投げる。
/// FILE* の後始末(close のコールバック)だけが `passRetained` した `MemoryFile` を手放すので、名前だけ .cbz の RAR や壊れた入れ子の
/// zip を開くたびに、その書庫のバイト列(既定で最大 256MB)が二度と解放されなかった。`ZipArchiveReader(data:)` は ZIPFoundation に
/// 渡す前に同じ判定をして、開けないものは自分で断る。
struct MemoryArchiveReleaseTests {

    /// バイト列が解放されたかの印。
    private final class ReleaseFlag: Sendable {
        private let released = Mutex(false)
        var isReleased: Bool { released.withLock { $0 } }
        func markReleased() { released.withLock { $0 = true } }
    }

    /// 解放されたら `flag` に印を付ける `Data`(コピーせずに持たせるので、誰かが持ち続ける限り印は付かない)。
    private static func trackedData(_ bytes: [UInt8], flag: ReleaseFlag) -> Data {
        let count = bytes.count
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        bytes.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: count) }
        return Data(bytesNoCopy: pointer, count: count, deallocator: .custom { pointer, _ in
            pointer.deallocate()
            flag.markReleased()
        })
    }

    /// `bytes` をメモリから zip として開いてみて、開けたか・手放した後にバイト列が解放されたかを返す。
    private static func openAndRelease(_ bytes: [UInt8]) -> (opened: Bool, released: Bool) {
        let flag = ReleaseFlag()
        var opened = false
        do {
            let data = trackedData(bytes, flag: flag)
            if let reader = try? ZipArchiveReader(data: data) {
                opened = true
                _ = try? reader.listFilePaths()
            }
        }
        return (opened, flag.isReleased)
    }

    private static func validZipBytes() throws -> [UInt8] {
        let folder = try TemporaryDirectory("memory-zip")
        var builder = ZipFixtureBuilder()
        builder.add("001.txt", text: "page")
        let url = folder.file("valid.zip")
        try builder.write(to: url)
        return Array(try Data(contentsOf: url))
    }

    @Test("開けた zip は、reader を手放せばバイト列も解放される(この試験の測り方の確かめ)")
    func validZipIsReleased() throws {
        let result = Self.openAndRelease(try Self.validZipBytes())
        #expect(result.opened)
        #expect(result.released)
    }

    @Test("中身が zip でないバイト列(名前だけ .cbz の RAR)は開けず、バイト列も解放される")
    func nonZipIsReleased() {
        let rarLike: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00] + Array(repeating: 0x5A, count: 4096)
        let result = Self.openAndRelease(rarLike)
        #expect(!result.opened)
        #expect(result.released)
    }

    @Test("終端レコードはあるがコメントが途中で切れている zip は開けず、バイト列も解放される")
    func truncatedCommentIsReleased() throws {
        var bytes = try Self.validZipBytes()
        // 終端レコードのコメント長(EOCD の 20 バイト目、リトルエンディアン)を、残りより長くする。
        let eocd = bytes.count - 22
        #expect(bytes[eocd..<eocd + 4] == [0x50, 0x4B, 0x05, 0x06])
        bytes[eocd + 20] = 0xFF
        bytes[eocd + 21] = 0x00
        let result = Self.openAndRelease(bytes)
        #expect(!result.opened)
        #expect(result.released)
    }

    @Test("後ろにコメントの付いた zip は今までどおり開ける(終端レコードを末尾 22 バイトより前でも探す)")
    func zipWithCommentStillOpens() throws {
        var bytes = try Self.validZipBytes()
        let eocd = bytes.count - 22
        let comment = Array("a comment".utf8)
        bytes[eocd + 20] = UInt8(comment.count)
        bytes[eocd + 21] = 0
        bytes += comment
        let result = Self.openAndRelease(bytes)
        #expect(result.opened)
        #expect(result.released)
    }
}

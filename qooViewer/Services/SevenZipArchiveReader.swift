import Foundation
import SevenZip

/// 7z / cb7 を読むための ArchiveReading 実装
/// (SevenZip.swift ライブラリを使用。暗号化されたアーカイブには非対応)
/// nonisolated: PageLoader(actor、メインスレッド外)から呼ばれるため、Xcode 26既定の
/// MainActor自動分離の対象外にしている(詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated final class SevenZipArchiveReader: ArchiveReading {
    private let archive: SevenZip.Archive
    private let entries: [SevenZip.Entry]
    /// path -> 対応するEntry(ページ読み込みのたびにentriesを線形探索しないための索引。
    /// ZipArchiveReaderのentryByCorrectedPathと同じ考え方。同名エントリが複数存在する場合は
    /// 元の`entries.first(where:)`と同じく最初に見つかったものを優先する)。
    private var entryByPath: [String: SevenZip.Entry] = [:]
    /// 全エントリの非圧縮サイズの合計。residentDecompressionBufferUpperBoundBytesの材料。
    private let totalUncompressedBytes: Int
    /// 一度でも取り出しを行ったか(それまではライブラリのバッファは空)。
    private var hasExtracted = false

    init(url: URL) throws {
        self.archive = try SevenZip.Archive(fileURL: url)
        self.entries = archive.entries
        for entry in entries where entryByPath[entry.path] == nil {
            entryByPath[entry.path] = entry
        }
        // 溢れよけにclampingで足す(索引が嘘をついていても落ちないように)。
        totalUncompressedBytes = entries.reduce(0) { $0 &+ Int(clamping: $1.uncompressedSize) }
    }

    func listFilePaths() throws -> [String] {
        entries.filter { !$0.directory }.map { $0.path }
    }

    func data(at path: String) throws -> Data {
        guard let entry = entryByPath[path] else {
            throw ArchiveReaderError.entryNotFound
        }
        hasExtracted = true
        return try archive.extract(entry: entry)
    }

    /// SevenZip.swiftの`Archive.extract(entry:)`はLZMA SDKの`SzArEx_Extract`を
    /// ブロックキャッシュ(blockIndex/outBuffer)付きで呼んでおり、1エントリを取り出すために
    /// **そのエントリが属するソリッドブロック全体**を伸長し、そのバッファを`Archive`が
    /// 解放されるまで保持し続ける(監査で指摘)。7-Zipの既定はソリッド圧縮なので、GB級の
    /// cb7では本を開いている間ずっとGB単位のメモリがこのreaderの裏に居座る。
    ///
    /// ライブラリはブロックの構成(どのエントリがどのブロックか)を公開していないため、
    /// 正確な大きさは分からない。ここでは「全エントリの非圧縮サイズの合計」を**上限の見積り**
    /// として返す(ブロックが1つのソリッド書庫ではぴったり一致し、複数ブロック・非ソリッドの
    /// 書庫では実際より大きく出る)。リソースモニタは「最大で」と添えて出す。
    var residentDecompressionBufferUpperBoundBytes: Int {
        hasExtracted ? totalUncompressedBytes : 0
    }

    /// 7zのエントリはSevenZip.Entry.modified(更新日時)しか持たず、作成日時という概念が無い
    /// ため、createdは常にnil(ArchiveReading.entryDates(at:)のコメント参照)。
    func entryDates(at path: String) -> (created: Date?, modified: Date?) {
        guard let entry = entryByPath[path] else { return (nil, nil) }
        return (nil, entry.modified)
    }

    /// 索引が持つ非圧縮サイズをそのまま返す(展開は伴わない)。
    func entryUncompressedSize(at path: String) -> Int64? {
        guard let entry = entryByPath[path] else { return nil }
        return Int64(entry.uncompressedSize)
    }
}

import Foundation
import SevenZip

/// 7z / cb7 を読むための ArchiveReading 実装
/// (SevenZip.swift ライブラリを使用。暗号化されたアーカイブには非対応)
/// nonisolated: PageLoader(actor、メインスレッド外)から呼ばれるため、Xcode 26既定の
/// MainActor自動分離の対象外にしている(詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated final class SevenZipArchiveReader: ArchiveReading {
    private let archive: SevenZip.Archive
    private let entries: [SevenZip.Entry]

    init(url: URL) throws {
        self.archive = try SevenZip.Archive(fileURL: url)
        self.entries = archive.entries
    }

    func listFilePaths() throws -> [String] {
        entries.filter { !$0.directory }.map { $0.path }
    }

    func data(at path: String) throws -> Data {
        guard let entry = entries.first(where: { $0.path == path }) else {
            throw ArchiveReaderError.entryNotFound
        }
        return try archive.extract(entry: entry)
    }
}

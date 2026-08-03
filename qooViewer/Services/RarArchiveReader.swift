import Foundation
import Unrar

/// rar / cbr を読むための ArchiveReading 実装
/// (Unrar.swift ライブラリを使用。パスワード付きアーカイブには非対応)
/// nonisolated: PageLoader(actor、メインスレッド外)から呼ばれるため、Xcode 26既定の
/// MainActor自動分離の対象外にしている(詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated final class RarArchiveReader: ArchiveReading {
    private let archive: Unrar.Archive
    private let entries: [Unrar.Entry]
    /// fileName -> 対応するEntry(ページ読み込みのたびにentriesを線形探索しないための索引。
    /// ZipArchiveReaderのentryByCorrectedPathと同じ考え方。同名エントリが複数存在する場合は
    /// 元の`entries.first(where:)`と同じく最初に見つかったものを優先する)。
    private var entryByFileName: [String: Unrar.Entry] = [:]

    init(url: URL) throws {
        self.archive = try Unrar.Archive(fileURL: url)
        self.entries = try archive.entries()
        for entry in entries where entryByFileName[entry.fileName] == nil {
            entryByFileName[entry.fileName] = entry
        }
    }

    func listFilePaths() throws -> [String] {
        entries.filter { !$0.directory }.map { $0.fileName }
    }

    func data(at path: String) throws -> Data {
        guard let entry = entryByFileName[path] else {
            throw ArchiveReaderError.entryNotFound
        }
        return try archive.extract(entry)
    }
}

import Foundation
import Unrar

/// rar / cbr を読むための ArchiveReading 実装
/// (Unrar.swift をフォークした qoo-oji/Unrar.swift の `memory-archive` ブランチを使用。
/// パスワード付きアーカイブには非対応)
///
/// フォークしたのは、入れ子の rar をメモリ上の Data から開けるようにするため(`init(data:)`)。
/// 元の unrar の公開 API はファイルパスしか受け付けず、入れ子の rar は一時ファイルへ書き出すほか
/// なかった。フォークは同梱の unrar に「メモリから読むモード」を足している
/// (フォークの docs/MemoryArchive.md 参照)。伸長そのものは元のままで、速度も変わらない。
/// nonisolated: PageLoader(actor、メインスレッド外)から呼ばれるため、Xcode 26既定の
/// MainActor自動分離の対象外にしている(詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated final class RarArchiveReader: ArchiveReading {
    private let archive: Unrar.Archive
    private let entries: [Unrar.Entry]
    /// fileName -> 対応するEntry(ページ読み込みのたびにentriesを線形探索しないための索引。
    /// ZipArchiveReaderのentryByCorrectedPathと同じ考え方。同名エントリが複数存在する場合は
    /// 元の`entries.first(where:)`と同じく最初に見つかったものを優先する)。
    private var entryByFileName: [String: Unrar.Entry] = [:]

    convenience init(url: URL) throws {
        try self.init(archive: Unrar.Archive(fileURL: url))
    }

    /// 入れ子になった書庫を、ディスクへ書き出さずメモリ上のDataから直接開く
    /// (NestedArchiveResolver、およびArchiveKind.opensFromMemory参照)。
    ///
    /// フォーク側の`Archive(data:)`はDataをコピーせずに保持し、`entries()`/`extract()`のたびに
    /// `withUnsafeBytes`で借りて unrar に渡す(各操作が開いて閉じる作りなので、ポインタの寿命が
    /// 操作の中に収まる)。分割ボリュームはメモリからは辿れないが、入れ子の分割rarは現実には無い。
    convenience init(data: Data) throws {
        try self.init(archive: Unrar.Archive(data: data))
    }

    private init(archive: Unrar.Archive) throws {
        self.archive = archive
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

    /// rarはUnrar.Entryが作成日時(creation)・更新日時(modified)の両方を持つ数少ない
    /// アーカイブ形式(ArchiveReading.entryDates(at:)のコメント参照)。
    func entryDates(at path: String) -> (created: Date?, modified: Date?) {
        guard let entry = entryByFileName[path] else { return (nil, nil) }
        return (entry.creation, entry.modified)
    }

    /// ArchiveReading.extract(at:to:maxByteCount:)のrar実装(プロトコル側のコメント参照)。
    ///
    /// Unrar.swiftの`extract(_:) -> Data`は伸長結果をすべてDataへ積み上げてから返すため、
    /// 大きな書庫では**その書庫の全バイトが一度メモリに載る**。入れ子の書庫は数百MB〜数GBに
    /// なりうる(大容量の本はrarでラップされていることが多い)ので、ここではコールバック版を
    /// 使ってチャンクが届くたびにファイルへ書き出す。
    ///
    /// コールバックはthrowできないため、書き込みエラーは変数に控えてから`progress.cancel()`で
    /// 伸長そのものを打ち切る(Unrar.swift側はisCancelledを見てUNRARCALLBACKに-1を返し、
    /// RARProcessFileがエラーになる)。中途半端なファイルが残らないよう、失敗時はここで消す。
    /// 上限超過(maxByteCount)も同じ経路で打ち切る ―― 書き出した量を数え、超えた時点で
    /// entryTooLargeを控えて伸長を止める(監査で指摘)。
    func extract(at path: String, to url: URL, maxByteCount: Int) throws {
        guard let entry = entryByFileName[path] else { throw ArchiveReaderError.entryNotFound }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ArchiveReaderError.cannotOpen
        }
        var writeError: Error?
        var writtenByteCount = 0
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try archive.extract(entry) { chunk, progress in
                guard writeError == nil else { return }
                writtenByteCount += chunk.count
                guard writtenByteCount <= maxByteCount else {
                    writeError = ArchiveReaderError.entryTooLarge
                    progress.cancel()
                    return
                }
                do {
                    try handle.write(contentsOf: chunk)
                } catch {
                    writeError = error
                    progress.cancel()
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw writeError ?? error
        }
        if let writeError {
            try? FileManager.default.removeItem(at: url)
            throw writeError
        }
    }

    /// ヘッダーが持つ非圧縮サイズをそのまま返す(展開は伴わない)。
    func entryUncompressedSize(at path: String) -> Int64? {
        guard let entry = entryByFileName[path] else { return nil }
        // clampingで変換する理由はSevenZipArchiveReaderの同名メソッド参照。
        return Int64(clamping: entry.uncompressedSize)
    }
}

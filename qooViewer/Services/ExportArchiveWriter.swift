import Foundation
import ZIPFoundation

/// 書き出し(CBZ/EPUB)の zip を書く窓口。**作成と書き込みはすべて `FileIO` の上で**(2026-10-11 の規約監査)。
///
/// 書き出しは `@concurrent`(2026-10-05 の効率の監査 A4 でメインから外した)で、そのとき zip への書き込みも協調スレッドプールの上に
/// 残った。出力先は利用者が選んだフォルダで、応答しない共有の上なら書き込み 1 回ごとにプールのスレッドが塞がる(FileIO の型コメント)。
/// ページの取り出し(PageLoader)は await を挟むので、書き込みだけをここで 1 回ずつ `FileIO` へ渡す。
///
/// `@unchecked Sendable`: `Archive` はスレッド安全でないが、書き出しは 1 エントリずつ待ってから次を書く(同時に 2 つの書き込みが
/// 走らない)ので、借りるスレッドが変わっても同時には触らない。
nonisolated final class ExportArchiveWriter: @unchecked Sendable {
    /// 書いている zip。`close()` で手放す(最後の書き込みの吐き出しと `fclose` は `Archive` の deinit が行う)。
    private var archive: Archive?

    private init(archive: Archive) {
        self.archive = archive
    }

    /// 出力先に新しい zip を作る(同名のファイルがあれば消してから。書き出しは一時ファイルへ書くので、普通は無い)。
    static func create(at url: URL) async throws -> ExportArchiveWriter {
        try await FileIO.perform {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return ExportArchiveWriter(archive: try Archive(url: url, accessMode: .create))
        }
    }

    /// 1 エントリを書く。
    ///
    /// - Parameter storedChunkSize: 格納(無圧縮)のエントリを渡す大きさ。nil なら ZIPFoundation の既定(CbzExporter の addEntry の
    ///   コメント)。
    func addEntry(path: String, data: Data, compressed: Bool, storedChunkSize: Int? = nil) async throws {
        try await FileIO.perform { [self] in
            guard let archive else { throw CocoaError(.fileWriteUnknown) }
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                // ZIPFoundation は日時を UTC として書くので、書き出す時刻が現地時刻で入るようにずらして渡す(ZipDOSTime)。
                // 省くと既定の「いま」が UTC のまま入り、日本では展開したファイルが 9 時間前の日時になる。
                modificationDate: ZipDOSTime.zipFoundationDate(forLocal: Date()),
                compressionMethod: compressed ? .deflate : .none,
                bufferSize: compressed ? defaultWriteChunkSize : (storedChunkSize ?? defaultWriteChunkSize)
            ) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
    }

    /// 書き終えた zip を閉じる。`Archive` の deinit が最後のバッファを吐き出して `fclose` するので、手放すのも `FileIO` の上で
    /// (呼ばずに捨てると、その時に走っている協調スレッドで閉じる ―― 失敗で抜けたときはそうなる)。
    func close() async {
        await FileIO.perform { [self] in archive = nil }
    }
}

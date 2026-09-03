import Foundation
import SevenZip

/// 7z / cb7 を読むための ArchiveReading 実装
/// (SevenZip.swift をフォークした qoo-oji/SevenZip.swift の `streaming-extract` ブランチを使用。
/// 暗号化されたアーカイブには非対応)
///
/// ■ なぜフォークか
/// 元の SevenZip.swift の `extract(entry:)` は LZMA SDK の `SzArEx_Extract` を使っており、1 エントリを
/// 取り出すために**そのエントリが属するソリッドブロック全体**を伸長し、そのバッファを `Archive` が
/// 解放されるまで保持し続ける。7-Zip の既定はソリッド圧縮なので、GB 級の cb7 では本を開いている間
/// ずっと GB 単位のメモリが reader の裏に居座っていた(リソースモニタに「7z の展開バッファ」として
/// 上限見積りを出していた時期がある)。フォークでは、ブロックを**要求されたぶんだけ**伸長する
/// 引き出し型の `readData(entry:)` / `read(entry:)` を足し、常駐を LZMA 辞書(通常 16〜64MB)+
/// 数百 KB に抑えた(フォークの docs/StreamingExtraction.md 参照)。
///
/// ■ 読み方の癖(ソリッド書庫)
/// フォークは「最後に読んだブロックのデコーダ」を 1 つ保持し、同じブロックの**前方**のエントリなら
/// そこまで読み捨てて続きから読む。書庫順に読む限りブロックの伸長は 1 回で済む。**後方**へ戻るときは
/// ブロック先頭からやり直しになる(ソリッド圧縮の性質で、どの実装でも避けられない)。ページ送りは
/// 前方が基本で、戻る先のページはたいてい PagePixelCache に残っているので、実用上はほぼ前方だけになる。
/// 非ソリッドの書庫(-ms=off)ではエントリごとにブロックが分かれるので、どちら向きでも同じ速さ。
///
/// nonisolated: PageLoader(actor、メインスレッド外)から呼ばれるため、Xcode 26既定の
/// MainActor自動分離の対象外にしている(詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated final class SevenZipArchiveReader: ArchiveReading {
    private let archive: SevenZip.Archive
    private let entries: [SevenZip.Entry]
    /// path -> 対応するEntry(ページ読み込みのたびにentriesを線形探索しないための索引。
    /// ZipArchiveReaderのentryByCorrectedPathと同じ考え方。同名エントリが複数存在する場合は
    /// 元の`entries.first(where:)`と同じく最初に見つかったものを優先する)。
    private var entryByPath: [String: SevenZip.Entry] = [:]

    convenience init(url: URL) throws {
        self.init(archive: try SevenZip.Archive(fileURL: url))
    }

    /// 入れ子になった書庫を、ディスクへ書き出さずメモリ上のDataから直接開く
    /// (NestedArchiveResolver、およびArchiveKind.opensFromMemory参照)。
    ///
    /// フォーク側の`Archive(data:)`はDataを**1回コピー**して自前のバッファに持つ(`Archive`が開いた
    /// まま長生きするオブジェクトで、Dataのポインタは`withUnsafeBytes`の外では安定が保証されない
    /// ため)。呼び出し側のDataはこの初期化が終わった時点で手放してよく、そうすれば書庫1つぶんの
    /// メモリで済む。
    convenience init(data: Data) throws {
        self.init(archive: try SevenZip.Archive(data: data))
    }

    private init(archive: SevenZip.Archive) {
        self.archive = archive
        self.entries = archive.entries
        for entry in entries where entryByPath[entry.path] == nil {
            entryByPath[entry.path] = entry
        }
    }

    func listFilePaths() throws -> [String] {
        entries.filter { !$0.directory }.map { $0.path }
    }

    func data(at path: String) throws -> Data {
        guard let entry = entryByPath[path] else {
            throw ArchiveReaderError.entryNotFound
        }
        return try archive.readData(entry: entry)
    }

    /// 先頭だけを伸長して打ち切る(プロトコル側のコメント参照)。ソリッドブロックの途中で止めても、
    /// フォーク側のデコーダは止めた位置を覚えているので、次にそのエントリ全体を読むときは
    /// ブロック先頭からやり直しになる(打ち切った先が同じエントリの先頭より後ろのため)。
    /// 縦横比の下調べ(全ページの先頭だけを順に読む)はページ順=書庫順に進むので、その用途では
    /// 各ページで「先頭を読む→次のページの先頭まで読み捨て」となり、やり直しは起きない。
    func dataPrefix(at path: String, maxByteCount: Int) throws -> Data {
        guard let entry = entryByPath[path] else {
            throw ArchiveReaderError.entryNotFound
        }
        return try archive.readData(entry: entry, maxByteCount: maxByteCount)
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

    /// ArchiveReading.extract(at:to:maxByteCount:)の7z実装(プロトコル側のコメント参照)。
    ///
    /// フォークの`read(entry:chunkSize:)`でチャンクごとにファイルへ書き出す。RarArchiveReaderと
    /// 同じく、書き出した量を数えて上限を超えた時点で打ち切り、失敗時は書きかけを残さない。
    /// クロージャの中で投げられるので、rarのような「エラーを控えてcancel」の迂回は要らない。
    func extract(at path: String, to url: URL, maxByteCount: Int) throws {
        guard let entry = entryByPath[path] else { throw ArchiveReaderError.entryNotFound }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ArchiveReaderError.cannotOpen
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var writtenByteCount = 0
            try archive.read(entry: entry, chunkSize: 1 << 18) { chunk in
                writtenByteCount += chunk.count
                guard writtenByteCount <= maxByteCount else { throw ArchiveReaderError.entryTooLarge }
                try handle.write(contentsOf: Data(chunk))
                return true
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

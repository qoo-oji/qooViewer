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
/// ■ 読み方の癖(ソリッド書庫)―― 前方は無料、後方は「辞書の範囲」だけ無料
/// フォークは「最後に読んだブロックのデコーダ」を 1 つ保持し、同じブロックの**前方**のエントリなら
/// そこまで読み捨てて続きから読む。書庫順に読む限りブロックの伸長は 1 回で済む。**後方**へ戻るときは、
/// 戻り先が「デコーダが最後に伸長した位置」から見て LZMA 辞書の範囲(直近 16〜64MB。書庫を作るときに
/// 決まる。フィルタ無しの LZMA/LZMA2 だけ)なら辞書のバイト列をそのまま渡し直すので無料、それより外は
/// ブロック先頭からやり直しになる(ソリッド圧縮の性質で、どの実装でも避けられない)。追加のメモリは
/// 持たない ―― このフォークの目的はメモリ削減なので、戻りのための履歴バッファは**意図して積んでいない**。
/// 非ソリッドの書庫(-ms=off)ではエントリごとにブロックが分かれるので、どちら向きでも同じ速さ。
///
/// ■ だから、後方読みを出さないのは qooViewer 側の責任
/// 監査(2026-09-04)で実機のログを取ったところ、後方読みの大半はユーザーのページ送りではなく
/// qooViewer 自身のアクセス順だった。それぞれこう直してある:
/// - 横長判定のウォームアップ(本全体の下調べ)は、以前は現在ページから**前後交互**に本全体を舐め、
///   しかも表示用と同じデコーダで舐めるので、終わった後はデコーダが本の末尾に居座り、以後の読みが
///   すべて「後方」になっていた。今は書庫順に読み、ルートが 7z の本では**専用の reader**(辞書 1 つぶんの
///   メモリを下調べの間だけ)で読むので、表示用のデコーダの位置は動かない
///   (PageLoader.scanPage / ViewerViewModel.warmUpWideImageCacheForEntireBook)。分かった寸法は
///   構造キャッシュへ永続化し、2 回目以降は書庫に触らない(PageLoader.loadPersistedPageSizes)。
///   同じ 1 パスで進捗バー用サムネイルもディスクキャッシュへ作っておく。
/// - 先読みは、以前は前後対称で、前方の先端から見て 6〜20 ページ後ろを常に読んでいた。今は 7z では
///   進んでいる方向だけを先読みする(PageLoader.prefetch の direction)。方向転換の瞬間に辞書の外へ
///   出れば 1 回だけやり直しが起きる(16MB 辞書・2.5MB/ページで 7 ページ以上戻ったとき)。
/// - 「情報を見る」用のヘッダー情報は、表示のために読んだ同じバイト列から取る(読み直さない)。
/// 250MB・100 ページのソリッド cb7 を中央から再開するケースで、旧経路(ブロック丸ごとキャッシュ)
/// 6.9 秒・監査時 275 秒 → 書庫順で 10 秒。7z に触れるアクセス順を変えるときは、実機ログで
/// 「ブロック先頭からのやり直し回数」を数えること。
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
    /// 次にそのエントリ全体を読むときは辞書の範囲内(型コメント参照)なので、やり直しにはならない。
    /// 先頭だけの読み取りはエントリの CRC を検証しない(全体を読むときは検証される)。
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
        // clampingで変換する: 索引の申告はUInt64で、細工された書庫では2^63以上もありうる。
        // 素の`Int64(_:)`はそこでトラップし、開いた瞬間の先読みでアプリが落ちる(監査で指摘)。
        return Int64(clamping: entry.uncompressedSize)
    }

    /// 「最後に読んだブロックのデコーダ」がいま抱えているメモリ(LZMA辞書+数百KBのバッファ。型コメント
    /// 参照)。フォールバック経路(BCJ2)でブロック全体をキャッシュしている場合はそのぶんも含む。
    /// まだ1ページも読んでいなければ0。
    var residentDecompressionBufferBytes: Int { archive.residentDecoderBytes }

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

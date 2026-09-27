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
    /// 読み込み層から読むときだけ: 読み取りの失敗の記録(ReadFailureLog のコメント)。
    private let readFailures: ReadFailureLog?

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

    /// ネットワークボリューム上の rar を、読み込み層(StagedFileSource)を通して読む(makeArchiveReader が選ぶ)。
    ///
    /// フォークの `Archive.Source.reader`(unrar の `RAROpenArchiveCallback`)で、unrar の読み取りを読み込み層へ回す。
    /// unrar はファイルごとのヘッダーを「7 バイト+残り」の 2 回の素の `read()` で読み、操作のたびに書庫を開き直すので、
    /// 直接読むと Quick Open の無い書庫ではページを読むたびにヘッダーの数だけ往復した(1 往復 5ms の模擬で最初のページまで
    /// 7.7 秒。docs/plans/network-volume-study.md)。読み込み層を通せば、一度取り寄せたヘッダーは手元から読む。
    convenience init(source: RandomAccessSource) throws {
        let failures = ReadFailureLog()
        try self.init(
            archive: Unrar.Archive(source: .reader(positionalReader(for: source, failures: failures))),
            readFailures: failures
        )
    }

    private init(archive: Unrar.Archive, readFailures: ReadFailureLog? = nil) throws {
        self.archive = archive
        self.readFailures = readFailures
        readFailures?.reset()
        self.entries = try archive.entries()
        try readFailures?.throwIfFailed()
        for entry in entries where entryByFileName[entry.fileName] == nil {
            entryByFileName[entry.fileName] = entry
        }
    }

    /// 読み込み層からの読み取りの失敗を覚えておく(2026-09-27 の監査)。
    ///
    /// unrar は DLL として組むと(`RARDLL` → `SILENT`)、読み取りの失敗を**「書庫がそこで終わった」として扱う**
    /// (`File::Read` が `AskRepeatRead` で「無視」を選び、以後の読みは 0 バイト)。一覧はそこまでの短いものになり、エラーにならない。
    /// ネットワークの瞬断でページの少ない本として開くと、「中身が差し替わった本」と判断されて読書位置と残りのページのブックマークが
    /// 消え(ViewerViewModel の指紋の比較)、短い一覧が構造キャッシュにも残った。ここで失敗を覚え、操作の後で投げ直す。
    /// 1 つの reader は 1 つのスレッドから使う(ほかの reader と同じ)が、記録は念のためロックで守る。
    nonisolated final class ReadFailureLog: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false

        func record() {
            lock.lock(); failed = true; lock.unlock()
        }

        func reset() {
            lock.lock(); failed = false; lock.unlock()
        }

        func throwIfFailed() throws {
            lock.lock(); let didFail = failed; lock.unlock()
            if didFail { throw ArchiveReaderError.readFailed }
        }
    }

    /// 書庫の操作 1 回を、読み取りの失敗を確かめながら行う(読み込み層から読まないときは素通し)。
    private func checkingReads<T>(_ body: () throws -> T) throws -> T {
        readFailures?.reset()
        let result: T
        do {
            result = try body()
        } catch {
            // 読み取りの失敗が先にあったなら、そちらを伝える(ライブラリの答えは「壊れたデータ」などになる)。
            try readFailures?.throwIfFailed()
            throw error
        }
        try readFailures?.throwIfFailed()
        return result
    }

    func listFilePaths() throws -> [String] {
        entries.filter { !$0.directory }.map { $0.fileName }
    }

    func data(at path: String) throws -> Data {
        guard let entry = entryByFileName[path] else {
            throw ArchiveReaderError.entryNotFound
        }
        return try checkingReads { try archive.extract(entry) }
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
            try checkingReads { try archive.extract(entry) { chunk, progress in
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
            } }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw writeError ?? error
        }
        if let writeError {
            try? FileManager.default.removeItem(at: url)
            throw writeError
        }
    }

    /// 分割された書庫は扱わない(サンドボックスでは隣のボリュームを読めず、途中で「開けない」になる)。
    /// 暗号化は項目ごとの印で伝え、断るのは展開の側(ArchiveExtractor)。
    func entriesInArchiveOrder() throws -> [ArchiveEntryDescriptor] {
        guard !archive.isVolume else { throw ArchiveReaderError.multiVolume }
        return entries.map { entry in
            ArchiveEntryDescriptor(
                path: entry.fileName, kind: entry.directory ? .directory : .file,
                uncompressedSize: entry.uncompressedSize, modified: entry.modified, isEncrypted: entry.encrypted
            )
        }
    }

    /// コールバックは投げられないので、`extract(at:to:maxByteCount:)` と同じく失敗を控えて `progress.cancel()` で止める。
    ///
    /// - Note: unrar の公開 API は 1 項目ごとに書庫を開き直して先頭から見出しを辿る。**ソリッドの rar では、読み飛ばす
    ///   項目も伸長される**ので、全項目をこれで順に取り出すと書庫の大きさの 2 乗に比例する(ページの表示と同じ経路)。
    ///   全項目を読むなら readEntriesInArchiveOrder。
    func readEntry(at path: String, _ body: (Data) throws -> Void) throws {
        guard let entry = entryByFileName[path] else { throw ArchiveReaderError.entryNotFound }
        var bodyError: (any Error)?
        // ライブラリの閉包は @escaping だが、呼ばれるのは extract の中だけ(同期)。
        try withoutActuallyEscaping(body) { body in
            do {
                try checkingReads { try archive.extract(entry) { chunk, progress in
                    guard bodyError == nil else { return }
                    do {
                        try body(chunk)
                    } catch {
                        bodyError = error
                        progress.cancel()
                    }
                } }
            } catch {
                throw bodyError ?? error
            }
        }
        if let bodyError { throw bodyError }
    }

    /// 書庫を 1 回だけ開いて見出しの順に読み通す(フォークの `forEachEntry`。2026-09-14 に足した)。ソリッドでも伸長は 1 回で済む。
    /// 同じ名前のエントリが 2 つあれば `visit` も 2 回呼ばれる(ArchiveExtractor は 2 つ目を読み飛ばす)。
    func readEntriesInArchiveOrder(_ visit: (String) throws -> ((Data) throws -> Void)?) throws {
        guard !archive.isVolume else { throw ArchiveReaderError.multiVolume }
        try checkingReads {
            try archive.forEachEntry { entry in
                entry.directory ? nil : try visit(entry.fileName)
            }
        }
    }

    /// ヘッダーが持つ非圧縮サイズをそのまま返す(展開は伴わない)。
    func entryUncompressedSize(at path: String) -> Int64? {
        guard let entry = entryByFileName[path] else { return nil }
        // clampingで変換する理由はSevenZipArchiveReaderの同名メソッド参照。
        return Int64(clamping: entry.uncompressedSize)
    }
}

/// 読み込み層を、フォークの「位置を指定して読む」口の形に包む(rar・7z で共用)。短い読みは返さない
/// (読み込み層はファイルの終わり以外で短く返さない)。失敗は -1。**7z はこれを読み取りのエラーにするが、unrar は
/// 「書庫がそこで終わった」として扱う**ので、rar は失敗を別に覚えて投げ直す(RarArchiveReader.ReadFailureLog)。
nonisolated func positionalRead(_ source: RandomAccessSource, _ offset: Int64, _ buffer: UnsafeMutableRawBufferPointer) -> Int {
    guard offset >= 0, let data = try? source.read(at: UInt64(offset), count: buffer.count) else { return -1 }
    data.copyBytes(to: buffer)
    return data.count
}

private nonisolated func positionalReader(
    for source: RandomAccessSource, failures: RarArchiveReader.ReadFailureLog
) -> Unrar.Archive.PositionalReader {
    Unrar.Archive.PositionalReader(size: Int64(source.size)) { offset, buffer in
        let read = positionalRead(source, offset, buffer)
        if read < 0 { failures.record() }
        return read
    }
}

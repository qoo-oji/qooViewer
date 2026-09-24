import Foundation
import ZIPFoundation

/// ネットワークボリューム上の zip / cbz / epub を読む ArchiveReading 実装。一覧を**中央ディレクトリだけから**作る。
///
/// ■ なぜ ZipArchiveReader(ZIPFoundation)と別にあるのか(docs/plans/network-volume-study.md)
/// ZIPFoundation 0.9.20 の一覧(`Archive.makeIterator`)は、エントリごとにローカルヘッダーへシークして読む(データ記述子付きの
/// zip ならその位置へもう 1 回)。ファイル全体に散らばった小さな読みが「エントリ数 × 1〜2 回」で、ネットワーク越しでは 1 回ごとに
/// 往復を待つ。1 往復 5ms の模擬で 200 ページの cbz の一覧が 2〜3 秒かかり、1 冊を開くあいだにそれを 3 回取っていた。
/// 任意の読み込み口を差し込む API も無い(Readium はこのためにフォークしている)。
///
/// ここでは末尾(EOCD・コメント・ZIP64 の位置)をまとめて 1 回、中央ディレクトリを 1 回で読み、ローカルヘッダーは取り出すときに
/// データと同じ 1 回の読みで読む。読みはすべて `RandomAccessSource`(ネットワーク上では `StagedFileSource`)を通す。
/// 伸長は ZIPFoundation の公開 API(`Data.decompress`)をそのまま使う。
///
/// ■ ZipArchiveReader と結果を一致させる(ページのキーが変わらないように)
/// 一覧のパス・種類・大きさ・日時、中身のバイト列は ZIPFoundation + ZipArchiveReader と**一致させる**:
/// - パスの復号(UTF-8 フラグ → UTF-8、無ければ codepage437 → `EntryNameDecoder` で書庫単位の補正)
/// - 種類の判定(`Entry.type` と同じ: 作成 OS が unix/osx なら外部属性の S_IFMT、msdos なら属性ビット、ほかは末尾の "/")
/// - EOCD の探し方(末尾 22 バイト目から 1 バイトずつ前へ、最初に見つかった署名。上限なし)
/// - ZIP64 の拾い方(locator は EOCD の直前 20 バイト、record はさらにその直前 56 バイトと決め打ち。拡張欄の値は 0 でなければ使う)
/// - 暗号化されたエントリで一覧が**止まる**こと(ZIPFoundation の Entry の init が nil を返し、反復が終わる)
/// - 補正後に同じパスになるエントリは先のものを採ること
/// - 格納は非圧縮サイズ、deflate は圧縮サイズぶん(どちらも中央ディレクトリの値)を読み、圧縮方式はローカルヘッダーのもの
/// - CRC は照合しない(ZIPFoundation の `extract(_:consumer:)` も照合しない。ZipArchiveReader.readEntry のコメント)
/// 2026-09-24 に、テストのフィクスチャ全件・境界ケース 22 本・実際の蔵書 8,266 本で突き合わせて一致を確かめた
/// (CentralDirectoryZipReaderTests が常に見ている)。
///
/// **違いは 1 つだけ(意図したもの)**: 中央ディレクトリは無事で、途中のローカルヘッダーだけが壊れた書庫。ZIPFoundation は
/// 一覧の時点でそこで打ち切るが、こちらは一覧に含め、そのエントリを取り出すときに失敗する(ページが増え、壊れたページが
/// 「読めないページ」になる)。ローカルヘッダーを一覧の時点で読まないことがこの reader の目的なので、揃えない。
/// ただし読まなくても分かる失敗(ローカルヘッダーの位置がファイルの終わりより後ろ)では、同じく一覧を打ち切る。
///
/// スレッド安全ではない(ほかの reader と同じ。PageLoader の actor などの中で 1 つのスレッドから使う)。出所は共有してよい。
nonisolated final class CentralDirectoryZipReader: ArchiveReading {
    private struct Record {
        let versionMadeBy: UInt16
        let dosTime: UInt16
        let dosDate: UInt16
        /// 中央ディレクトリの圧縮方式。取り出しはローカルヘッダーの方式に従う(ZIPFoundation と同じ)ので、これは
        /// 読み方を選ぶ目安にだけ使う(dataPrefix)。
        let cdCompressionMethod: UInt16
        /// 中央ディレクトリの値(ZIP64 の拡張欄があればそちら)。
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        /// ローカルヘッダーの長さの見積もりに使う(中央ディレクトリの名前・拡張欄の長さ)。
        let nameLength: Int
        let extraLength: Int
        /// ZIPFoundation の `Entry.path` と同じ文字列(補正前)。
        let mangledPath: String
        let kind: ArchiveEntryDescriptor.Kind
    }

    enum ReaderError: Error {
        case missingEndOfCentralDirectory
        case badLocalHeader
        case invalidCompressionMethod
    }

    private let source: RandomAccessSource
    private var records: [Record] = []
    private var recordIndexByCorrectedPath: [String: Int] = [:]
    private var nameDecoder: EntryNameDecoder?
    private var descriptors: [ArchiveEntryDescriptor]?

    /// 取り出しの 1 回の読みの上限。smbfs は 1 回の read を 256KB〜1MB の要求に分けて並べて送るので、1 回 ≒ 1 往復+転送。
    private static let readChunk = 4 * 1024 * 1024

    init(source: RandomAccessSource) throws {
        self.source = source
        try readCentralDirectory()
    }

    private var fileSize: UInt64 { source.size }

    private func read(_ offset: UInt64, _ count: Int) throws -> Data {
        try source.read(at: offset, count: count)
    }

    // MARK: - 中央ディレクトリ

    private func readCentralDirectory() throws {
        // 末尾をまとめて読む。EOCD(22)+コメント(最大 65535)+ZIP64 の locator(20)と record(56)が収まる大きさ。
        let tailLength = Int(min(fileSize, 65_535 + 22 + 20 + 56 + 1024))
        var tailStart = fileSize - UInt64(tailLength)
        var tail = try read(tailStart, tailLength)

        // ZIPFoundation と同じく、末尾 22 バイト目から 1 バイトずつ前へ、最初に見つかった署名を採る(上限なし)。
        var eocdOffset: UInt64?
        var position = Int64(fileSize) - 22
        while position >= 0 {
            let p = UInt64(position)
            if p < tailStart {
                // 末尾の窓の外(zip ではないファイルでだけ起きる)。1MB ずつ前へ広げる。
                let newStart = p >= 1 << 20 ? p - (1 << 20) + 1 : 0
                tail = try read(newStart, Int(tailStart - newStart)) + tail
                tailStart = newStart
            }
            let i = Int(p - tailStart)
            if i + 4 <= tail.count, tail.le32(i) == 0x0605_4b50 {
                eocdOffset = p
                break
            }
            position -= 1
        }
        guard let eocdOffset else { throw ReaderError.missingEndOfCentralDirectory }

        // 読んである末尾の窓の中ならそこから、外なら読む。
        func bytes(_ offset: UInt64, _ count: Int) throws -> Data {
            if offset >= tailStart, offset + UInt64(count) <= tailStart + UInt64(tail.count) {
                let i = Int(offset - tailStart)
                return tail.subdata(in: i..<(i + count))
            }
            return try read(offset, count)
        }

        let eocd = try bytes(eocdOffset, 22)
        guard eocd.count == 22 else { throw ReaderError.missingEndOfCentralDirectory }
        let commentLength = Int(eocd.le16(20))
        // ZIPFoundation はコメントを読み切れないと EOCD ごと失敗にする(開けない)。
        guard try bytes(eocdOffset + 22, commentLength).count == commentLength else {
            throw ReaderError.missingEndOfCentralDirectory
        }
        var totalEntries = UInt64(eocd.le16(10))
        var cdSize = UInt64(eocd.le32(12))
        var cdOffset = UInt64(eocd.le32(16))

        // ZIP64: ZIPFoundation と同じく、locator は EOCD の直前 20 バイト、record はさらにその直前 56 バイトと決め打ちで読む
        // (locator が指す位置は見ない)。record の「展開に要る版」が 4.5 未満なら ZIP64 として扱わない。
        if eocdOffset > 20 {
            let locatorOffset = eocdOffset - 20
            if locatorOffset > 56 {
                let recordOffset = locatorOffset - 56
                let locator = try bytes(locatorOffset, 20)
                let record = try bytes(recordOffset, 56)
                if locator.count == 20, locator.le32(0) == 0x0706_4b50,
                   record.count == 56, record.le32(0) == 0x0606_4b50, record.le16(14) >= 45 {
                    totalEntries = record.le64(32)
                    cdSize = record.le64(40)
                    cdOffset = record.le64(48)
                }
            }
        }

        let cd = try bytes(cdOffset, Int(min(cdSize, fileSize)))
        var all: [Record] = []
        var cursor = 0
        var index: UInt64 = 0
        while index < totalEntries {
            // 署名が合わない・途中で切れている → ZIPFoundation と同じくそこで一覧を終える。
            guard cursor + 46 <= cd.count, cd.le32(cursor) == 0x0201_4b50 else { break }
            let flags = cd.le16(cursor + 8)
            let nameLength = Int(cd.le16(cursor + 28))
            let extraLength = Int(cd.le16(cursor + 30))
            let fileCommentLength = Int(cd.le16(cursor + 32))
            let nameStart = cursor + 46
            guard nameStart + nameLength + extraLength + fileCommentLength <= cd.count else { break }
            // 暗号化されたエントリで一覧が止まる(ZIPFoundation と同じ)。
            if flags & 1 != 0 { break }
            let nameData = cd.subdata(in: nameStart..<(nameStart + nameLength))
            let extra = cd.subdata(in: (nameStart + nameLength)..<(nameStart + nameLength + extraLength))
            var compressedSize = UInt64(cd.le32(cursor + 20))
            var uncompressedSize = UInt64(cd.le32(cursor + 24))
            var localOffset = UInt64(cd.le32(cursor + 42))
            if let zip64 = Self.zip64Values(
                extra: extra,
                uncompressed: uncompressedSize == 0xFFFF_FFFF, compressed: compressedSize == 0xFFFF_FFFF,
                offset: localOffset == 0xFFFF_FFFF, disk: cd.le16(cursor + 34) == 0xFFFF
            ) {
                if zip64.uncompressed > 0 { uncompressedSize = zip64.uncompressed }
                if zip64.compressed > 0 { compressedSize = zip64.compressed }
                if zip64.offset > 0 { localOffset = zip64.offset }
            }
            // ZIPFoundation はここでローカルヘッダーを読み、読めなければ一覧を打ち切る。こちらは読まないが、**読まなくても
            // 分かる失敗**(ファイルの終わりより後ろ)だけは同じく打ち切る。ZIP64 の拡張欄の位置が 0(=先頭のエントリ)だと
            // ZIPFoundation は 32 ビットの 0xFFFFFFFF の方を使うので、小さな書庫ではここに当たる(テストで見つけた、2026-09-24)。
            guard localOffset + 30 <= fileSize else { break }
            let versionMadeBy = cd.le16(cursor + 4)
            let external = cd.le32(cursor + 38)
            // ZIPFoundation の Entry.path と同じ(Darwin では String(data:encoding:) ?? "")。
            let mangled = String(data: nameData, encoding: flags & (1 << 11) != 0 ? .utf8 : Self.codepage437) ?? ""
            all.append(Record(
                versionMadeBy: versionMadeBy, dosTime: cd.le16(cursor + 12), dosDate: cd.le16(cursor + 14),
                cdCompressionMethod: cd.le16(cursor + 10),
                compressedSize: compressedSize, uncompressedSize: uncompressedSize, localHeaderOffset: localOffset,
                nameLength: nameLength, extraLength: extraLength, mangledPath: mangled,
                kind: Self.kind(path: mangled, versionMadeBy: versionMadeBy, external: external)
            ))
            cursor = nameStart + nameLength + extraLength + fileCommentLength
            index += 1
        }

        // ここから下は ZipArchiveReader.indexEntries と同じ(判定の標本はファイルだけ、補正後に同じパスなら先のもの)。
        let fileIndices = all.indices.filter { all[$0].kind == .file }
        let decoder = EntryNameDecoder(mangledPaths: fileIndices.map { all[$0].mangledPath })
        for i in fileIndices {
            let path = decoder.correctedPath(for: all[i].mangledPath)
            if recordIndexByCorrectedPath[path] == nil { recordIndexByCorrectedPath[path] = i }
        }
        records = all
        nameDecoder = decoder
    }

    /// ZIPFoundation の `ZIP64ExtendedInformation.scanForZIP64Field` と同じ読み方。値は「0xFFFF… だった欄の順」に並び、
    /// 欄の数と拡張欄の大きさが合わなければ無いものとする。
    private static func zip64Values(extra: Data, uncompressed: Bool, compressed: Bool, offset: Bool, disk: Bool)
        -> (uncompressed: UInt64, compressed: UInt64, offset: UInt64)? {
        guard !extra.isEmpty else { return nil }
        var o = 0
        while o < extra.count - 4 {
            let id = extra.le16(o)
            let size = Int(extra.le16(o + 2))
            let next = o + 4 + size
            guard next <= extra.count else { return nil }
            if id == 0x0001 {
                let expected = (uncompressed ? 8 : 0) + (compressed ? 8 : 0) + (offset ? 8 : 0) + (disk ? 4 : 0)
                guard expected + 4 == next - o else { return nil }
                var r = o + 4
                var values: (uncompressed: UInt64, compressed: UInt64, offset: UInt64) = (0, 0, 0)
                if uncompressed { values.uncompressed = extra.le64(r); r += 8 }
                if compressed { values.compressed = extra.le64(r); r += 8 }
                if offset { values.offset = extra.le64(r) }
                return values
            }
            o = next
        }
        return nil
    }

    /// ZIPFoundation の `Entry.type` と同じ判定。
    private static func kind(path: String, versionMadeBy: UInt16, external: UInt32) -> ArchiveEntryDescriptor.Kind {
        let isDirectoryByName = path.hasSuffix("/")
        switch versionMadeBy >> 8 {
        case 3, 19: // unix, osx
            switch mode_t(UInt16(truncatingIfNeeded: external >> 16)) & S_IFMT {
            case S_IFREG: return .file
            case S_IFDIR: return .directory
            case S_IFLNK: return .symbolicLink
            default: return isDirectoryByName ? .directory : .file
            }
        case 0: // msdos
            return isDirectoryByName || (external >> 4) == 0x01 ? .directory : .file
        default:
            return isDirectoryByName ? .directory : .file
        }
    }

    private static let codepage437 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x400))
    )

    /// ZIPFoundation の `Date(dateTime:)` と同じ変換(MS-DOS の日時を UTC として組み立てる。現地時刻への直しは
    /// ZipDOSTime.localDate が行う)。
    private static func zipFoundationDate(date: UInt16, time: UInt16) -> Date {
        let msdos = Int(date) << 16 | Int(time)
        var t = tm()
        t.tm_sec = Int32((msdos & 31) * 2)
        t.tm_min = Int32((msdos >> 5) & 63)
        t.tm_hour = Int32((Int(time) >> 11) & 31)
        t.tm_mday = Int32((msdos >> 16) & 31)
        t.tm_mon = Int32((msdos >> 21) & 15) - 1
        t.tm_year = Int32(1980 + (msdos >> 25)) - 1900
        return Date(timeIntervalSince1970: TimeInterval(timegm(&t)))
    }

    // MARK: - 取り出し

    /// ローカルヘッダーとデータの先頭(最大 `firstChunk` バイト)を 1 回で読む。
    private func openEntry(_ record: Record, firstChunk: Int) throws
        -> (dataOffset: UInt64, method: UInt16, localCompressedSize: UInt32, head: Data) {
        // ローカルヘッダーの長さは読むまで分からない(拡張欄が中央ディレクトリと違うことがある)ので、中央ディレクトリの
        // 長さに少し余裕を足して見積もる。足りなければ続きは後で読む(provide)。
        let guess = 30 + record.nameLength + record.extraLength + 64
        let first = try read(record.localHeaderOffset, guess + max(firstChunk, 0))
        guard first.count >= 30, first.le32(0) == 0x0403_4b50 else { throw ReaderError.badLocalHeader }
        let headerLength = 30 + Int(first.le16(26)) + Int(first.le16(28))
        let head = first.count > headerLength ? first.subdata(in: headerLength..<first.count) : Data()
        return (record.localHeaderOffset + UInt64(headerLength), first.le16(8), first.le32(18), head)
    }

    /// エントリの中身を伸長しながら `consumer` へ渡す(`outputChunk` ずつ)。consumer が投げたら止める。
    private func stream(_ record: Record, outputChunk: Int, _ consumer: (Data) throws -> Void) throws {
        switch record.kind {
        case .directory:
            try consumer(Data())
            return
        case .symbolicLink:
            // ZIPFoundation と同じく、ローカルヘッダーの圧縮サイズぶんをそのまま渡す。
            let opened = try openEntry(record, firstChunk: 0)
            try consumer(try read(opened.dataOffset, Int(opened.localCompressedSize)))
            return
        case .file:
            break
        }
        let wanted = Int(min(UInt64(Self.readChunk), max(record.compressedSize, record.uncompressedSize)))
        let opened = try openEntry(record, firstChunk: wanted)
        let isStored: Bool
        let total: UInt64
        switch opened.method {
        case 0: (isStored, total) = (true, record.uncompressedSize)
        case 8: (isStored, total) = (false, record.compressedSize)
        default: throw ReaderError.invalidCompressionMethod
        }
        // 読みの提供役: 先頭は openEntry で読んだぶん、続きは readChunk ずつ。
        var buffered = opened.head
        var bufferedStart: UInt64 = 0
        func provide(_ position: Int64, _ size: Int) throws -> Data {
            let pos = UInt64(position)
            if pos >= bufferedStart, pos + UInt64(size) <= bufferedStart + UInt64(buffered.count) {
                let i = Int(pos - bufferedStart)
                return buffered.subdata(in: i..<(i + size))
            }
            let remaining = total > pos ? total - pos : 0
            buffered = try read(opened.dataOffset + pos, Int(min(UInt64(max(size, Self.readChunk)), remaining)))
            bufferedStart = pos
            return buffered.subdata(in: 0..<min(size, buffered.count))
        }
        if isStored {
            var position: UInt64 = 0
            while position < total {
                let chunk = try provide(Int64(position), Int(min(UInt64(outputChunk), total - position)))
                if chunk.isEmpty { break }
                try consumer(chunk)
                position += UInt64(chunk.count)
            }
        } else {
            _ = try Data.decompress(size: Int64(total), bufferSize: outputChunk, skipCRC32: true,
                                    provider: provide, consumer: consumer)
        }
    }

    private func record(at path: String) throws -> Record {
        guard let i = recordIndexByCorrectedPath[path] else { throw ArchiveReaderError.entryNotFound }
        return records[i]
    }

    // MARK: - ArchiveReading

    func listFilePaths() throws -> [String] {
        Array(recordIndexByCorrectedPath.keys)
    }

    func data(at path: String) throws -> Data {
        let r = try record(at: path)
        var result = Data()
        // 事前確保の上限は ZipArchiveReader と同じ(索引の申告は信用しない)。
        result.reserveCapacity(Int(min(r.uncompressedSize, 64 * 1024 * 1024)))
        try stream(r, outputChunk: 1 << 20) { result.append($0) }
        return result
    }

    private struct PrefixReached: Error {}

    /// 先頭だけ要るとき。格納(cbz の多く)なら要るぶんだけを 1 回で読む。deflate は伸長の流れのまま、溜まったら打ち切る。
    func dataPrefix(at path: String, maxByteCount: Int) throws -> Data {
        let r = try record(at: path)
        guard maxByteCount > 0 else { return Data() }
        if r.kind == .file, r.cdCompressionMethod == 0 {
            let want = Int(min(UInt64(maxByteCount), r.uncompressedSize))
            let opened = try openEntry(r, firstChunk: want)
            if opened.method == 0 {
                if opened.head.count >= want { return Data(opened.head.prefix(want)) }
                return try read(opened.dataOffset, want)
            }
            // 中央ディレクトリとローカルヘッダーで方式が違う(壊れた・細工された書庫)。ローカルヘッダーに従う通常の経路へ。
        }
        var result = Data()
        do {
            try stream(r, outputChunk: 256 * 1024) { chunk in
                result.append(chunk)
                if result.count >= maxByteCount { throw PrefixReached() }
            }
        } catch is PrefixReached {
            // 必要なぶんが読めたので打ち切っただけ。
        }
        return result
    }

    func entryDates(at path: String) -> (created: Date?, modified: Date?) {
        guard let r = try? record(at: path) else { return (nil, nil) }
        return (nil, ZipDOSTime.localDate(fromZIPFoundation: Self.zipFoundationDate(date: r.dosDate, time: r.dosTime)))
    }

    func extract(at path: String, to url: URL, maxByteCount: Int) throws {
        let r = try record(at: path)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ArchiveReaderError.cannotOpen }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var written = 0
            try stream(r, outputChunk: 1 << 20) { chunk in
                written += chunk.count
                guard written <= maxByteCount else { throw ArchiveReaderError.entryTooLarge }
                try handle.write(contentsOf: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func entryUncompressedSize(at path: String) -> Int64? {
        guard let r = try? record(at: path) else { return nil }
        return Int64(clamping: r.uncompressedSize)
    }

    func entriesInArchiveOrder() throws -> [ArchiveEntryDescriptor] {
        if let descriptors { return descriptors }
        let decoder = nameDecoder ?? EntryNameDecoder(mangledPaths: [])
        let made = records.map { r in
            ArchiveEntryDescriptor(
                path: decoder.correctedPath(for: r.mangledPath), kind: r.kind, uncompressedSize: r.uncompressedSize,
                modified: ZipDOSTime.localDate(fromZIPFoundation: Self.zipFoundationDate(date: r.dosDate, time: r.dosTime))
            )
        }
        descriptors = made
        return made
    }

    func readEntry(at path: String, _ body: (Data) throws -> Void) throws {
        try stream(try record(at: path), outputChunk: 1 << 18, body)
    }
}

private extension Data {
    nonisolated func le16(_ i: Int) -> UInt16 {
        UInt16(self[startIndex + i]) | UInt16(self[startIndex + i + 1]) << 8
    }

    nonisolated func le32(_ i: Int) -> UInt32 {
        UInt32(le16(i)) | UInt32(le16(i + 2)) << 16
    }

    nonisolated func le64(_ i: Int) -> UInt64 {
        UInt64(le32(i)) | UInt64(le32(i + 4)) << 32
    }
}

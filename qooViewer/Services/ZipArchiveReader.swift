import Foundation
import CoreFoundation
import ZIPFoundation
import UniversalCharsetDetection

/// zip / cbz を読むための ArchiveReading 実装。
///
/// 昔の日本語Windows/Macで作られたzipは、ファイル名がUTF-8ではなくShift-JIS等の
/// レガシーな文字コードで格納されていることがある(ZIPの仕様上、UTF-8フラグが
/// 立っていないと ZIPFoundation は codepage437 として読んでしまい、文字化けする)。
/// ここでは、文字化けしていそうなパスを codepage437 として元のバイト列に戻し、
/// UniversalCharsetDetection(uchardetのSwiftラッパー)で文字コードを推定し直して
/// 正しいファイル名に補正している。
/// nonisolated: PageLoader(actor、メインスレッド外)から呼ばれるため、Xcode 26既定の
/// MainActor自動分離の対象外にしている(詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated final class ZipArchiveReader: ArchiveReading {
    private let archive: Archive
    /// 補正後のパス -> 実際のZIPFoundationのEntry
    private var entryByCorrectedPath: [String: Entry] = [:]

    init(url: URL) throws {
        self.archive = try Archive(url: url, accessMode: .read)
        indexEntries()
    }

    /// 入れ子になった書庫を、ディスクへ書き出さずメモリ上のDataから直接開く。rar/7zと異なり
    /// ZIPFoundation自体がData版のAPIを持っているため、一時ファイルが不要
    /// (NestedArchiveResolver、およびArchiveKind.opensFromMemory参照)。
    ///
    /// **渡すDataは必ず独立した実体にすること。** ZIPFoundationのMemoryFileはこのDataを
    /// 保持し続ける(funopenでFILE*を被せ、読み出しのたびにcopyBytesする実装)。ここへ
    /// 親書庫のバッファのsubrange(スライス)をそのまま渡すと、Swiftのスライスは元の
    /// バッファ全体を参照し続けるため、この小さな書庫を1つ開いているだけで**親の全バイトが
    /// 道連れで常駐する**。取り出した結果をそのまま渡すぶんには問題ない
    /// (ArchiveReading.data(at:)はどの実装も新しいDataを組み立てて返す)。
    init(data: Data) throws {
        self.archive = try Archive(data: data, accessMode: .read)
        indexEntries()
    }

    private func indexEntries() {
        for entry in archive where entry.type == .file {
            entryByCorrectedPath[Self.correctedPath(for: entry)] = entry
        }
    }

    func listFilePaths() throws -> [String] {
        Array(entryByCorrectedPath.keys)
    }

    func data(at path: String) throws -> Data {
        guard let entry = entryByCorrectedPath[path] else { throw ArchiveReaderError.entryNotFound }
        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry) { chunk in
            result.append(chunk)
        }
        return result
    }

    /// 目的のバイト数に達したことを伝えるためだけの内部エラー。ZIPFoundationのextractは
    /// 「途中で止める」APIを持たないが、チャンクを受け取るクロージャ(Consumer)がthrowできる
    /// ので、それを打ち切りの合図として使い、呼び出し側で握り潰す。
    private struct PrefixReached: Error {}

    /// ArchiveReading.dataPrefix(at:maxByteCount:)のzip実装(プロトコル側のコメント参照)。
    /// 必要なバイト数が溜まった時点で伸長を打ち切る。
    ///
    /// extractは呼び出しのたびに対象エントリの先頭へ必ずシークし直す(ZIPFoundationの
    /// Archive+Reading.swift参照)ため、途中で打ち切ってもアーカイブ側の読み取り位置は
    /// 次回以降に影響しない。
    ///
    /// skipCRC32: true — CRC32はエントリ全体を読み切って初めて検証できる値で、途中で
    /// 打ち切るこの経路では最後まで計算しようがない。計算させても結果を使えないため省く
    /// (伸長した範囲のチェックサム計算ぶんだけ速くなる)。
    func dataPrefix(at path: String, maxByteCount: Int) throws -> Data {
        guard let entry = entryByCorrectedPath[path] else { throw ArchiveReaderError.entryNotFound }
        guard maxByteCount > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(min(maxByteCount, Int(entry.uncompressedSize)))
        do {
            _ = try archive.extract(entry, skipCRC32: true) { chunk in
                result.append(chunk)
                if result.count >= maxByteCount { throw PrefixReached() }
            }
        } catch is PrefixReached {
            // 必要なぶんが読めたので打ち切っただけ。正常系。
        }
        return result
    }

    /// zipのセントラルディレクトリはMS-DOS形式の更新日時しか持たず、作成日時という概念が無い
    /// ため、createdは常にnil(ArchiveReading.entryDates(at:)のコメント参照)。
    func entryDates(at path: String) -> (created: Date?, modified: Date?) {
        guard let entry = entryByCorrectedPath[path] else { return (nil, nil) }
        return (nil, entry.fileAttributes[.modificationDate] as? Date)
    }

    /// ArchiveReading.extract(at:to:)のzip実装(プロトコル側のコメント参照)。
    /// ZIPFoundationのextract(_:to:)は、伸長したチャンクをそのままFILE*へ書き出していく
    /// (Archive+Reading.swift参照)ため、エントリの大きさに関わらずメモリのピークは
    /// バッファ1つぶんに収まる。
    ///
    /// この関数は書き出し先が既に存在するとfileWriteFileExistsで失敗する。呼び出し側
    /// (NestedArchiveResolver)が毎回UUIDで新しいパスを払い出すため、通常は起こらない。
    func extract(at path: String, to url: URL) throws {
        guard let entry = entryByCorrectedPath[path] else { throw ArchiveReaderError.entryNotFound }
        _ = try archive.extract(entry, to: url)
    }

    /// セントラルディレクトリが持つ非圧縮サイズをそのまま返す(展開は伴わない)。
    func entryUncompressedSize(at path: String) -> Int64? {
        guard let entry = entryByCorrectedPath[path] else { return nil }
        return Int64(entry.uncompressedSize)
    }

    /// 文字化けしていそうな古いzipのパスを、文字コード自動判定で補正する。
    private static func correctedPath(for entry: Entry) -> String {
        let defaultPath = entry.path

        // codepage437として再エンコードできる = 実際のUTF-8(日本語などを含む)ではなく、
        // 1バイトずつcodepage437として誤読された文字列である可能性が高い、という判定。
        // (実在する日本語などの文字はcodepage437の文字集合に含まれないため、
        //  正しくUTF-8デコードされたパスは基本的にこの変換に失敗する)
        guard let rawBytes = defaultPath.data(using: .codepage437) else {
            return defaultPath
        }
        guard
            let detectedName = rawBytes.detectedCharacterEncoding,
            let encoding = stringEncoding(fromIANA: detectedName),
            encoding != .ascii, encoding != .utf8,
            let corrected = String(data: rawBytes, encoding: encoding),
            !corrected.isEmpty
        else {
            return defaultPath
        }
        return corrected
    }

    private static func stringEncoding(fromIANA name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}

/// ZIPFoundation内部にも同名の定義があるが、外部モジュールからは参照できない(internal)ため、
/// 同じ仕組み(DOS Latin US = codepage437)をこちらでも定義しておく。
/// nonisolated: 上のZipArchiveReader(nonisolated final class)のcorrectedPath(nonisolatedな
/// static func)から参照するため、こちらもXcode既定のMainActor自動分離の対象外にしておく必要がある
/// (付けないと「Main actor-isolated static property 'codepage437' can not be referenced from a
/// nonisolated context」というビルドエラーになる)。
private extension String.Encoding {
    nonisolated static let codepage437: String.Encoding = {
        let dosLatinUS = CFStringEncoding(0x400)
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(dosLatinUS)
        return String.Encoding(rawValue: nsEncoding)
    }()
}

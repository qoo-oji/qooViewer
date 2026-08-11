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

    /// zipのセントラルディレクトリはMS-DOS形式の更新日時しか持たず、作成日時という概念が無い
    /// ため、createdは常にnil(ArchiveReading.entryDates(at:)のコメント参照)。
    func entryDates(at path: String) -> (created: Date?, modified: Date?) {
        guard let entry = entryByCorrectedPath[path] else { return (nil, nil) }
        return (nil, entry.fileAttributes[.modificationDate] as? Date)
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

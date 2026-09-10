import Foundation
import CoreGraphics
import ZIPFoundation

/// コレクション表紙をzipにまとめて書き出す/読み戻すための、ファイル側の役
/// (ユーザー要望 2026-09-11)。
///
/// ■ 何を出すのか
/// **利用者が画像を指定した表紙だけ**(`BookLayoutSettings.shelfCoverImageFileName`)。既定
/// (本の先頭ページ)や、本の中のページを選んだだけの表紙は、その本さえあればいつでも作り直せる
/// ので出す意味が無い。出す価値があるのは「利用者が外から持ってきた絵」で、しかもそれは
/// 元ファイルが失われていることがある(2026-09-11の実測では131冊すべてが失われていた)。
/// **このzipが、その絵の唯一の控えになりうる。**
///
/// ■ なぜ変換しないのか
/// 保管庫(CollectionCoverSourceStore)が既にJPEGなので、**バイトのまま複製するだけでよい**
/// (ユーザー判断 2026-09-11)。復号も再エンコードもしないので劣化せず、速く、本体が未接続の
/// ボリューム上にあっても書き出せる。zipのエントリも無圧縮で入れる(JPEGは既に圧縮済み)。
///
/// ■ ファイル名
/// 本の名前(フォルダはフォルダ名、ファイルは拡張子を落としたもの。
/// `MetadataEditorViewModel.baseName(forBookID:)`)に`.jpg`を付ける。同じ名前の本が複数あれば
/// ` (2)`と番号を足す。名前は本を指し示すための**照合の手がかり**でもあるので、
/// `manifest.json`にエントリ名とbookIDの対応も一緒に入れておく ―― 読み込み側は、名前を
/// 付け替えられていなければmanifestで正確に、付け替えられていれば名前で照合する。
nonisolated enum ShelfCoverArchive {
    /// zipに入れる1件。
    struct Entry: Sendable {
        /// zipの中でのファイル名(拡張子込み)。
        let fileName: String
        /// この表紙が紐付いている本(manifestに書く)。
        let bookID: String
        /// 保管庫の中の実体。
        let sourceURL: URL
    }

    struct ExportResult: Sendable {
        /// 実際に書き出せた件数。
        let written: Int
        /// 実体が読めずに飛ばした本のbookID(ウインドウ下部に出す)。
        let skipped: [String]
    }

    /// manifestのファイル名。**この名前のエントリは表紙として扱わない**(読み込み側も同じ)。
    static let manifestFileName = "qooViewer-covers.json"

    /// manifestの中身。読み込み側が知らない版を読まされたときに気づけるよう`version`を持つ。
    struct Manifest: Codable, Sendable {
        struct Item: Codable, Sendable {
            let fileName: String
            let bookID: String
        }
        var version: Int = 1
        var generator: String = "qooViewer"
        var exportedAt: Date
        var items: [Item]
    }

    // MARK: - 書き出し

    /// zipを1つ作る。`destination`に既にファイルがあれば置き換える(保存パネルが上書きの確認を
    /// 済ませている)。
    ///
    /// **必ずメインアクターの外から呼ぶこと。** ファイルの複製とzipの書き込みを行う。
    static func write(entries: [Entry], to destination: URL) throws -> ExportResult {
        // 途中で失敗したときに、書きかけのzipを保存先に残さない ―― 一時ファイルへ作ってから
        // 差し替える(CollectionCoverStore.writeが`.atomic`で書くのと同じ考え方)。
        let workURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qooViewer-covers-\(UUID().uuidString).zip", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: workURL) }

        let archive = try Archive(url: workURL, accessMode: .create)
        var written: [Manifest.Item] = []
        var skipped: [String] = []
        for entry in entries {
            guard let data = try? Data(contentsOf: entry.sourceURL, options: .mappedIfSafe) else {
                // 保管庫のファイルが消えている(ストアを作り直した等)。1件で全体を止めない。
                skipped.append(entry.bookID)
                continue
            }
            try addEntry(to: archive, path: entry.fileName, data: data, compressed: false)
            written.append(Manifest.Item(fileName: entry.fileName, bookID: entry.bookID))
        }

        let manifest = Manifest(exportedAt: Date(), items: written)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try addEntry(
            to: archive, path: manifestFileName, data: try encoder.encode(manifest), compressed: true
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: workURL, to: destination)
        return ExportResult(written: written.count, skipped: skipped)
    }

    /// 本の名前から、zipの中で使うファイル名を決める。同じ名前が既にあれば` (2)`と足す。
    ///
    /// 名前はNFCへ揃える(CbzExporter/EpubExporterと同じ理由。`nfcNormalizedForExport`の
    /// コメント参照 ―― APFSはNFDのまま返すので、揃えないとWindowsで濁点が分離して見える)。
    /// 制御文字とパス区切りは落とす。**先頭のドットも落とす**(不可視ファイルにしない)。
    static func uniqueFileName(
        forBaseName baseName: String, extension ext: String, used: inout Set<String>
    ) -> String {
        let cleaned = sanitized(baseName)
        var candidate = "\(cleaned).\(ext)"
        var suffix = 2
        // 大文字小文字を区別しないファイルシステムでぶつからないよう、畳んで比べる。
        while used.contains(candidate.lowercased()) {
            candidate = "\(cleaned) (\(suffix)).\(ext)"
            suffix += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    private static func sanitized(_ baseName: String) -> String {
        var value = nfcNormalizedForExport(baseName)
        value = String(value.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && scalar != "/" && scalar != "\\"
        })
        value = value.trimmingCharacters(in: .whitespaces)
        while value.hasPrefix(".") { value.removeFirst() }
        // 長すぎる名前はファイルシステムが受け取れない(255バイト)。拡張子と連番のぶんを残す。
        while value.utf8.count > 200, !value.isEmpty { value.removeLast() }
        return value.isEmpty ? "book" : value
    }

    // MARK: - 読み込み

    /// zipから読み出した表紙1件。
    struct ImportedEntry: Sendable {
        /// zipの中でのファイル名。**照合にしか使わない。** 保管庫へ書くときの名前は
        /// こちらが振るUUIDなので、この文字列がディスクのパスへ流れ込むことは無い
        /// (CollectionCoverSourceStoreの型コメント参照。これでZip Slipは構造的に起きない)。
        let entryName: String
        /// 拡張子を落とした照合用の名前。
        let baseName: String
        let data: Data
        /// そのまま持てるか、焼き直しが要るか、取り込めないか。
        let verdict: ImageIntegrityCheck.Verdict
        /// manifestに書かれていた本(名前を付け替えられていればnil)。
        let bookIDFromManifest: String?
    }

    struct ReadResult: Sendable {
        var entries: [ImportedEntry] = []
        /// 中身を見るまでもなく飛ばしたエントリ(大きすぎる・フォルダ・Finderの残骸)。
        var ignored: [String] = []
    }

    /// 読み込むzipの上限。細工されたzip(いわゆるzip爆弾)で、展開しただけでメモリと
    /// ディスクを食い尽くされないようにするためのもの。表紙は1冊1枚の小さな画像なので、
    /// 実用上これに引っかかる正当なzipは無い。
    static let maxEntryCount = 5000
    static let maxEntryBytes: Int64 = 32 * 1024 * 1024
    static let maxTotalBytes: Int64 = 1024 * 1024 * 1024

    /// zipを読み、中の画像を検査して返す。**必ずメインアクターの外から呼ぶこと。**
    ///
    /// 展開はすべてメモリ上で行う(一時ファイルを作らない)。取り込むかどうかの判断と
    /// 保管庫への書き込みは呼び出し側(画面)が行う ―― ここは「何が入っていたか」を返すだけ。
    static func read(zipAt url: URL, maxPixelSize: CGFloat) throws -> ReadResult {
        let reader = try makeArchiveReader(for: url)
        let paths = try reader.listFilePaths()
        var result = ReadResult()
        var total: Int64 = 0
        var manifestByEntryName: [String: String] = [:]

        // manifestを先に読む(あれば、名前ではなくこちらで正確に照合できる)。
        if let manifestPath = paths.first(where: { lastComponent($0) == manifestFileName }),
           let data = try? reader.data(at: manifestPath) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let manifest = try? decoder.decode(Manifest.self, from: data), manifest.version == 1 {
                for item in manifest.items { manifestByEntryName[item.fileName] = item.bookID }
            }
        }

        for path in paths.prefix(maxEntryCount) {
            let name = lastComponent(path)
            // manifest自身・Finderの残骸・隠しファイルは表紙ではない。
            guard name != manifestFileName, !isAppleDoubleEntry(path), !isHiddenArchiveEntry(path)
            else { continue }
            if let size = reader.entryUncompressedSize(at: path), size > maxEntryBytes {
                result.ignored.append(name)
                continue
            }
            guard let data = try? reader.data(at: path), !data.isEmpty else {
                result.ignored.append(name)
                continue
            }
            total += Int64(data.count)
            guard total <= maxTotalBytes else { break }
            result.entries.append(
                ImportedEntry(
                    entryName: name,
                    baseName: (name as NSString).deletingPathExtension,
                    data: data,
                    verdict: ImageIntegrityCheck.inspect(data, maxPixelSize: maxPixelSize),
                    bookIDFromManifest: manifestByEntryName[name]
                )
            )
        }
        if paths.count > maxEntryCount {
            result.ignored.append(contentsOf: paths.dropFirst(maxEntryCount).map(lastComponent))
        }
        return result
    }

    /// zipのエントリ名から最後の要素だけを取る。**フォルダに入ったzipも受け取れるようにする**
    /// ため ―― Finderの「圧縮」はフォルダごと固めると`表紙/第1巻.jpg`のような名前になる。
    /// パス部分はここで完全に捨てるので、以降どこにも渡らない。
    private static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    // MARK: - ZIPFoundationへの書き込み

    private static func addEntry(
        to archive: Archive, path: String, data: Data, compressed: Bool
    ) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compressed ? .deflate : .none
        ) { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        }
    }
}

import Foundation
import ZIPFoundation

/// 項目を zip に固める(改善要望7 段階 6、2026-09-14)。**ブロッキングする**ので FileIO の上で呼ぶ
/// (段取りは FileOperationService の `compress`)。
///
/// ■ ZIPFoundation で書く
/// libarchive を同梱しない(依存を増やさない。書き出し機能と同じライブラリ)。エントリ名は **NFC に正規化**して渡す
/// (APFS は NFD で返すことがあり、そのまま入れると Windows で濁点が分かれる ―― `nfcNormalizedForExport` のコメント)。
/// ZIPFoundation は汎用フラグ bit 11(UTF-8)を常に立てる。
///
/// ■ 入れ方(Finder の「圧縮」に合わせたところ)
/// - フォルダはフォルダごと入れる(`Folder/001.jpg`。Finder と同じ)。複数を選んだら、それぞれを最上位に並べる。
/// - 隠しファイル(`.DS_Store`、`._*` を含む先頭がドットの名前)とフォルダのカスタムアイコン(`Icon\r`)は入れない。
///   **選んだ項目そのもの**は隠しファイルでも入れる(明示的に選んだので)。
/// - 記号リンクはリンクとして入れる(ZIPFoundation の既定。辿らない)。ソケットなどの特殊なファイルは入れない。
/// - 圧縮方式はファイルごと: 既に圧縮されている形式(画像・書庫・PDF・EPUB・動画)は無圧縮(縮まらず CPU だけを使う ―― CbzExporter と同じ判断)、
///   それ以外は deflate。
///
/// ■ 一時名に書いてから置く
/// 出力先と同じフォルダの `.qooViewer-compress-<UUID>.zip` に書き、書き終えたら `name.zip`(塞がっていれば `name 2.zip`)へ
/// `renamex_np(RENAME_EXCL)`。中止・失敗で出来損ないを残さない。
nonisolated enum ZipCompressor {
    /// 1 件を入れるときに見るもの。
    struct Source: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case file, directory, symbolicLink }
        let url: URL
        /// zip の中のパス(NFC。フォルダは末尾の `/` なし)。
        let entryPath: String
        let kind: Kind
        let size: Int64
    }

    static let temporaryFilePrefix = ".qooViewer-compress-"

    /// 出力の名前(拡張子を含まない)。1 件ならその名前(Finder と同じく、ファイルなら拡張子ごと `a.jpg.zip`)、
    /// 複数なら入っているフォルダの名前。フォルダの名前が取れない(`/` など)なら「アーカイブ」。
    static func archiveBaseName(for items: [URL]) -> String {
        if items.count == 1, let item = items.first { return item.lastPathComponent }
        let parent = items.first?.deletingLastPathComponent().lastPathComponent ?? ""
        return parent.isEmpty || parent == "/" ? String(localized: "Archive", language: AppLanguage.currentLocale) : parent
    }

    /// 入れるものを並べる。読めないフォルダは失敗させる(黙って欠けた zip を作らない)。
    static func collect(_ items: [URL]) throws -> [Source] {
        var sources: [Source] = []
        for item in items {
            if Cancellation.isRequestedInCurrentScope { throw CancellationError() }
            let topName = item.lastPathComponent
            guard let top = kindAndSize(ofPath: item.path) else {
                throw FileOperationError.itemMissing(item)
            }
            guard let topKind = top.kind else { continue }
            sources.append(Source(url: item, entryPath: nfcNormalizedForExport(topName), kind: topKind, size: top.size))
            guard topKind == .directory else { continue }
            guard let enumerator = FileManager.default.enumerator(atPath: item.path) else {
                throw FileOperationError.posixFailure(item: item, errnoCode: EACCES)
            }
            // 列挙はディスク上の順(名前順ではない)。書庫の中の並びを毎回同じにするため、要素ごとの名前順に並べ替える
            // (親フォルダは子より前に来る)。
            var children: [Source] = []
            defer {
                sources += children.sorted { $0.entryPath.split(separator: "/").lexicographicallyPrecedes($1.entryPath.split(separator: "/")) }
            }
            while let relative = enumerator.nextObject() as? String {
                if Cancellation.isRequestedInCurrentScope { throw CancellationError() }
                let name = (relative as NSString).lastPathComponent
                let child = item.appendingPathComponent(relative)
                guard let info = kindAndSize(ofPath: child.path) else { continue }
                if isExcluded(name) {
                    if info.kind == .directory { enumerator.skipDescendants() }
                    continue
                }
                guard let kind = info.kind else { continue }
                children.append(Source(
                    url: child, entryPath: nfcNormalizedForExport(topName + "/" + relative), kind: kind, size: info.size
                ))
            }
        }
        return sources
    }

    /// 入れない名前(型コメント)。
    static func isExcluded(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "Icon\r"
    }

    /// 無圧縮で入れる拡張子(既に圧縮されている形式)。
    static let storedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "jxl",
        "zip", "cbz", "rar", "cbr", "7z", "cb7", "gz", "bz2", "xz", "zst", "lz4",
        "pdf", "epub",
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "mp3", "m4a", "aac", "flac", "ogg", "opus",
    ]

    static func compressionMethod(for entryPath: String) -> CompressionMethod {
        storedExtensions.contains((entryPath as NSString).pathExtension.lowercased()) ? .none : .deflate
    }

    /// `sources` を固めて `folder` に置く。中止なら nil(一時ファイルは消してある)。
    static func compress(
        _ sources: [Source], into folder: URL, baseName: String, fileExtension: String, tracker: ProgressTracker
    ) throws -> URL? {
        let temporary = folder.appendingPathComponent("\(temporaryFilePrefix)\(UUID().uuidString).zip")
        do {
            let archive = try Archive(url: temporary, accessMode: .create)
            for source in sources {
                if Cancellation.isRequestedInCurrentScope { throw CancellationError() }
                // 件数はファイルだけ数える(総数もファイルの数。FileOperationService.compress)。
                if source.kind == .file { tracker.startEntry(named: source.url.lastPathComponent) }
                try add(source, to: archive, tracker: tracker)
                if source.kind == .file { tracker.finishEntry() }
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if error is CancellationError { return nil }
            throw error
        }
        var tried: Set<String> = []
        let preferred = baseName + "." + fileExtension
        while true {
            let name = FileNameValidation.nextAvailableName(for: preferred) { candidate in
                tried.contains(candidate) || FileOperationService.itemExists(at: folder.appendingPathComponent(candidate))
            }
            let target = folder.appendingPathComponent(name)
            let code = FileOperationService.exclusiveRename(from: temporary, to: target)
            if code == 0 { return target }
            guard code == EEXIST else {
                try? FileManager.default.removeItem(at: temporary)
                throw FileOperationError.posixFailure(item: target, errnoCode: code)
            }
            tried.insert(name)
        }
    }

    private static func add(_ source: Source, to archive: Archive, tracker: ProgressTracker) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.url.path)
        // ZIPFoundation は日時を UTC として書くので、現地時刻になるようにずらして渡す(ZipDOSTime)。
        let modified = ZipDOSTime.zipFoundationDate(forLocal: attributes?[.modificationDate] as? Date ?? Date())
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value
        switch source.kind {
        case .directory:
            try archive.addEntry(
                with: source.entryPath + "/", type: .directory, uncompressedSize: Int64(0), modificationDate: modified,
                permissions: permissions, provider: { _, _ in Data() }
            )
        case .symbolicLink:
            let target = Data(try FileManager.default.destinationOfSymbolicLink(atPath: source.url.path).utf8)
            try archive.addEntry(
                with: source.entryPath, type: .symlink, uncompressedSize: Int64(target.count), modificationDate: modified,
                permissions: permissions, provider: { _, _ in target }
            )
        case .file:
            let before = MoveVerification.stamp(of: source.url)
            let descriptor = open(source.url.path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw FileOperationError.posixFailure(item: source.url, errnoCode: errno) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            try archive.addEntry(
                with: source.entryPath, type: .file, uncompressedSize: source.size, modificationDate: modified,
                permissions: permissions, compressionMethod: compressionMethod(for: source.entryPath),
                bufferSize: 1 << 20
            ) { _, size in
                if Cancellation.isRequestedInCurrentScope { throw CancellationError() }
                let chunk = try handle.read(upToCount: size) ?? Data()
                // 数えた大きさより短い = 読んでいる間に縮んだ。ZIPFoundation は短いチャンクを知らずに先へ進み、壊れた zip になる。
                guard chunk.count == size else { throw FileOperationError.sourceChangedDuringOperation(source.url) }
                tracker.addBytes(Int64(chunk.count))
                return chunk
            }
            // 読んでいる間に伸びた・書き換わった(宣言した大きさまでしか入っていない)。
            if MoveVerification.stamp(of: source.url) != before {
                throw FileOperationError.sourceChangedDuringOperation(source.url)
            }
        }
    }

    /// 種類と大きさ。**リンクを辿らない**。無ければ nil、入れない種類(ソケットなど)なら kind が nil。
    private static func kindAndSize(ofPath path: String) -> (kind: Source.Kind?, size: Int64)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return (.file, Int64(info.st_size))
        case S_IFDIR: return (.directory, 0)
        case S_IFLNK: return (.symbolicLink, 0)
        default: return (nil, 0)
        }
    }
}

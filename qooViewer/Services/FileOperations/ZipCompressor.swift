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

    /// 入れるものを並べる。**読めないフォルダ・調べられない項目は、どの深さでも失敗させる**(黙って欠けた zip を作らない)。
    ///
    /// 以前は `FileManager.enumerator(atPath:)` で歩いていたが、これは読めない(0000 など)サブフォルダを**黙って飛ばして正常に終わる**
    /// (2026-09-14 の 2 回目の監査で実測)ので、最上位より下の読めないフォルダは空のフォルダとして入り、`lstat` に失敗した子
    /// (パスが PATH_MAX を超える、など)も黙って抜けていた。利用者は出来た zip を信じて元を消しうる。自分で歩いて失敗を拾う。
    /// 途中で消えた項目(ENOENT)だけは、元から無かったものとして飛ばす。
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
            // 列挙はディスク上の順(名前順ではない)。書庫の中の並びを毎回同じにするため、要素ごとの名前順に並べ替える
            // (親フォルダは子より前に来る)。
            var children: [Source] = []
            defer {
                sources += children.sorted { $0.entryPath.split(separator: "/").lexicographicallyPrecedes($1.entryPath.split(separator: "/")) }
            }
            // 再帰せずに自分のスタックで歩く(相対パス。"" は最上位)。
            var pendingFolders = [""]
            while let folder = pendingFolders.popLast() {
                if Cancellation.isRequestedInCurrentScope { throw CancellationError() }
                let folderURL = folder.isEmpty ? item : item.appendingPathComponent(folder)
                let names: [String]
                do {
                    names = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)
                } catch {
                    let code = posixCode(of: error) ?? EACCES
                    if !folder.isEmpty, code == ENOENT { continue }
                    throw FileOperationError.posixFailure(item: folderURL, errnoCode: code)
                }
                for name in names {
                    if Cancellation.isRequestedInCurrentScope { throw CancellationError() }
                    // 隠しファイル・隠しフォルダは中へも入らない。
                    if isExcluded(name) { continue }
                    let relative = folder.isEmpty ? name : folder + "/" + name
                    let child = item.appendingPathComponent(relative)
                    var info = stat()
                    guard lstat(child.path, &info) == 0 else {
                        let code = errno
                        if code == ENOENT { continue }
                        throw FileOperationError.posixFailure(item: child, errnoCode: code)
                    }
                    guard let kind = sourceKind(of: info) else { continue }
                    children.append(Source(
                        url: child, entryPath: nfcNormalizedForExport(topName + "/" + relative), kind: kind,
                        size: kind == .file ? Int64(info.st_size) : 0
                    ))
                    if kind == .directory { pendingFolders.append(relative) }
                }
            }
        }
        return sources
    }

    /// Foundation のエラーの下にある errno(無ければ nil)。
    private static func posixCode(of error: any Error) -> Int32? {
        let nsError = error as NSError
        let underlying = nsError.domain == NSPOSIXErrorDomain ? nsError : nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        guard let underlying, underlying.domain == NSPOSIXErrorDomain else { return nil }
        return Int32(underlying.code)
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
            // ここで `archive` の寿命が終わり、ZIPFoundation が閉じる(最後のセントラルディレクトリと EOCD はそこで書かれる)。
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if error is CancellationError { return nil }
            throw error
        }
        do {
            try verifyWrittenArchive(
                at: temporary, expectedEntryCount: sources.count,
                reportingAs: folder.appendingPathComponent(baseName + "." + fileExtension)
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
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

    /// 書き終えた一時ファイルが**最後まで書けているか**を、置く前に確かめる(2026-09-14 の 2 回目の監査)。
    ///
    /// ZIPFoundation 0.9.20 は `addEntry` の `defer { fflush }` と `deinit` の `fclose` の結果を捨てる。最後のエントリの
    /// セントラルディレクトリと EOCD は stdio のバッファに残っているので、そこでディスクが溢れても(ENOSPC)誰にも届かず、
    /// 末尾の欠けた zip が成功として `name.zip` になっていた(8MB の使い捨てボリュームで実測: 開き直すと
    /// `missingEndOfCentralDirectoryRecord`)。空き容量の事前検査は元の合計と余裕しか見ないので、管理情報の分で超えうる。
    /// `fsync` で遅れて返る書き込みの失敗(ネットワークの共有)を拾い、読み取りで開き直してエントリの数を数える。
    /// - Parameter reportedItem: 失敗の文に出す名前(一時ファイルの名前は利用者に意味が無い)。
    static func verifyWrittenArchive(at url: URL, expectedEntryCount: Int, reportingAs reportedItem: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw FileOperationError.posixFailure(item: reportedItem, errnoCode: errno) }
        let syncFailure = fsync(descriptor) == 0 ? 0 : errno
        close(descriptor)
        // EINVAL / ENOTSUP は fsync を持たないファイルシステム(失敗ではない)。
        if syncFailure != 0, syncFailure != EINVAL, syncFailure != ENOTSUP {
            throw FileOperationError.posixFailure(item: reportedItem, errnoCode: syncFailure)
        }
        var count = 0
        do {
            let archive = try Archive(url: url, accessMode: .read)
            for _ in archive { count += 1 }
        } catch {
            count = -1
        }
        guard count == expectedEntryCount else {
            // 理由は分からない(書き込みは成功を返していた)ので、空きが余裕を割っていればディスクの不足、それ以外は入出力エラーとして伝える。
            let folder = url.deletingLastPathComponent()
            let isFull = FileOperationPreflight.availableCapacity(at: folder).map { $0 < FileOperationPreflight.freeSpaceMargin(at: folder) } ?? false
            throw FileOperationError.posixFailure(item: reportedItem, errnoCode: isFull ? ENOSPC : EIO)
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
        let kind = sourceKind(of: info)
        return (kind, kind == .file ? Int64(info.st_size) : 0)
    }

    /// 入れる種類。ソケット・FIFO・デバイスなどは nil。
    private static func sourceKind(of info: stat) -> Source.Kind? {
        switch info.st_mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        default: nil
        }
    }
}

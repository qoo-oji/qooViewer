import Foundation
import SevenZip
import Unrar

/// 書庫の展開(改善要望7 段階 6、2026-09-14)。zip / cbz / epub / rar / cbr / 7z / cb7。
/// **ブロッキングする**ので FileIO の上で呼ぶ(段取りは FileOperationService の `extract`)。
///
/// ■ 読むのは既存の ArchiveReading
/// 形式ごとの違い(zip の文字コードの補正 = EntryNameDecoder、7z のストリーミング、rar のコールバック)は reader の中にある。
/// 展開のために別の読み方を持たない ―― 本として開いたときと展開したときで名前が食い違わない。
///
/// ■ 一時フォルダに全部書いてから置く
/// 展開先と同じフォルダの `.qooViewer-extract-<UUID>/` へ書き、書き終えてから最終の場所へ `renamex_np(RENAME_EXCL)` で置く
/// (衝突は `name 2`)。中止・失敗なら一時フォルダごと消す ―― qooLibrary で「止めたのに 20MB の中途半端なフォルダが残り、
/// 成功として扱われていた」。同じフォルダに置くのは、最後の移動を rename で一瞬にするため(別の場所から運ぶと、
/// 別のボリュームなら全部をもう一度コピーする)。
///
/// ■ 書き込み
/// - ファイルは `open(O_CREAT | O_EXCL | O_NOFOLLOW)` で作る。一時フォルダは作ったばかりで記号リンクを 1 つも作らない
///   (ArchiveExtractionPlan が捨てる)ので、`..` を除いたパスが外へ出る道は無い。それでも既存の何かを辿って書かない形にしておく。
/// - **`FileHandle.write(contentsOf:)`(投げる版)**。投げない `write(_:)` はディスクフルで ObjC の例外になり、アプリが SIGABRT で落ちた(qooLibrary 実測)。
/// - 書いた量を自分で数え、限度(合計・圧縮比)を超えたらその場で止める。索引の宣言サイズは信じない。
nonisolated enum ArchiveExtractor {
    /// どこへ置くか。
    enum Placement: Sendable, Equatable {
        /// 展開先の直下に中身を並べる(「ここに展開」「展開先を選んで展開…」)。
        case contents
        /// 書庫の名前のフォルダを作ってその中へ(「〈名前〉に展開」)。同じ名前があれば `name 2`。
        case ownFolder
    }

    /// 展開する前に確かめ終えた 1 冊。
    struct Prepared: Sendable {
        let archive: URL
        let plan: ArchiveExtractionPlan
    }

    /// 開いて一覧を作り、限度を確かめる。1 バイトも書かない。
    static func prepare(_ archive: URL, limits: ArchiveExtractionLimits) throws -> Prepared {
        let reader = try openReader(archive)
        let entries: [ArchiveEntryDescriptor]
        do {
            entries = try reader.entriesInArchiveOrder()
        } catch {
            throw classify(error, archive: archive)
        }
        let plan = ArchiveExtractionPlan(entries: entries)
        if plan.hasEncryptedEntries { throw ArchiveOperationError.encrypted(archive: archive) }
        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        try plan.checkLimits(limits, archiveSize: archiveSize, archive: archive)
        return Prepared(archive: archive, plan: plan)
    }

    /// 一時フォルダの名前の頭。
    static let temporaryFolderPrefix = ".qooViewer-extract-"

    /// 展開して置く。中止されたら nil(一時フォルダは消してある)。
    ///
    /// - Returns: 置いた項目(`.ownFolder` なら作ったフォルダ 1 つ、`.contents` なら直下に並べた項目)。
    static func extract(
        _ prepared: Prepared, into folder: URL, placement: Placement, limits: ArchiveExtractionLimits, tracker: ProgressTracker
    ) throws -> [TransferReceipt]? {
        let archive = prepared.archive
        let reader = try openReader(archive)
        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        let temporary = folder.appendingPathComponent("\(temporaryFolderPrefix)\(UUID().uuidString)", isDirectory: true)
        guard mkdir(temporary.path, 0o700) == 0 else {
            throw FileOperationError.posixFailure(item: folder, errnoCode: errno)
        }
        var written: UInt64 = 0
        do {
            // フォルダは先に全部作る(空のフォルダも残す)。
            for item in prepared.plan.items where item.isDirectory {
                try makeDirectories(temporary.appendingPathComponent(item.relativePath, isDirectory: true), under: temporary)
            }
            var pending = Dictionary(
                prepared.plan.items.filter { !$0.isDirectory }.map { ($0.sourcePath, $0) }, uniquingKeysWith: { first, _ in first }
            )
            var current: OpenEntry?
            do {
                // **書庫の順に 1 回だけ読む**(readEntriesInArchiveOrder の型コメント。ソリッドの rar を 1 項目ずつ読むと 2 乗になった)。
                try reader.readEntriesInArchiveOrder { path in
                    try current?.finish(tracker: tracker)
                    current = nil
                    if Cancellation.isRequestedInCurrentScope { throw CancellationError() }
                    // 計画に無いもの(__MACOSX・捨てたエントリ)と、同じパスの 2 つ目は読み飛ばす。
                    guard let item = pending.removeValue(forKey: path) else { return nil }
                    let target = temporary.appendingPathComponent(item.relativePath)
                    tracker.startEntry(named: target.lastPathComponent)
                    try makeDirectories(target.deletingLastPathComponent(), under: temporary)
                    let entry = try OpenEntry(item: item, target: target)
                    current = entry
                    return { chunk in
                        if Cancellation.isRequestedInCurrentScope { throw CancellationError() }
                        let (sum, overflow) = written.addingReportingOverflow(UInt64(chunk.count))
                        written = overflow ? .max : sum
                        guard written <= limits.maxTotalBytes else {
                            throw ArchiveOperationError.tooLarge(archive: archive, limit: limits.maxTotalBytes)
                        }
                        guard !limits.exceedsCompressionRatio(expandedBytes: written, archiveSize: archiveSize) else {
                            throw ArchiveOperationError.suspiciousCompressionRatio(archive: archive)
                        }
                        try entry.write(chunk)
                        tracker.addBytes(Int64(chunk.count))
                    }
                }
                try current?.finish(tracker: tracker)
                current = nil
            } catch {
                current?.abandon()
                throw classifyWhileReading(error, archive: archive)
            }
            // フォルダの日時は中身を書き終えてから(書くたびに更新日時が変わる)。
            for item in prepared.plan.items where item.isDirectory {
                setModificationDate(item.modified, of: temporary.appendingPathComponent(item.relativePath))
            }
            return try place(temporary, archive: archive, into: folder, placement: placement)
        } catch is CancellationError {
            try? FileOperationService.removeAbsorbingTransientFailure(at: temporary)
            return nil
        } catch {
            try? FileOperationService.removeAbsorbingTransientFailure(at: temporary)
            throw error
        }
    }

    // MARK: - 下請け

    private static func openReader(_ archive: URL) throws -> ArchiveReading {
        do {
            return try makeArchiveReader(for: archive)
        } catch {
            throw classify(error, archive: archive)
        }
    }

    /// 書いている途中の 1 ファイル。
    ///
    /// ファイルは `open(O_CREAT | O_EXCL | O_NOFOLLOW)` で作る(型コメント)。
    private final class OpenEntry {
        let item: ArchiveExtractionPlan.Item
        let target: URL
        private let handle: FileHandle

        init(item: ArchiveExtractionPlan.Item, target: URL) throws {
            let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            guard descriptor >= 0 else { throw FileOperationError.posixFailure(item: target, errnoCode: errno) }
            self.item = item
            self.target = target
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }

        func write(_ chunk: Data) throws {
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                throw WriteFailure(underlying: error, item: target)
            }
        }

        func finish(tracker: ProgressTracker) throws {
            do {
                try handle.close()
            } catch {
                throw WriteFailure(underlying: error, item: target)
            }
            ArchiveExtractor.setModificationDate(item.modified, of: target)
            tracker.finishEntry()
        }

        func abandon() {
            try? handle.close()
        }
    }

    /// 読んでいる間の失敗を、利用者に伝える形へ。書き込みの失敗は errno へ、それ以外(CRC・壊れたデータ・パスワード)は classify。
    private static func classifyWhileReading(_ error: any Error, archive: URL) -> Error {
        if let failure = error as? WriteFailure { return posixFailure(failure.underlying, item: failure.item) }
        return classify(error, archive: archive)
    }

    /// 書き込みの失敗を、reader の中を通っても見分けられるように包む。
    private struct WriteFailure: Error {
        let underlying: any Error
        let item: URL
    }

    /// `folder` を作る(途中も)。一時フォルダの外は作らない。**既にあるのがフォルダでなければ失敗**(ファイルを辿らない)。
    private static func makeDirectories(_ folder: URL, under root: URL) throws {
        let rootPath = root.path
        let path = folder.path
        guard path.hasPrefix(rootPath) else { throw FileOperationError.posixFailure(item: folder, errnoCode: EPERM) }
        var current = rootPath
        for component in path.dropFirst(rootPath.count).split(separator: "/") {
            current += "/" + component
            if mkdir(current, 0o755) == 0 { continue }
            let code = errno
            var info = stat()
            guard code == EEXIST, lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw FileOperationError.posixFailure(item: URL(fileURLWithPath: current), errnoCode: code)
            }
        }
    }

    /// 一時フォルダから最終の場所へ。
    private static func place(_ temporary: URL, archive: URL, into folder: URL, placement: Placement) throws -> [TransferReceipt] {
        switch placement {
        case .ownFolder:
            // 一時フォルダは 0700 で作った(書いている途中を他人に見せない)。見える名前にする前に普通のフォルダの権限へ。
            chmod(temporary.path, 0o755)
            let name = folderName(for: archive)
            let placed = try moveExclusively(temporary, into: folder, preferredName: name, isDirectory: true)
            return [TransferReceipt(source: archive, destination: placed, replacedItemInTrash: nil, identity: FileIdentity.of(placed))]
        case .contents:
            let children = ((try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [])
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            var receipts: [TransferReceipt] = []
            do {
                for child in children {
                    let source = temporary.appendingPathComponent(child)
                    var info = stat()
                    let isDirectory = lstat(source.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
                    let placed = try moveExclusively(source, into: folder, preferredName: child, isDirectory: isDirectory)
                    receipts.append(TransferReceipt(source: archive, destination: placed, replacedItemInTrash: nil, identity: FileIdentity.of(placed)))
                }
            } catch {
                // 途中まで置いたものは受領書ごと返せないので、置いたものを一時フォルダへ戻してから失敗させる
                // (呼び出し側が一時フォルダごと消す。取り消しの手段の無い半端な展開を残さない)。
                for receipt in receipts {
                    _ = FileOperationService.exclusiveRename(
                        from: receipt.destination, to: temporary.appendingPathComponent(UUID().uuidString)
                    )
                }
                throw error
            }
            rmdir(temporary.path)
            return receipts
        }
    }

    /// `preferredName` で置く。塞がっていれば `name 2`…(確かめてから置くまでの間に塞がっても RENAME_EXCL が断るので、次の名前で試し直す)。
    private static func moveExclusively(_ source: URL, into folder: URL, preferredName: String, isDirectory: Bool) throws -> URL {
        var tried: Set<String> = []
        while true {
            let name = FileNameValidation.nextAvailableName(for: preferredName, isDirectory: isDirectory) { candidate in
                tried.contains(candidate) || FileOperationService.itemExists(at: folder.appendingPathComponent(candidate))
            }
            let target = folder.appendingPathComponent(name, isDirectory: isDirectory)
            let code = FileOperationService.exclusiveRename(from: source, to: target)
            if code == 0 { return target }
            guard code == EEXIST else { throw FileOperationError.posixFailure(item: target, errnoCode: code) }
            tried.insert(name)
        }
    }

    /// 「〈名前〉に展開」のフォルダ名。拡張子を 1 つ外す(`book.cbz` → `book`)。外すと空・ドットだけになるなら元の名前のまま。
    static func folderName(for archive: URL) -> String {
        let name = archive.lastPathComponent
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty || base == name ? name : base
    }

    private static func setModificationDate(_ date: Date?, of url: URL) {
        guard let date else { return }
        var values = URLResourceValues()
        values.contentModificationDate = date
        var target = url
        try? target.setResourceValues(values)
    }

    fileprivate static func posixFailure(_ error: any Error, item: URL) -> Error {
        let nsError = error as NSError
        let underlying = nsError.domain == NSPOSIXErrorDomain ? nsError : nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        if let underlying, underlying.domain == NSPOSIXErrorDomain {
            return FileOperationError.posixFailure(item: item, errnoCode: Int32(underlying.code))
        }
        return error
    }

    /// reader の失敗を、利用者に伝える形へ。
    static func classify(_ error: any Error, archive: URL) -> Error {
        switch error {
        case is ArchiveOperationError, is FileOperationError, is CancellationError:
            return error
        case ArchiveReaderError.multiVolume:
            return ArchiveOperationError.multiVolume(archive: archive)
        case UnrarError.missingPassword:
            return ArchiveOperationError.encrypted(archive: archive)
        default:
            return ArchiveOperationError.unreadable(archive: archive)
        }
    }
}

/// 圧縮・展開の失敗(FileOperationError に無いもの)。
nonisolated enum ArchiveOperationError: Error, Sendable, Equatable {
    case encrypted(archive: URL)
    case multiVolume(archive: URL)
    /// 開けない・壊れている・対応していない方式。
    case unreadable(archive: URL)
    case tooManyEntries(archive: URL, count: Int, limit: Int)
    case tooLarge(archive: URL, limit: UInt64)
    case suspiciousCompressionRatio(archive: URL)
}

extension ArchiveOperationError: LocalizedError {
    nonisolated var errorDescription: String? {
        let locale = AppLanguage.currentLocale
        switch self {
        case let .encrypted(archive):
            return String(format: String(localized: "“%@” is protected with a password. qooViewer can’t extract encrypted archives.", language: locale),
                          archive.lastPathComponent)
        case let .multiVolume(archive):
            return String(format: String(localized: "“%@” is split into several files. qooViewer can’t extract split archives.", language: locale),
                          archive.lastPathComponent)
        case let .unreadable(archive):
            return String(format: String(localized: "“%@” couldn’t be read. It may be damaged, encrypted, or compressed with a method qooViewer doesn’t support.", language: locale),
                          archive.lastPathComponent)
        case let .tooManyEntries(archive, count, limit):
            return String(format: String(localized: "“%1$@” contains %2$lld files, more than qooViewer extracts at once (%3$lld).", language: locale),
                          archive.lastPathComponent, count, limit)
        case let .tooLarge(archive, limit):
            let formatter = ByteCountFormatter()
            return String(format: String(localized: "“%1$@” would expand to more than %2$@, so it wasn’t extracted.", language: locale),
                          archive.lastPathComponent, formatter.string(fromByteCount: Int64(clamping: limit)))
        case let .suspiciousCompressionRatio(archive):
            return String(format: String(localized: "“%@” expands to far more than its size, which is typical of a damaged or malicious archive, so it wasn’t extracted.", language: locale),
                          archive.lastPathComponent)
        }
    }
}

import Foundation

// 事前検査と進捗の部品(改善要望7 段階 2、2026-09-13。qooLibrary の ProgressTracker / PathLimits /
// VolumeCapacity / NameLengthLimit / MoveVerification を 1 ファイルに写したもの)。
// どれも FileIO のスレッドの上で同期に呼ぶ。

/// 一括の移動・コピーの進み具合を数え、100ms に間引いて報告する。
///
/// ■ 総量をいつ数えるか
/// 総バイト数はフォルダを再帰的に歩かないと分からない。**1 バイトも書かないと分かっている操作**
/// (同一ボリューム内の移動 = rename)と、**クローンで済むと分かるコピー**では数えない(数分かけて
/// 数えたあと一瞬で終わるのは本末転倒)。数えないときは件数だけを報告する。
///
/// ■ 間引き
/// 項目の切り替わりと完了は必ず送る。**項目の最初のバイトも間引かない** ―― 速いディスクでは 1 項目が
/// 100ms の窓に収まり、「最中」の報告が一度も出ない(qooLibrary の CI で踏んだ)。
///
/// ■ 参照型 + 鍵
/// copyfile の status callback は FileIO のスレッドの上で同期に呼ばれ、await できない。
nonisolated final class ProgressTracker: @unchecked Sendable {
    private static let updateInterval: Duration = .milliseconds(100)

    private let lock = NSLock()
    private let sink: ProgressSink?
    private var progress: FileOperationProgress
    private var lastReportedAt: ContinuousClock.Instant?
    private var sentFirstBytesOfItem = false

    /// 実際に書くバイト数の見積もり。空き容量の事前検査に使う。数えなかった・数える途中で
    /// 中止されたなら nil(= 検査しない)。
    let requiredBytes: Int64?
    /// 走査で見つけたいちばん深い相対パス(パス長の事前検査用)。
    let deepestRelativePath: (path: String, item: URL)?
    /// いちばん大きいファイル(宛先のファイルサイズ上限の検査用)。
    let largestFile: (size: Int64, item: URL)?
    /// いちばん長い名前(UTF-8 のバイト数。SMB の名前長の検査用)。
    let longestName: (name: String, item: URL)?

    /// - Parameter mayClone: false ならクローンできる宛先でも数える(FileOperationService の `allowsCloning` ―― テスト用)。
    init(sink: ProgressSink?, items: [URL], destination: URL, writesNoBytes: Bool, mayClone: Bool = true) {
        self.sink = sink
        if writesNoBytes || (mayClone && Self.willBeCloned(items: items, destination: destination)) {
            requiredBytes = nil
            deepestRelativePath = nil
            largestFile = nil
            longestName = nil
        } else {
            let measured = Self.walk(items)
            requiredBytes = measured.bytes > 0 ? measured.bytes : nil
            deepestRelativePath = measured.deepest
            largestFile = measured.largest
            longestName = measured.longestName
        }
        progress = FileOperationProgress(totalBytes: requiredBytes ?? 0, totalItems: items.count)
    }

    /// 総量を呼び出し側が知っている操作(圧縮・展開。段階 6)。走査も事前検査の値も持たない。
    init(sink: ProgressSink?, totalBytes: Int64, totalItems: Int) {
        self.sink = sink
        requiredBytes = nil
        deepestRelativePath = nil
        largestFile = nil
        longestName = nil
        progress = FileOperationProgress(totalBytes: totalBytes, totalItems: totalItems)
    }

    func begin() { mutate(force: true, beginsItem: true) { _ in } }

    /// 展開・圧縮の 1 エントリの始まりと終わり。**間引く**(小さなファイルが数万件ある書庫で、1 件ごとに
    /// メインアクターへ報告を投げない)。項目をまたいでも最初のバイトの例外は使わない。
    func startEntry(named name: String) {
        mutate(force: false, countsAsBytes: false) { $0.currentItemName = name }
    }

    func finishEntry() {
        mutate(force: false, countsAsBytes: false) { $0.completedItems += 1 }
    }

    func startItem(_ item: URL) {
        mutate(force: true, beginsItem: true) { $0.currentItemName = item.lastPathComponent }
    }

    /// 別スレッドから呼ばれる(copyfile の callback)。
    func addBytes(_ bytes: Int64) {
        mutate(force: false) { $0.completedBytes += bytes }
    }

    func finishItem() {
        mutate(force: true) { $0.completedItems += 1 }
    }

    /// 更新と報告の判定を 1 つの鍵の下で行い、**報告そのものは鍵の外で**呼ぶ(受け手が何をするか分からない)。
    /// - Parameter countsAsBytes: false なら「最初のバイトは間引かない」の例外を使わず、消費もしない(展開・圧縮のエントリの区切り。
    ///   消費させると、エントリの名前の報告が例外を使い切り、書き始めたバイトの報告が 100ms 待たされる)。
    private func mutate(
        force: Bool, beginsItem: Bool = false, countsAsBytes: Bool = true, _ change: (inout FileOperationProgress) -> Void
    ) {
        lock.lock()
        change(&progress)
        if beginsItem { sentFirstBytesOfItem = false }
        let now = ContinuousClock.now
        let shouldReport: Bool
        if !countsAsBytes {
            shouldReport = lastReportedAt.map { now - $0 >= Self.updateInterval } ?? true
        } else if force || !sentFirstBytesOfItem {
            shouldReport = true
        } else if let last = lastReportedAt, now - last < Self.updateInterval {
            shouldReport = false
        } else {
            shouldReport = true
        }
        if shouldReport {
            lastReportedAt = now
            if !force, countsAsBytes { sentFirstBytesOfItem = true }
        }
        let snapshot = progress
        lock.unlock()
        guard shouldReport, let sink else { return }
        sink.report(snapshot)
    }

    /// クローンで済む(バイトを運ばない)と分かるか。同じボリュームでも exFAT のようにクローンできない
    /// 形式があるので `volumeSupportsFileCloning` まで見る。
    private static func willBeCloned(items: [URL], destination: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeSupportsFileCloningKey]
        guard let values = try? destination.resourceValues(forKeys: keys),
              values.volumeSupportsFileCloning == true,
              let volume = values.volumeUUIDString
        else { return false }
        return items.allSatisfy { (try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString == volume }
    }

    /// 対象を 1 度だけ歩いて、合計バイト数・いちばん深い相対パス・いちばん大きいファイル・いちばん長い名前を拾う。
    /// 中止されたら 0 を返す(待たせ続けるより不定の進捗のほうがよい)。
    private static func walk(_ items: [URL]) -> (
        bytes: Int64, deepest: (path: String, item: URL)?, largest: (size: Int64, item: URL)?, longestName: (name: String, item: URL)?
    ) {
        var total: Int64 = 0
        var deepest: (path: String, item: URL)?
        var largest: (size: Int64, item: URL)?
        var longestName: (name: String, item: URL)?
        func note(relativePath: String, item: URL) {
            if relativePath.utf8.count > (deepest?.path.utf8.count ?? -1) { deepest = (relativePath, item) }
            let name = item.lastPathComponent
            if name.utf8.count > (longestName?.name.utf8.count ?? -1) { longestName = (name, item) }
        }
        func note(size: Int64, item: URL) {
            total += size
            if size > (largest?.size ?? -1) { largest = (size, item) }
        }
        for item in items {
            if Cancellation.isRequestedInCurrentScope { return (0, nil, nil, nil) }
            let name = item.lastPathComponent
            note(relativePath: name, item: item)
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue } // リンクはリンクとして運ぶだけ
            guard values?.isDirectory == true else {
                note(size: Int64(values?.fileSize ?? 0), item: item)
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: item, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []
            ) else { continue }
            let rootPath = item.standardizedFileURL.path
            while let child = enumerator.nextObject() as? URL {
                if Cancellation.isRequestedInCurrentScope { return (0, nil, nil, nil) }
                // NSDirectoryEnumerator は相対パスを公開しないので、起点のパスを前から削る。
                let childPath = child.standardizedFileURL.path
                if childPath.hasPrefix(rootPath + "/") {
                    note(relativePath: name + "/" + childPath.dropFirst(rootPath.count + 1), item: child)
                }
                let childValues = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard childValues?.isRegularFile == true else { continue }
                note(size: Int64(childValues?.fileSize ?? 0), item: child)
            }
        }
        return (total, deepest, largest, longestName)
    }
}

/// 事前検査の判定。**判断できないときは検査しない**(誤って断ると正当な操作ができなくなるのに対し、
/// 通しても失敗は errno として理由付きで捕まる ―― 害の非対称。qooLibrary と同じ判断)。
nonisolated enum FileOperationPreflight {
    /// パス全体の上限バイト数(終端の NUL を除く)。全形式で 1024(PATH_MAX)。exFAT/FAT は pathconf が
    /// -1 を返すので PATH_MAX へ落とす(実測で同値、qooLibrary)。
    static func maxPathBytes(at url: URL) -> Int {
        let reported = url.withUnsafeFileSystemRepresentation { pointer -> Int in
            guard let pointer else { return -1 }
            let value = pathconf(pointer, _PC_PATH_MAX)
            return value > 0 ? Int(value) : -1
        }
        return (reported > 0 ? reported : Int(PATH_MAX)) - 1
    }

    static func resultingPathBytes(destination: URL, relativePath: String) -> Int {
        destination.path.utf8.count + 1 + relativePath.utf8.count
    }

    /// 宛先の空き容量。`volumeAvailableCapacityForImportantUsage` を先に見る(Finder の表示に近い)が、
    /// **小さなボリュームでは 0 を返す**(200MB の空のイメージで 0。qooLibrary 実測)ので、0 なら素の値へ落とす。
    static func availableCapacity(at url: URL) -> Int64? {
        let values = try? existingAncestor(of: url).resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// 空き容量の検査に足す余裕。固定 64MB だと空きが 64MB を下回るボリュームでどんな小さなコピーも
    /// 断ってしまう(qooLibrary で発覚)ので、ボリューム全体の 5% を上限にする。
    static func freeSpaceMargin(at url: URL) -> Int64 {
        let requested: Int64 = 64 * 1024 * 1024
        guard let total = (try? existingAncestor(of: url).resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity,
              total > 0
        else { return requested }
        return min(requested, Int64(total) / 20)
    }

    /// 1 ファイルの上限(FAT32 は 4GB 弱)。答えない形式では nil。
    static func maximumFileSize(at url: URL) -> Int64? {
        guard let limit = (try? url.resourceValues(forKeys: [.volumeMaximumFileSizeKey]))?.volumeMaximumFileSize, limit > 0
        else { return nil }
        return Int64(limit)
    }

    /// 名前の上限を**バイトで**数える宛先か。実測したのは `smbfs`(UTF-8 255 バイト)だけなので、それだけ持つ。
    /// APFS/HFS+/exFAT は FileNameValidation の入口の規則と同じかそれより緩い。
    static func nameByteLimit(at url: URL, mounts: MountTable) -> Int? {
        mounts.entry(containing: url)?.fileSystemType == "smbfs" ? 255 : nil
    }

    /// 書き込み先に実際に書けるか。`volumeIsReadOnly` を見たうえで `access(W_OK)`。SMB ではモードビットも
    /// volumeIsReadOnly も嘘をつき、access(2) だけが正しかった(qooLibrary 実測)。
    static func checkWritable(_ folder: URL) throws {
        if (try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            throw FileOperationError.destinationIsReadOnly(folder)
        }
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        guard access(folder.path, W_OK) != 0 else { return }
        throw FileOperationError.destinationNotWritable(folder, errnoCode: errno)
    }

    /// 宛先が、運ぶフォルダ自身かその配下でないこと。
    static func checkNotInsideSource(_ item: URL, destination: URL) throws {
        guard (try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true
        else { return }
        let source = item.standardizedFileURL.resolvingSymlinksInPath().path
        let target = destination.standardizedFileURL.resolvingSymlinksInPath().path
        if target == source || target.hasPrefix(source + "/") {
            throw FileOperationError.destinationInsideSource(source: item, destination: destination)
        }
    }

    /// 実在する祖先(これから作る場所の問い合わせ用)。ルートで止める(`/..` で無限ループしない)。
    private static func existingAncestor(of url: URL) -> URL {
        var target = url
        while !FileManager.default.fileExists(atPath: target.path), target.pathComponents.count > 1 {
            target = target.deletingLastPathComponent()
        }
        return target
    }
}

/// **元を消す前に、運んだ結果が元と一致するかを確かめる**(別ボリュームへの移動 = コピーして元を消す)。
///
/// 更新日時と大きさだけで「運ぶ間に元が変わったか」を決めない理由(qooLibrary 実測):
/// - **SMB は書き込み直後の更新日時を数百 ms 後に差し替える**(fsync しても)ので、作ったばかりの
///   ファイルを続けて移動すると日時だけが変わり、誤って断る。
/// - FAT は日時が 2 秒精度で、同じ大きさの書き換えを見分けられない。
/// だから「大きさか実体が変わった」は変わった、それ以外は**中身の抜き取り(先頭・中央・末尾の 64KB)**で決める。
///
/// **ローカルのボリュームでは更新日時(ns)の違いも「変わった」に数える**(2026-09-14 の 2 回目の監査 7)。抜き取りだけだと、
/// 領域を先に確保してから書き続けるもの(ダウンロード・ディスクイメージ・仮想マシンのディスク)の窓の外の書き込みを見逃し、
/// 移動では元を消して書き込みを失った。日時を差し替えるのは SMB のサーバの都合なので、ネットワークの元だけ抜き取りに任せる。
nonisolated enum MoveVerification {
    struct Stamp: Equatable {
        let inode: UInt64
        let device: Int32
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    static func stamp(of url: URL) -> Stamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Stamp(
            inode: UInt64(info.st_ino), device: info.st_dev, size: Int64(info.st_size),
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec
        )
    }

    /// 運ぶ前の姿 `before` と比べて、元が書き換えられたとみなすか。
    /// - Parameter trustsModificationDate: 元がローカルのボリュームにある(型コメント)。
    static func sourceWasModified(before: Stamp?, source: URL, destination: URL, trustsModificationDate: Bool) -> Bool {
        // 元が既に無い、または前の姿を取れていないなら比べようがない。断らない側に倒す。
        guard let before, let after = stamp(of: source) else { return false }
        if before.size != after.size || before.inode != after.inode || before.device != after.device { return true }
        if trustsModificationDate,
           before.modifiedSeconds != after.modifiedSeconds || before.modifiedNanoseconds != after.modifiedNanoseconds {
            return true
        }
        return !looksIdentical(source: source, destination: destination)
    }

    private static let windowSize = 64 * 1024

    /// 読めない等で判定できなければ true(一致とみなす)。
    static func looksIdentical(source: URL, destination: URL) -> Bool {
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true { return true }
        if values?.isDirectory == true {
            // フォルダは中身を読み直さず、構成(件数と合計バイト数)を突き合わせる。孫以下が同じ大きさのまま
            // 書き換わった場合は見分けられない(既知の限界)。
            return treeSummary(of: source) == treeSummary(of: destination)
        }
        guard let sourceSize = fileSize(source), let destinationSize = fileSize(destination) else { return true }
        guard sourceSize == destinationSize else { return false }
        guard sourceSize > 0,
              let a = try? FileHandle(forReadingFrom: source),
              let b = try? FileHandle(forReadingFrom: destination)
        else { return true }
        defer {
            try? a.close()
            try? b.close()
        }
        let window = Int64(windowSize)
        let offsets = sourceSize <= window
            ? [UInt64(0)]
            : Array(Set([0, UInt64(sourceSize / 2 - window / 2), UInt64(sourceSize - window)])).sorted()
        for offset in offsets {
            guard (try? a.seek(toOffset: offset)) != nil, (try? b.seek(toOffset: offset)) != nil,
                  let left = try? a.read(upToCount: windowSize), let right = try? b.read(upToCount: windowSize)
            else { return true }
            if left != right { return false }
        }
        return true
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }

    private struct TreeSummary: Equatable {
        var count = 0
        var bytes: Int64 = 0
    }

    private static func treeSummary(of url: URL) -> TreeSummary? {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []
        ) else { return nil }
        var summary = TreeSummary()
        while let child = enumerator.nextObject() as? URL {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            summary.count += 1
            summary.bytes += Int64(values?.fileSize ?? 0)
        }
        return summary
    }
}

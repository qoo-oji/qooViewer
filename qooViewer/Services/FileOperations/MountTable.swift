import Foundation

/// **いまマウントされているボリュームの一覧を、ファイルシステムに触れずに答える**
/// (改善要望7 段階 2、2026-09-13。qooLibrary の `MountTable` を写したもの)。
///
/// 「この場所はネットワークか」「同じボリュームか」を素直に書くと `resourceValues` や `statfs(path)`
/// になり、どちらも**その場所のファイルシステムへ問い合わせる**。相手が応答しなければ戻ってこない
/// (SMB 30 秒、NFS hard は無限)。`getmntinfo_r_np(MNT_NOWAIT)` はカーネルが控えているマウント表を
/// 写すだけで、どこにも問い合わせない。**`MNT_WAIT` を渡してはならない**(各ファイルシステムに
/// statfs を要求する)。
///
/// `getmntinfo` ではなく `_r_np` 版: 前者はプロセス共有の静的バッファを返すので、別スレッドが
/// 同時に呼ぶと互いの結果を壊す。
///
/// ボリュームの実体確認(`BookLocationResolver`)が 2026-09-13 に `getmntinfo(MNT_NOWAIT)` を直に
/// 読むよう直した処理も、ここへ寄せた(同じ読み取りを 2 箇所に持たない)。
///
/// 費用は 1 回 0.13ms(マウント 97 件、qooLibrary 実測)。同じ判定を何十回も繰り返すときは
/// `current()` を 1 回だけ呼んで値を使い回す(値型にしてある)。
nonisolated struct MountTable: Sendable {
    struct Entry: Sendable, Equatable {
        /// マウント先(`f_mntonname`)。例: `/`、`/Volumes/Backup`。
        let mountPoint: String
        /// マウント元(`f_mntfromname`)。例: `/dev/disk3s1`、`//user@server/share`。
        let mountedFrom: String
        /// ファイルシステム種別(`f_fstypename`)。例: `apfs`、`smbfs`、`exfat`。
        let fileSystemType: String
        /// `MNT_LOCAL` が立っているか。ネットワーク越しなら false。
        /// (qooLibrary が 9 種のボリュームで `volumeIsLocalKey` と一致することを実測済み)
        let isLocal: Bool
        /// `MNT_DONTBROWSE`(Finder に出さないマウント。Time Machine のスナップショット等)。
        let isHiddenFromBrowsing: Bool
    }

    let entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries
    }

    /// いまのマウント表を写し取る。**ファイルシステムには触れない**(メインアクターから呼んでよい)。
    static func current() -> MountTable {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return MountTable(entries: []) }
        defer { free(buffer) }
        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            var raw = buffer[index]
            entries.append(Entry(
                mountPoint: string(from: &raw.f_mntonname),
                mountedFrom: string(from: &raw.f_mntfromname),
                fileSystemType: string(from: &raw.f_fstypename),
                isLocal: raw.f_flags & UInt32(MNT_LOCAL) != 0,
                isHiddenFromBrowsing: raw.f_flags & UInt32(MNT_DONTBROWSE) != 0
            ))
        }
        return MountTable(entries: entries)
    }

    // MARK: - 問い合わせ

    /// `path` を含むマウントのうち**いちばん深いもの**。マウントは入れ子になる(`/` の中に
    /// `/Volumes/…`)ので、最長一致でなければ何もかもが起動ボリューム扱いになる。
    ///
    /// - Note: 外れたボリューム上のパスは `/` まで後退する(`/` は常にある)。「そのボリュームが
    ///   まだあるか」はこれで判定せず、`isOnAnUnmountedVolume` を使う。
    func entry(containing path: String) -> Entry? {
        let target = Self.normalized(path)
        var best: Entry?
        for entry in entries where Self.path(target, isAtOrUnder: entry.mountPoint) {
            if best == nil || entry.mountPoint.count > best!.mountPoint.count {
                best = entry
            }
        }
        return best
    }

    func entry(containing url: URL) -> Entry? {
        entry(containing: url.standardizedFileURL.path)
    }

    /// ネットワーク越しか。**判定できなければ false**(ローカル扱い)。
    func isRemote(_ url: URL) -> Bool {
        guard let entry = entry(containing: url) else { return false }
        return !entry.isLocal
    }

    /// ローカルか。判定できなければ false(`isRemote` と向きが逆になるのは、呼び出し側が
    /// 「ローカルなら安い処理をしてよい」の判断に使うため ―― 迷ったら安い処理をしない)。
    func isLocal(_ url: URL) -> Bool {
        entry(containing: url)?.isLocal ?? false
    }

    /// 2 つの場所が同じマウントの上にあるか(同一ボリューム内の移動はバイトを運ばない、の判定)。
    func areOnSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let left = entry(containing: a), let right = entry(containing: b) else { return false }
        return left.mountPoint == right.mountPoint
    }

    /// そのマウント先がいま存在するか。
    func isMounted(_ mountPoint: String) -> Bool {
        let target = Self.normalized(mountPoint)
        return entries.contains { $0.mountPoint == target }
    }

    /// `url` がいま繋がっていないボリューム上を指しているか。
    ///
    /// **`entry(containing:)` で判定してはいけない**: 外れたボリューム配下のパスは最長一致が
    /// `/` まで後退し、「繋がっている」と答えてしまう。`/Volumes/<名前>` を取り出して表に居るかを見る。
    /// パスの実体は見ない(ブロックしうるうえ、外れても空のフォルダが残ることがある)。
    func isOnAnUnmountedVolume(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if let entry = entry(containing: path), entry.mountPoint != "/" { return false }
        guard let volumeRoot = Self.volumeRoot(of: path) else { return false }
        return !isMounted(volumeRoot)
    }

    /// ボリュームを同定する文字列。ローカルは `volumeUUIDString`(マウント順で変わらない ――
    /// FileNodeIdentifier の型コメント)、UUID を持たないボリューム(SMB など)はマウント元のハッシュ。
    ///
    /// - Note: UUID の読み取りは**そのボリュームへの問い合わせ**なので、ローカルのときだけ行う。
    ///   `FileIO` の上から呼ぶこと。
    func volumeIdentifier(_ url: URL) -> String? {
        guard let entry = entry(containing: url) else { return nil }
        if entry.isLocal,
           let uuid = (try? URL(fileURLWithPath: entry.mountPoint, isDirectory: true)
               .resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString {
            return uuid
        }
        return "mount:" + String(entry.mountedFrom.hashValueStable, radix: 16)
    }

    /// パスが載っているボリュームの入口 `/Volumes/<名前>`。起動ボリューム上なら nil。純粋な文字列処理。
    static func volumeRoot(of path: String) -> String? {
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix) else { return nil }
        let name = path.dropFirst(prefix.count).prefix { $0 != "/" }
        guard !name.isEmpty else { return nil }
        return prefix + name
    }

    // MARK: - パスの扱い

    /// 末尾のスラッシュだけを落とす。`standardizingPath` / `resolvingSymlinksInPath()` は
    /// 先頭の `/private` を外す特別扱いを持つので使わない(docs/13 の standardizedFileURL の件と同じ罠)。
    static func normalized(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    /// `path` が `ancestor` そのものかその配下か。素の hasPrefix だと `/Volumes/A` が
    /// `/Volumes/AB` に一致するので、区切りまで含めて見る。
    static func path(_ path: String, isAtOrUnder ancestor: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") }
        return path == ancestor || path.hasPrefix(ancestor + "/")
    }

    private static func string<T>(from field: inout T) -> String {
        withUnsafeBytes(of: &field) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}

private extension String {
    /// 起動をまたいで同じ値になるハッシュ(FNV-1a)。`hashValue` は起動ごとに種が変わるので鍵にできない。
    nonisolated var hashValueStable: UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

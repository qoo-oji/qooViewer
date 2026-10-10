import Foundation

/// ファイルブラウザのツリーが FSEvents で見張るフォルダと、知らせのパスを行のパスへ読み替える表(2026-10-10)。
/// 行を読み直すのは FileBrowserTreeView、ここは「どこを見張り、知らせがどの行に当たるか」を決めるだけ。
///
/// ■ なぜ読み替えが要るか
/// FSEvents は**記号リンクを解いた実際のパス**で知らせる(`/var/…` は `/private/var/…`、よく使う項目に登録したリンク越しのパスは
/// リンク先のパス)。ツリーの行は根の行(ボリューム・ホーム・よく使う項目)のパスの下に子の名前を足したパスを持つので、根のパスが
/// リンクを含むと、その下の行には知らせが一度も当たらなかった(外での変更が反映されず、変更日順の並びも古いまま。2026-10-10 の
/// 「残っている穴」)。右ペインは表示中のフォルダを両方の書き方で持って照合している(`FileBrowserState.watchedFolderSpellings`)ので、
/// ツリーも根ごとに同じ書き方を持ち、知らせのパスを行のパスへ読み替える。リンクが入りうるのは根のパスだけ(子の行はリンクを出さない
/// ―― `isNavigableFolder` は記号リンクを含まない)なので、根ごとの読み替えで配下の行すべてに当たる。
///
/// ■ 見張るフォルダの重なりは、解いたパスで判定する
/// 以前は行のパスの文字列の包含で重なりを除いていたので、あるボリュームの根の行と、その中の、リンクで別のボリュームを指すパスの行を
/// 開いていると、後者が「前者の配下」として外れ、リンク先の変更が届かなかった。
///
/// ■ リンクの先がネットワーク上なら、触らずに見張りから外す(2026-10-10 の監査の 1)
/// 根の行のパスはローカルでも、リンクの先が共有の上のことがある(よく使う項目の `~/NAS` が共有の上のフォルダを指すなど)。
/// `resolvingSymlinksInPath` で解くとリンクの先の共有に問い合わせ、応答しない共有では 1 回 30 秒(NFS の hard マウントなら無限)
/// 塞がる。しかも解き直しは行の子を読むたびに走っていたので、塞がった FileIO のスレッドが積もり、最後はアプリの FileIO 全体
/// (一覧・本を開く)が止まりえた。そこで、リンクは自分で 1 階層ずつ解き、**次に触るパスがネットワーク上のボリュームに入るなら
/// その手前でやめる**(`resolvedWithoutTouchingRemoteVolumes`。マウント表は文字列で引くのでファイルシステムに触れない)。
/// そういう根の下の行は見張らない(FSEvents はネットワーク上では飛ばず、ストリームの生成も塞がる ―― 右ペインと同じ決まり)。
/// 根の書き方は `FileBrowserTreeView` が根ごとに覚え、根を開き直したとき・マウント表が変わったときだけ調べ直す。
nonisolated struct FileBrowserTreeWatchPlan: Equatable {
    /// 根の行のパスの書き方(FSEvents が使いうるもの)。**ブロッキングする(ローカルのリンクを読む)ので FileIO の上で作る。**
    /// ネットワーク上のボリュームには触れない(型コメント)。
    struct RootSpellings: Equatable {
        /// 行のパス(`FileBrowserState.id(for:)` の形)。
        let rowPath: String
        /// リンクを解いたパス(見張るフォルダの重なりの判定に使う)。
        let resolvedPath: String
        /// 行のパス以外の書き方(リンクを解いたもの・`/private` を付けた・外したもの)。
        let otherSpellings: Set<String>
        /// FSEvents で見張れるか。リンクの先がネットワーク上のボリュームに入る・リンクが循環している根は false(配下の行を見張らない)。
        var isWatchable = true

        static func make(rowPath: String, mountTable: MountTable = .current()) -> RootSpellings {
            guard let resolved = FileBrowserTreeWatchPlan.resolvedWithoutTouchingRemoteVolumes(rowPath, mountTable: mountTable),
                  !mountTable.isRemote(path: resolved)
            else {
                return RootSpellings(rowPath: rowPath, resolvedPath: rowPath, otherSpellings: [], isWatchable: false)
            }
            // FSEvents が知らせうる書き方(`FileBrowserState.watchedFolderSpellings` と同じ考え方): 行のパス・解いたパス・
            // 頭の `/private` を付けた形と外した形(`/var` `/tmp` `/etc` は `/private` の下へのリンク)。
            var all: Set<String> = [rowPath, resolved]
            for candidate in [rowPath, resolved] {
                if privateLinkedTops.contains(where: { MountTable.path(candidate, isAtOrUnder: $0) }) {
                    all.insert("/private" + candidate)
                }
                let withoutPrivate = String(candidate.dropFirst("/private".count))
                if candidate.hasPrefix("/private/"),
                   privateLinkedTops.contains(where: { MountTable.path(withoutPrivate, isAtOrUnder: $0) }) {
                    all.insert(withoutPrivate)
                }
            }
            return RootSpellings(rowPath: rowPath, resolvedPath: resolved, otherSpellings: all.subtracting([rowPath]))
        }

        private static let privateLinkedTops = ["/var", "/tmp", "/etc"]
    }

    /// `path` の記号リンクを 1 階層ずつ解いた実際のパス(`realpath` と同じ形 ―― `/var/…` は `/private/var/…`)。
    /// **ネットワーク上のボリュームには触れない**: 次に `lstat` するパスがマウント表でネットワーク上のボリュームに入るなら、
    /// その手前でやめて nil を返す(型コメント)。リンクが循環している(解き直しが 40 回を超えた)ときも nil。無い階層から先は
    /// 書かれたまま残す(無いものの中にリンクは無い)。**ローカルのファイルシステムには触る(lstat・readlink)ので FileIO の上で。**
    static func resolvedWithoutTouchingRemoteVolumes(_ path: String, mountTable: MountTable) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var resolved = "/"
        var pending = path.split(separator: "/").map(String.init)
        var linkHops = 0
        func joined(_ base: String, _ name: String) -> String { base == "/" ? "/" + name : base + "/" + name }
        while !pending.isEmpty {
            let name = pending.removeFirst()
            if name.isEmpty || name == "." { continue }
            if name == ".." {
                resolved = (resolved as NSString).deletingLastPathComponent
                continue
            }
            let candidate = joined(resolved, name)
            if mountTable.isRemote(path: candidate) { return nil }
            var status = stat()
            guard lstat(candidate, &status) == 0 else {
                // 無い・読めない階層。そこから先は書かれたまま。
                return pending.reduce(candidate) { joined($0, $1) }
            }
            guard status.st_mode & S_IFMT == S_IFLNK else {
                resolved = candidate
                continue
            }
            linkHops += 1
            if linkHops > 40 { return nil }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlink(candidate, &buffer, Int(PATH_MAX))
            guard length > 0 else { return nil }
            let target = String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if target.hasPrefix("/") { resolved = "/" }
            pending = target.split(separator: "/").map(String.init) + pending
        }
        return resolved
    }

    struct Alias: Equatable {
        /// FSEvents が知らせるパスの頭。
        let eventPrefix: String
        /// 読み替えた先の行のパスの頭。
        let rowPrefix: String
    }

    /// 見張るフォルダ(リンクを解いたパスで重なりを除いたもの)。
    let watchedPaths: Set<String>
    let aliases: [Alias]

    /// - Parameters:
    ///   - rows: 開いている(子を読む)ローカルの行のパス。
    ///   - roots: 開いている根の行の書き方。
    ///   - pendingRoots: 書き方をまだ調べている根の行のパス。その配下の行は、調べ終えるまで見張らない(調べ終えたら作り直す)。
    ///   - mountTable: 解いたパスがネットワーク上なら見張らない(根の書き方を調べた後にマウントされた場合の保険)。
    static func make(
        rows: [String], roots: [RootSpellings], pendingRoots: Set<String> = [], mountTable: MountTable? = nil
    ) -> FileBrowserTreeWatchPlan {
        // 行ごとの解いたパス: いちばん深い根の解いたパス + 根より下の部分(子の行はリンクを出さないので、根の部分だけ解けばよい)。
        // いちばん深い根が見張れない・まだ調べている根なら、その行は見張らない(nil)。
        let rootPaths = roots.map(\.rowPath) + pendingRoots.subtracting(roots.map(\.rowPath))
        let deepestFirst = rootPaths.sorted { $0.count > $1.count }
        let spellingsByRow = Dictionary(roots.map { ($0.rowPath, $0) }, uniquingKeysWith: { first, _ in first })
        func resolved(_ row: String) -> String? {
            guard let rootPath = deepestFirst.first(where: { MountTable.path(row, isAtOrUnder: $0) }) else { return row }
            guard let root = spellingsByRow[rootPath], root.isWatchable else { return nil }
            let path = replacingPrefix(root.rowPath, with: root.resolvedPath, in: row)
            if let mountTable, mountTable.isRemote(path: path) { return nil }
            return path
        }
        var watched: [String] = []
        for path in Set(rows.compactMap(resolved)).sorted() where !watched.contains(where: { MountTable.path(path, isAtOrUnder: $0) }) {
            watched.append(path)
        }
        let aliases = roots.filter(\.isWatchable).flatMap { root in
            root.otherSpellings.map { Alias(eventPrefix: $0, rowPrefix: root.rowPath) }
        }
        return FileBrowserTreeWatchPlan(
            watchedPaths: Set(watched),
            // 長い頭から当てる(結果は全部使うが、並びを決めておくと比べやすい)。
            aliases: aliases.sorted { ($0.eventPrefix.count, $0.eventPrefix, $0.rowPrefix) > ($1.eventPrefix.count, $1.eventPrefix, $1.rowPrefix) }
        )
    }

    static let empty = FileBrowserTreeWatchPlan(watchedPaths: [], aliases: [])

    /// 知らせのパス(`normalized` 済み)に当たる行のパス。そのものと、読み替えた書き方のすべて(同じ実体を別の根の下にも
    /// 出していれば、そのどちらの行にも当てる)。
    func rowPaths(forEventPath path: String) -> [String] {
        var result = [path]
        for alias in aliases where MountTable.path(path, isAtOrUnder: alias.eventPrefix) {
            let translated = Self.replacingPrefix(alias.eventPrefix, with: alias.rowPrefix, in: path)
            if !result.contains(translated) { result.append(translated) }
        }
        return result
    }

    private static func replacingPrefix(_ prefix: String, with replacement: String, in path: String) -> String {
        if path == prefix { return replacement }
        let rest = prefix == "/" ? String(path.dropFirst()) : String(path.dropFirst(prefix.count + 1))
        return replacement == "/" ? "/" + rest : replacement + "/" + rest
    }
}

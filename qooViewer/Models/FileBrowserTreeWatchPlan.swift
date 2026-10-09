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
nonisolated struct FileBrowserTreeWatchPlan: Equatable {
    /// 根の行のパスの書き方(FSEvents が使いうるもの)。**ブロッキングする(リンクを解く)ので FileIO の上で作る。**
    /// ネットワーク上の根には作らない(そもそも見張らない)。
    struct RootSpellings: Equatable {
        /// 行のパス(`FileBrowserState.id(for:)` の形)。
        let rowPath: String
        /// リンクを解いたパス(見張るフォルダの重なりの判定に使う)。
        let resolvedPath: String
        /// 行のパス以外の書き方(リンクを解いたもの・`/private` を付けたもの)。
        let otherSpellings: Set<String>

        static func make(rowPath: String) -> RootSpellings {
            let url = URL(filePath: rowPath, directoryHint: .isDirectory)
            let all = FileBrowserState.watchedFolderSpellings(of: url)
            return RootSpellings(
                rowPath: rowPath,
                resolvedPath: MountTable.normalized(url.resolvingSymlinksInPath().path),
                otherSpellings: all.subtracting([rowPath])
            )
        }
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
    static func make(rows: [String], roots: [RootSpellings]) -> FileBrowserTreeWatchPlan {
        // 行ごとの解いたパス: いちばん深い根の解いたパス + 根より下の部分(子の行はリンクを出さないので、根の部分だけ解けばよい)。
        let sortedRoots = roots.sorted { $0.rowPath.count > $1.rowPath.count }
        func resolved(_ row: String) -> String {
            guard let root = sortedRoots.first(where: { MountTable.path(row, isAtOrUnder: $0.rowPath) }) else { return row }
            return replacingPrefix(root.rowPath, with: root.resolvedPath, in: row)
        }
        var watched: [String] = []
        for path in Set(rows.map(resolved)).sorted() where !watched.contains(where: { MountTable.path(path, isAtOrUnder: $0) }) {
            watched.append(path)
        }
        let aliases = roots.flatMap { root in
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

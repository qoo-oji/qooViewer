import Foundation

/// 対象フォルダがいま使えるか(docs/plans/auto-rename-study.md §6)。**保存しない**(実行役が毎回見る)。
nonisolated enum AutoRenameTargetAvailability: Equatable, Sendable {
    case available
    /// よく使う項目から外された(§6.2 の決定: 状態は変えず止め、よく使う項目に戻されたら再開)。
    case outsideFavorites
    /// ボリュームが繋がっていない、または同じ場所に**別の**ボリュームが繋がっている(UUID が違う)。削除扱いにしない。
    case volumeNotConnected
    /// ネットワーク上(§6.1。対象にできない。後から同じパスに共有がマウントされた場合)。
    case networkVolume
    /// 読み書きの許可が無い(`FolderAccessStore` が覆っていない・`EPERM` / `EACCES`)。
    case noAccess
    /// ボリュームは繋がっているのにフォルダが無い(`ENOENT` / フォルダでない)。**これだけが自動で OFF にする理由**。
    case missing
}

nonisolated enum AutoRenameTargetProbe {
    struct Input: Sendable {
        var path: String
        var volumeUUID: String?
        var isUnderFavorite: Bool
        var hasAccess: Bool
    }

    /// **ブロッキングする**(lstat・ボリュームの UUID の問い合わせ)ので `FileIO` の上で呼ぶ。
    ///
    /// 見る順番に意味がある: 消えていないのに消えたと判定しないよう、ボリュームの接続(UUID の一致まで)を確かめてから、はじめて
    /// フォルダの有無を見る(§6.2)。
    static func availability(_ input: Input, mounts: MountTable) -> AutoRenameTargetAvailability {
        guard input.isUnderFavorite else { return .outsideFavorites }
        let url = URL(fileURLWithPath: input.path, isDirectory: true)
        if mounts.isOnAnUnmountedVolume(url) { return .volumeNotConnected }
        if mounts.isRemote(url) { return .networkVolume }
        if let expected = input.volumeUUID, let current = mounts.volumeIdentifier(url), current != expected {
            return .volumeNotConnected
        }
        guard input.hasAccess else { return .noAccess }
        var info = stat()
        guard lstat(input.path, &info) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .missing
            default: return .noAccess
            }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .missing }
        guard access(input.path, R_OK | W_OK | X_OK) == 0 else { return .noAccess }
        return .available
    }
}

/// 走査 1 回ぶんの「どの規則をどのフォルダに掛けるか」。メインアクターで組み、値のまま `FileIO` へ渡す。
nonisolated struct AutoRenamePlan: Sendable, Equatable {
    struct Rule: Sendable, Equatable {
        let id: UUID
        let name: String
        let text: AutoRename.RuleText
    }

    struct Target: Sendable, Equatable {
        let id: UUID
        /// `rules` の添字(規則の一覧の並び)。
        let ruleIndex: Int
        let path: String
        let includesSubfolders: Bool
    }

    /// 規則の一覧の並びどおり。
    let rules: [Rule]
    let targets: [Target]
    /// 実行ログから元の名前に戻した項目(AutoRenameStore.excludedPaths)。名前を変えない。
    var excludedPaths: Set<String> = []

    init(rules: [Rule], targets: [Target], excludedPaths: Set<String> = []) {
        self.rules = rules
        self.targets = targets
        self.excludedPaths = excludedPaths
    }

    var isEmpty: Bool { targets.isEmpty }

    /// `folder` の直下の項目に掛ける規則(一覧の並び)。
    func ruleIndices(forFolder folder: String) -> [Int] {
        let folder = MountTable.normalized(folder)
        let indices = Set(targets.filter {
            folder == $0.path || ($0.includesSubfolders && MountTable.path(folder, isAtOrUnder: $0.path))
        }.map(\.ruleIndex))
        return indices.sorted()
    }

    /// `folder` の中へ降りるか(その下に掛ける規則が 1 つでもありうる)。
    func shouldDescend(into folder: String) -> Bool {
        let folder = MountTable.normalized(folder)
        return targets.contains {
            ($0.includesSubfolders && MountTable.path(folder, isAtOrUnder: $0.path))
                || ($0.path != folder && MountTable.path($0.path, isAtOrUnder: folder))
        }
    }

    /// `folder` がどれかの対象に関わるか(対象の中、または対象を中に持つ)。FSEvents のパスの振り分けに使う。
    func isRelevant(folder: String) -> Bool {
        !ruleIndices(forFolder: folder).isEmpty || shouldDescend(into: folder)
    }

    /// 走査の出発点。ほかの対象の配下にある対象は、祖先から降りれば必ず届くので外す(`shouldDescend` が対象の祖先を通す)。
    var roots: [String] {
        let paths = Set(targets.map(\.path)).sorted { $0.count < $1.count }
        var kept: [String] = []
        for path in paths where !kept.contains(where: { MountTable.path(path, isAtOrUnder: $0) }) {
            kept.append(path)
        }
        return kept
    }
}

/// フォルダを読んで、名前を変える候補を決める(**ブロッキングする**。`FileIO` の上で呼ぶ)。ファイルの名前はまだ変えない。
nonisolated enum AutoRenameScanner {
    struct Candidate: Sendable, Equatable {
        let folder: String
        let name: String
        let isDirectory: Bool
        let newName: String
        let ruleNames: [String]
        /// 書き終わりの判定のための様子(`takesSnapshots` のときだけ)。読めなければ nil。
        let snapshot: AutoRename.ItemSnapshot?

        var path: String { folder + "/" + name }
    }

    struct Skip: Sendable, Equatable {
        let folder: String
        let name: String
        let reason: AutoRename.SkipReason
        let ruleNames: [String]

        var path: String { folder + "/" + name }
    }

    struct Result: Sendable, Equatable {
        /// 深いフォルダが先(中身の名前を変えてから、フォルダの名前を変える)。
        var candidates: [Candidate] = []
        var skips: [Skip] = []
        /// ビューアで開いている本(またはそれを含むフォルダ)なので見送ったものがあったフォルダ。閉じた後に見直す。
        var foldersWithItemsInUse: Set<String> = []
    }

    /// - Parameters:
    ///   - recursive: 配下へ降りるか(`plan.shouldDescend` が通すフォルダだけ)。false なら `folder` の直下だけ。
    ///   - inUsePaths: ビューアで開いている本のパス。それ自身か、それを中に持つ項目の名前は変えない。
    static func examine(
        folder: String, recursive: Bool, plan: AutoRenamePlan, inUsePaths: [String] = [], takesSnapshots: Bool,
        isRegistered: @escaping (String) -> Bool = BulkRename.isRegisteredExtension
    ) -> Result {
        var result = Result()
        var visited = 0
        visit(
            MountTable.normalized(folder), recursive: recursive, plan: plan, inUsePaths: inUsePaths,
            takesSnapshots: takesSnapshots, isRegistered: isRegistered, result: &result, visited: &visited
        )
        return result
    }

    /// 1 回の走査で読むフォルダの上限(記号リンクは辿らないので輪にはならないが、巨大な木で止まらなくならないように)。
    static let maxFoldersPerExamination = 100_000

    private static func visit(
        _ folder: String, recursive: Bool, plan: AutoRenamePlan, inUsePaths: [String], takesSnapshots: Bool,
        isRegistered: @escaping (String) -> Bool, result: inout Result, visited: inout Int
    ) {
        guard visited < maxFoldersPerExamination, !Cancellation.isRequestedInCurrentScope,
              let names = try? FileOperationService.directoryEntryNames(atPath: folder)
        else { return }
        visited += 1
        let ruleIndices = plan.ruleIndices(forFolder: folder)
        var existing = Set(names)
        var subfolders: [String] = []
        var items: [(name: String, isDirectory: Bool)] = []
        for name in names {
            // 隠し項目(ドットで始まる名前。qooViewer の作業用の `.qooViewer-*` もここで外れる)は扱わない。
            guard !name.hasPrefix(".") else { continue }
            let path = folder + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            guard kind != S_IFLNK, info.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
            var isDirectory = kind == S_IFDIR
            if isDirectory, isPackage(path) {
                // パッケージ(.app など)は 1 つのファイルとして扱い、中へ降りない(ファイルブラウザの一覧と同じ)。
                isDirectory = false
            } else if isDirectory, recursive, plan.shouldDescend(into: path) {
                subfolders.append(path)
            }
            if !ruleIndices.isEmpty, !plan.excludedPaths.contains(path) { items.append((name, isDirectory)) }
        }
        if recursive {
            for subfolder in subfolders.sorted() {
                visit(
                    subfolder, recursive: true, plan: plan, inUsePaths: inUsePaths, takesSnapshots: takesSnapshots,
                    isRegistered: isRegistered, result: &result, visited: &visited
                )
            }
        }
        guard !ruleIndices.isEmpty else { return }
        let rules = ruleIndices.map { plan.rules[$0] }
        let texts = rules.map(\.text)
        for item in items.sorted(by: { $0.name < $1.name }) {
            let applicable = rules.filter { !item.isDirectory || $0.text.appliesToFolders }
            let decision = AutoRename.decide(
                name: item.name, isDirectory: item.isDirectory, rules: texts, existingNames: existing, isRegistered: isRegistered
            )
            switch decision {
            case .unchanged:
                continue
            case .skipped(let reason):
                result.skips.append(Skip(folder: folder, name: item.name, reason: reason, ruleNames: applicable.map(\.name)))
            case .rename(let newName):
                let path = folder + "/" + item.name
                if inUsePaths.contains(where: { MountTable.path($0, isAtOrUnder: path) }) {
                    result.foldersWithItemsInUse.insert(folder)
                    continue
                }
                let snapshot = takesSnapshots
                    ? AutoRenameFileSystem.snapshot(of: URL(fileURLWithPath: path), isDirectory: item.isDirectory) : nil
                result.candidates.append(Candidate(
                    folder: folder, name: item.name, isDirectory: item.isDirectory, newName: newName,
                    ruleNames: applicable.map(\.name), snapshot: snapshot
                ))
                // 後の項目の衝突の判定に、この名前が埋まる予定を入れる(元の名前はまだ空かないものとして残す)。
                existing.insert(newName)
            }
        }
    }

    private static func isPackage(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    }
}

extension AutoRename.SkipReason {
    /// 実行ログと確認の一覧に出す理由。
    nonisolated func message(locale: Locale) -> String {
        switch self {
        case .wouldKeepChanging:
            return String(localized: "Applying the rules again would change the name again, so it was left as it is.", language: locale)
        case .invalidName(_, let problem):
            switch problem {
            case .leadingDot:
                return String(localized: "The new name would begin with a dot “.”.", language: locale)
            case .invalid(let failure):
                return failure.localizedDescription
            }
        case .avoidedNameWouldKeepChanging:
            return String(
                localized: "An item with the new name already exists, and the rules would change the numbered name again.",
                language: locale
            )
        }
    }

    nonisolated var result: String {
        switch self {
        case .wouldKeepChanging(let result), .invalidName(let result, _), .avoidedNameWouldKeepChanging(let result): result
        }
    }
}

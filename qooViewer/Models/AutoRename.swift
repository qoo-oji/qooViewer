import Darwin
import Foundation

/// ファイルブラウザの自動リネーム(2026-09-15、ユーザー要望)の規則。設計と決定事項は docs/plans/auto-rename-study.md。
///
/// ■ 1 つの規則 = 名前の変え方 1 つ + 対象フォルダの列(検討メモ §2 の D 案)
/// 最初の案は「対象フォルダ 1 つ + 置換の組の列」だったが、同じ規則を複数のフォルダに掛けるとフォルダの数だけ設定を作り規則を
/// 写すことになる。規則ごとに掛ける範囲を変えられ、ON/OFF が一覧のチェックボックス 1 段で済むこの形にした(メールの振り分けルールと同じ)。
/// 規則は一覧の**上から順に**かける。
///
/// ■ 変え方は 2 つ(段階 2 の途中でユーザー要望により追加、2026-09-15)
/// - テキストを置き換える: 置き換える部分を「ファイル名」(拡張子を除いた部分)か「拡張子」から選ぶ(`zip` → `cbz` のため)。
/// - テキストを追加: Finder の一括リネームの「テキストを追加」と同じく、名前の前か後(拡張子の前)に付ける。**既に付いていれば付けない**
///   (付けないと、走査のたびにもう一度付いて名前が伸び続ける)。
///
/// 保存は `UserDefaults` の JSON(AutoRenameStore)。SwiftData のモデルではないので StoreSchemaGuard の世代は増えない。
nonisolated struct AutoRenameRule: Codable, Identifiable, Equatable, Sendable {
    enum Operation: String, Codable, CaseIterable, Sendable {
        case replaceText
        case addText
    }

    /// 置き換える部分。
    enum ReplaceScope: String, Codable, CaseIterable, Sendable {
        /// 拡張子(後ろから続く登録済みの拡張子)を除いた部分。
        case name
        /// 最後の拡張子。検索文字列と**丸ごと一致したときだけ**置き換える(部分一致にすると `z` → `x` で `zip` の一部が変わる)。
        case fileExtension
    }

    var id: UUID
    /// 利用者が付けた名前。空なら中身から付ける(`displayName`)。
    var name: String
    var isEnabled: Bool
    var operation: Operation
    var find: String
    var replaceWith: String
    var replaceScope: ReplaceScope
    /// 「テキストを追加」で付ける文字列。
    var addedText: String
    var addPlacement: BulkRename.Placement
    /// 大文字小文字を区別するか(§8 の 3。既定は区別しない ―― Finder の一括リネームと同じ)。「テキストを追加」では「既に付いているか」の判定に使う。
    var isCaseSensitive: Bool
    /// フォルダの名前も変えるか(§8 の 5。**既定 OFF**。コピー中のフォルダの名前を変えると Finder のコピーそのものが失敗するため ―― §9.2)。
    /// OFF でもサブフォルダの中のファイルは変える(「サブフォルダを含める」とは別の設定)。拡張子を置き換える規則はフォルダに掛けない。
    var includesFolders: Bool
    var targets: [AutoRenameTarget]

    init(
        id: UUID = UUID(), name: String = "", isEnabled: Bool = true, operation: Operation = .replaceText,
        find: String = "", replaceWith: String = "", replaceScope: ReplaceScope = .name,
        addedText: String = "", addPlacement: BulkRename.Placement = .afterName,
        isCaseSensitive: Bool = false, includesFolders: Bool = false, targets: [AutoRenameTarget] = []
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.operation = operation
        self.find = find
        self.replaceWith = replaceWith
        self.replaceScope = replaceScope
        self.addedText = addedText
        self.addPlacement = addPlacement
        self.isCaseSensitive = isCaseSensitive
        self.includesFolders = includesFolders
        self.targets = targets
    }

    /// 一覧に出す名前。名前が空なら中身から(「“foo” → “bar”」「“.zip” → “.cbz”」「“[tag] ” + 名前」)、中身も空なら「名称未設定の規則」。
    func displayName(locale: Locale) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard hasEffect else { return String(localized: "Untitled Rule", language: locale) }
        switch operation {
        case .replaceText:
            switch replaceScope {
            case .name:
                return String(format: String(localized: "“%1$@” → “%2$@”", language: locale), find, replaceWith)
            case .fileExtension:
                return String(
                    format: String(localized: "“%1$@” → “%2$@”", language: locale),
                    "." + AutoRename.bareExtension(find), "." + AutoRename.bareExtension(replaceWith)
                )
            }
        case .addText:
            switch addPlacement {
            case .beforeName: return String(format: String(localized: "“%@” + Name", language: locale), addedText)
            case .afterName: return String(format: String(localized: "Name + “%@”", language: locale), addedText)
            }
        }
    }

    /// 名前を変えうるか(検索文字列・付ける文字列が空の規則、置換後の拡張子が空の規則は何もしない)。
    var hasEffect: Bool {
        switch operation {
        case .replaceText:
            switch replaceScope {
            case .name: return !find.isEmpty
            case .fileExtension: return !AutoRename.bareExtension(find).isEmpty && !AutoRename.bareExtension(replaceWith).isEmpty
            }
        case .addText:
            return !addedText.isEmpty
        }
    }

    /// フォルダに掛かりうるか(拡張子を置き換える規則はフォルダに掛けない)。
    var canApplyToFolders: Bool {
        !(operation == .replaceText && replaceScope == .fileExtension)
    }

    /// 今ある項目に掛ける前の確認(§8 の 2)で「変わった」とみなす中身。ここが変わった規則は、確認し直すまでかけない。
    var confirmationSignature: String {
        [
            operation.rawValue, find, replaceWith, replaceScope.rawValue, addedText, addPlacement.rawValue,
            isCaseSensitive ? "cs" : "ci", includesFolders ? "folders" : "files",
        ].joined(separator: "\u{0}")
    }

    // MARK: - Codable(後から足した項目が無い JSON も読めるように)

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, operation, find, replaceWith, replaceScope, addedText, addPlacement, isCaseSensitive,
             includesFolders, targets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        operation = (try? container.decodeIfPresent(Operation.self, forKey: .operation)) ?? .replaceText
        find = try container.decodeIfPresent(String.self, forKey: .find) ?? ""
        replaceWith = try container.decodeIfPresent(String.self, forKey: .replaceWith) ?? ""
        replaceScope = (try? container.decodeIfPresent(ReplaceScope.self, forKey: .replaceScope)) ?? .name
        addedText = try container.decodeIfPresent(String.self, forKey: .addedText) ?? ""
        addPlacement = (try? container.decodeIfPresent(BulkRename.Placement.self, forKey: .addPlacement)) ?? .afterName
        isCaseSensitive = try container.decodeIfPresent(Bool.self, forKey: .isCaseSensitive) ?? false
        includesFolders = try container.decodeIfPresent(Bool.self, forKey: .includesFolders) ?? false
        targets = try container.decodeIfPresent([AutoRenameTarget].self, forKey: .targets) ?? []
    }
}

/// 規則の対象フォルダ 1 つ。**よく使う項目の配下のローカルのフォルダ**に限る(§6.1)。
nonisolated struct AutoRenameTarget: Codable, Identifiable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case enabled
        /// 利用者が OFF にした。
        case disabledByUser
        /// ボリュームは繋がっているのにフォルダが無かったので、自動で OFF にした(§6.2)。フォルダが戻っても自動では ON にしない。
        case disabledMissing
    }

    var id: UUID
    /// 揃えたパス(`AutoRename.canonicalPath`)。
    var path: String
    /// 登録したときのボリュームの UUID(`MountTable.volumeIdentifier`)。**「ボリュームは繋がっているのにフォルダが無い」の判定は、
    /// パスが載っているマウントの UUID がこれと一致したときだけ行う**(同じ名前の別のディスク・起動ボリュームに残った空の
    /// `/Volumes/X` を削除扱いにしない。§6.2)。
    var volumeUUID: String?
    /// 移動の提案(§6.3)のための**セキュリティスコープの無い**ブックマーク。権限の外へ移ったフォルダでもパスは得られる(§9.3)。
    /// スコープ付きを保存すると、よく使う項目の外へ移った対象にも書けてしまうので使わない。
    var bookmark: Data?
    var includesSubfolders: Bool
    var state: State
    /// `disabledMissing` になる直前の状態。移動の提案で「更新」したときに戻す(§6.3)。
    var stateBeforeMissing: State?
    /// 移動の提案で「この提案を表示しない」を選んだ。
    var suppressesMoveSuggestion: Bool
    /// 今ある項目に掛けることを確認した時点の中身(規則の `confirmationSignature` + この対象の設定)。いまの中身と違う対象には、
    /// 確認し直すまで何もかけない(§8 の 2)。OFF にすると消える(ON に戻したら確認し直す)。
    var confirmedSignature: String?
    /// 保存データの JSON から取り込んだ対象で、利用者がまだ確認していない(2026-09-23 の 3 回目の監査の中 6)。
    ///
    /// 確認の印の無い対象は、今ある項目に変える名前が無ければ黙って確認済みにする(`AutoRenameService.refreshConfirmations` ――
    /// 自分で足した規則なら、変えるものが無いことを確かめる手間を省いてよい)。取り込んだ規則は利用者が一度も見ていないので、
    /// それだと「中身を確認し直すまで触らない」という取り込みの約束が破れ、以後届いたファイルの名前を黙って変え始めた。true の
    /// 対象は、変えるものが無くても確認を待つ。`AutoRenameStore.confirm` で外れる。Optional なのは保存済みの JSON を読めるように。
    var awaitsReviewAfterImport: Bool?

    init(
        id: UUID = UUID(), path: String, volumeUUID: String? = nil, bookmark: Data? = nil, includesSubfolders: Bool = true,
        state: State = .enabled, stateBeforeMissing: State? = nil, suppressesMoveSuggestion: Bool = false,
        confirmedSignature: String? = nil
    ) {
        self.id = id
        self.path = AutoRename.canonicalPath(path)
        self.volumeUUID = volumeUUID
        self.bookmark = bookmark
        self.includesSubfolders = includesSubfolders
        self.state = state
        self.stateBeforeMissing = stateBeforeMissing
        self.suppressesMoveSuggestion = suppressesMoveSuggestion
        self.confirmedSignature = confirmedSignature
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// その規則のもとで、この対象が今ある項目に掛けてよいと確認済みか。
    func isConfirmed(for rule: AutoRenameRule) -> Bool {
        confirmedSignature == signature(for: rule)
    }

    func signature(for rule: AutoRenameRule) -> String {
        [rule.confirmationSignature, path, includesSubfolders ? "subfolders" : "direct"].joined(separator: "\u{0}")
    }

    /// `folder` の直下の項目がこの対象に含まれるか(対象そのもの、または「サブフォルダを含める」ときの配下のフォルダ)。
    func covers(folder: String) -> Bool {
        let folder = AutoRename.canonicalPath(folder)
        return folder == path || (includesSubfolders && MountTable.path(folder, isAtOrUnder: path))
    }
}

/// 自動リネームの名前の決め方と、書き終わりの判定(純粋関数。ファイルには触らない ―― 触る部分は AutoRenameFileSystem)。
nonisolated enum AutoRename {
    /// 規則の数の上限(§8 の 6)。
    static let maxRules = 20

    /// 自動リネームが比べるパスの書き方を 1 つに揃える(**ファイルに触らない文字列処理**)。
    ///
    /// 同じ場所が 3 通りに書かれて届く: よく使う項目は `standardizedFileURL` を通して `/private` を外した形(`/var/…`)、FSEvents はリンクを
    /// 解いた実体の形(`/private/var/…`)、起動ボリュームを見張ると `/System/Volumes/Data` の付いた形。揃えずに比べると、対象が
    /// 「よく使う項目の外」に見えて何も変わらない(サンドボックスの外で走る CI で発覚、2026-09-16。手元のテストはコンテナの中で `/private` が現れず通っていた)。
    /// `standardizedFileURL` は `/private` を**実在するときだけ**外す(消えたパスでは外れない)ので使わず、ここで文字列として外す。
    static func canonicalPath(_ path: String) -> String {
        var result = MountTable.normalized(FileBrowserState.pathOutsideDataVolume(path))
        for linked in ["/var", "/tmp", "/etc"] where MountTable.path(result, isAtOrUnder: "/private" + linked) {
            result.removeFirst("/private".count)
            break
        }
        return result
    }

    /// URL 版。`..` などの成分は `standardizedFileURL` で畳んでから揃える。
    static func canonicalPath(of url: URL) -> String {
        canonicalPath(url.standardizedFileURL.path)
    }
    /// 1 つの規則の対象フォルダの数の上限。
    static let maxTargetsPerRule = 20

    /// 名前を決めるときに見る、規則の中身だけ。
    struct RuleText: Equatable, Sendable {
        enum Operation: Equatable, Sendable {
            case replace(find: String, with: String, scope: AutoRenameRule.ReplaceScope)
            case add(text: String, placement: BulkRename.Placement)
        }

        var operation: Operation
        var isCaseSensitive: Bool
        var includesFolders: Bool

        init(operation: Operation, isCaseSensitive: Bool = false, includesFolders: Bool = false) {
            self.operation = operation
            self.isCaseSensitive = isCaseSensitive
            self.includesFolders = includesFolders
        }

        /// ファイル名の置き換え。
        init(find: String, replaceWith: String, isCaseSensitive: Bool = false, includesFolders: Bool = false) {
            self.init(operation: .replace(find: find, with: replaceWith, scope: .name), isCaseSensitive: isCaseSensitive,
                      includesFolders: includesFolders)
        }

        init(_ rule: AutoRenameRule) {
            let operation: Operation = switch rule.operation {
            case .replaceText: .replace(find: rule.find, with: rule.replaceWith, scope: rule.replaceScope)
            case .addText: .add(text: rule.addedText, placement: rule.addPlacement)
            }
            self.init(operation: operation, isCaseSensitive: rule.isCaseSensitive, includesFolders: rule.includesFolders)
        }

        var appliesToFolders: Bool {
            guard includesFolders else { return false }
            if case .replace(_, _, .fileExtension) = operation { return false }
            return true
        }
    }

    /// 拡張子の欄の入力から先頭のドットと前後の空白を落とす(`.zip` と `zip` を同じに扱う)。
    static func bareExtension(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        return trimmed
    }

    /// 項目 1 つについての結論。
    enum Decision: Equatable, Sendable {
        /// 規則をかけても名前が変わらない。
        case unchanged
        case rename(to: String)
        case skipped(SkipReason)
    }

    enum SkipReason: Equatable, Sendable {
        /// 規則をもう一度かけると名前がまた変わる(`a → aa`、`A → B` と `B → A` の 2 つの規則など)。変え続けないよう何もしない(§5.1)。
        case wouldKeepChanging(result: String)
        /// 使えない名前になる(先頭のドット・空・`/`・長すぎる)。
        case invalidName(result: String, problem: BulkRename.Problem)
        /// 重なる名前を `name 2` で避けたら、その名前に規則がまた掛かる(検索文字列が `2` など。§5.3)。
        case avoidedNameWouldKeepChanging(result: String)
    }

    /// `name` に `rules` を上から順にかけた結果。フォルダには「フォルダの名前も変える」規則だけをかける。
    ///
    /// **ファイル名の置き換えは、拡張子(後ろから続く登録済みの拡張子。一括リネームと同じ分け方)には掛けない。** 一括リネームは Finder と
    /// 同じく拡張子を含む名前全体で置き換えるが、無人で繰り返し掛かる自動リネームでそうすると、検索文字列が拡張子の中にも現れる規則が
    /// 拡張子を壊し続ける(`x → yx` で `x.txt` が `yx.tyxt.txt` になり、次の回にさらに伸びる。段階 1 のテストで判明、2026-09-15)。
    /// 拡張子を変えたいときは「拡張子」を選んだ規則で、最後の拡張子を丸ごと置き換える。
    static func applying(_ rules: [RuleText], to name: String, isDirectory: Bool, isRegistered: (String) -> Bool) -> String {
        rules.reduce(name) { current, rule in
            guard !isDirectory || rule.appliesToFolders else { return current }
            let options: String.CompareOptions = rule.isCaseSensitive ? [] : .caseInsensitive
            switch rule.operation {
            case let .replace(find, replaceWith, .name):
                guard !find.isEmpty else { return current }
                let (stem, ext) = BulkRename.splitExtension(current, isRegistered: isRegistered)
                let replaced = stem.replacingOccurrences(of: find, with: replaceWith, options: options)
                return ext.isEmpty ? replaced : replaced + "." + ext
            case let .replace(find, replaceWith, .fileExtension):
                let from = bareExtension(find)
                let to = bareExtension(replaceWith)
                let ext = (current as NSString).pathExtension
                let stem = (current as NSString).deletingPathExtension
                guard !from.isEmpty, !to.isEmpty, !ext.isEmpty, !stem.isEmpty,
                      ext.compare(from, options: options) == .orderedSame
                else { return current }
                return stem + "." + to
            case let .add(text, placement):
                guard !text.isEmpty else { return current }
                let (stem, ext) = BulkRename.splitExtension(current, isRegistered: isRegistered)
                let added: String
                switch placement {
                case .beforeName:
                    guard stem.range(of: text, options: options.union(.anchored)) == nil else { return current }
                    added = text + stem
                case .afterName:
                    guard stem.range(of: text, options: options.union([.anchored, .backwards])) == nil else { return current }
                    added = stem + text
                }
                return ext.isEmpty ? added : added + "." + ext
            }
        }
    }

    /// 名前を決める。
    ///
    /// - Parameters:
    ///   - existingNames: そのフォルダにある全部の名前(隠しファイルも。自分自身を含んでよい ―― 自分の名前は塞がっていない扱い)。
    ///   - isRegistered: 拡張子が登録済みか。テストは固定の表を渡す(BulkRename.plan と同じ)。
    static func decide(
        name: String, isDirectory: Bool, rules: [RuleText], existingNames: Set<String>,
        isRegistered: @escaping (String) -> Bool = BulkRename.isRegisteredExtension
    ) -> Decision {
        var cache: [String: Bool] = [:]
        let registered = { (ext: String) -> Bool in
            if let known = cache[ext] { return known }
            let known = isRegistered(ext)
            cache[ext] = known
            return known
        }
        let result = applying(rules, to: name, isDirectory: isDirectory, isRegistered: registered)
        guard result != name else { return .unchanged }
        // 使えない名前を先に見る(先頭のドットだけになった名前は拡張子を持たないので、もう一度かけると変わりうる ―― 理由は使えない名前の方)。
        if let problem = BulkRename.problem(forNewName: result) {
            return .skipped(.invalidName(result: result, problem: problem))
        }
        guard applying(rules, to: result, isDirectory: isDirectory, isRegistered: registered) == result else {
            return .skipped(.wouldKeepChanging(result: result))
        }
        let available = BulkRename.availableName(
            for: result, ownName: name, existingNames: existingNames, isRegistered: registered
        )
        guard available == result
                || applying(rules, to: available, isDirectory: isDirectory, isRegistered: registered) == available
        else {
            return .skipped(.avoidedNameWouldKeepChanging(result: available))
        }
        if available != result, let problem = BulkRename.problem(forNewName: available) {
            return .skipped(.invalidName(result: available, problem: problem))
        }
        return .rename(to: available)
    }

    // MARK: - 書き終わりの判定(§5.2)

    /// ファイル 1 つの様子。
    struct FileSnapshot: Equatable, Sendable {
        var size: Int64
        var modified: Date
        /// Finder がコピーしている途中の印(FinderInfo の種類/クリエータが `brok`/`MACS`)。単独のファイルのコピー中だけ付く(§9.2)。
        var isBeingCopiedByFinder: Bool
    }

    /// フォルダの様子。**フォルダ自身の更新時刻では判定しない**(大きなファイル 1 つを書いている間は動かない §9.2)ので、配下全部を持つ。
    struct FolderSnapshot: Equatable, Sendable {
        /// 配下の項目の相対パスごとの(大きさ, 更新時刻)。フォルダ自身は "" で入る。
        var entries: [String: CollectionAutoFolderScan.Snapshot]
        var containsItemBeingCopiedByFinder: Bool
        /// 数えきれないほど大きかった(`FolderSnapshot.maxEntries` を超えた)。
        var isTruncated: Bool

        /// 配下を数える上限。超えたフォルダは 2 回の観測で比べられない(比べる量が大きすぎる)ので、全部の更新時刻が古いときだけ通す。
        static let maxEntries = 20_000

        var newestModification: Date? {
            entries.values.map(\.modified).max()
        }
    }

    enum ItemSnapshot: Equatable, Sendable {
        case file(FileSnapshot)
        case folder(FolderSnapshot)
    }

    struct Observation: Equatable, Sendable {
        var snapshot: ItemSnapshot
        var at: Date
    }

    /// もう書き込みが終わっているとみなせるか。
    ///
    /// - ファイル: Finder のコピー中の印が無く、`CollectionAutoFolderScan.isSettled`(更新時刻が十分古い、または間を空けた 2 回の観測で
    ///   大きさも更新時刻も同じ)を通る。印を見るのは、遅い元から Finder が読んでいて書き込みが止まったのを「書き終わった」と
    ///   取り違えないため。
    /// - フォルダ: 配下に Finder のコピー中の印が無く、配下全部の更新時刻が十分古いか、間を空けた 2 回の観測で配下全部が同じ。
    static func isSettled(
        _ observation: Observation, previous: Observation?,
        quietFor quietInterval: TimeInterval = CollectionAutoFolderScan.quietInterval,
        minimumGap: TimeInterval = CollectionAutoFolderScan.recheckDelay
    ) -> Bool {
        switch observation.snapshot {
        case .file(let file):
            guard !file.isBeingCopiedByFinder else { return false }
            var previousFile: CollectionAutoFolderScan.Observation?
            if let previous, case .file(let earlier) = previous.snapshot, !earlier.isBeingCopiedByFinder {
                previousFile = .init(snapshot: .init(size: earlier.size, modified: earlier.modified), at: previous.at)
            }
            return CollectionAutoFolderScan.isSettled(
                .init(snapshot: .init(size: file.size, modified: file.modified), at: observation.at),
                previous: previousFile, quietFor: quietInterval, minimumGap: minimumGap
            )
        case .folder(let folder):
            guard !folder.containsItemBeingCopiedByFinder else { return false }
            if let newest = folder.newestModification {
                let age = observation.at.timeIntervalSince(newest)
                if age >= quietInterval { return true }
            } else {
                return true
            }
            guard !folder.isTruncated, let previous, case .folder(let earlier) = previous.snapshot, earlier == folder else {
                return false
            }
            return observation.at.timeIntervalSince(previous.at) >= minimumGap
        }
    }
}

/// 自動リネームがファイルシステムに触る部分(nonisolated。`FileIO` の上から呼ぶ)。
nonisolated enum AutoRenameFileSystem {
    /// Finder がコピー中のファイルに付ける FinderInfo の先頭 8 バイト(種類 `brok` + クリエータ `MACS`。§9.2 で実測)。
    static let finderCopyMarker: [UInt8] = Array("brokMACS".utf8)

    static func isBeingCopiedByFinder(_ path: String) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 32)
        let length = getxattr(path, "com.apple.FinderInfo", &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        guard length >= 8 else { return false }
        return Array(buffer.prefix(8)) == finderCopyMarker
    }

    /// 項目の様子を 1 回読む。読めなければ nil。
    static func snapshot(of url: URL, isDirectory: Bool) -> AutoRename.ItemSnapshot? {
        if !isDirectory {
            guard let file = fileSnapshot(url.path) else { return nil }
            return .file(AutoRename.FileSnapshot(size: file.size, modified: file.modified, isBeingCopiedByFinder: isBeingCopiedByFinder(url.path)))
        }
        guard let root = fileSnapshot(url.path) else { return nil }
        var entries: [String: CollectionAutoFolderScan.Snapshot] = ["": root]
        var busy = false
        var truncated = false
        var stack: [(path: String, relative: String)] = [(url.path, "")]
        while let (path, relative) = stack.popLast() {
            guard let names = try? FileOperationService.directoryEntryNames(atPath: path) else {
                continue
            }
            for name in names {
                let childPath = path + "/" + name
                let childRelative = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard lstat(childPath, &info) == 0 else { continue }
                if entries.count >= AutoRename.FolderSnapshot.maxEntries {
                    truncated = true
                    break
                }
                entries[childRelative] = .init(size: Int64(info.st_size), modified: modificationDate(info))
                let kind = info.st_mode & S_IFMT
                if kind == S_IFDIR {
                    stack.append((childPath, childRelative))
                } else if kind == S_IFREG, isBeingCopiedByFinder(childPath) {
                    busy = true
                }
            }
            if truncated { break }
        }
        return .folder(AutoRename.FolderSnapshot(entries: entries, containsItemBeingCopiedByFinder: busy, isTruncated: truncated))
    }

    private static func fileSnapshot(_ path: String) -> CollectionAutoFolderScan.Snapshot? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return .init(size: Int64(info.st_size), modified: modificationDate(info))
    }

    private static func modificationDate(_ info: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}

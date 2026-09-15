import AppKit
import Combine
import Foundation

/// 自動リネームの実行役(2026-09-15、ユーザー要望。設計と決定事項は docs/plans/auto-rename-study.md)。アプリ全体で 1 つ(AppStores)。
///
/// ■ 何を契機に動くか(§7)
/// 起動時の走査、規則・対象の変更、FSEvents(対象の配下すべてに届く。フォルダごと移ってきたときは中身のイベントが来ないので配下を読む。
/// あふれたら配下を全部読む)、ボリュームのマウント、よく使う項目・フォルダの許可・読み取り専用モードの変更、見送った項目の見直し。
/// **アプリが起動している間だけ動く**(終了中の変更は次の起動時の走査で拾う)。
///
/// ■ いつ名前を変えないか
/// - 読み取り専用モードの間(§8 の 1)。
/// - 対象が使えないとき(よく使う項目の外・未接続・ネットワーク・権限なし・見つからない。AutoRenameTargetProbe)。
/// - 今ある項目に掛けることをまだ確認していない対象(§8 の 2)。確認の一覧に出す。変わる項目が 1 つも無ければ、確認は要らないので黙って印を付ける。
/// - 書き込みが終わっていない(Finder のコピー中の印・2 回の観測。§5.2)。
/// - ビューアで開いている本(またはそれを含むフォルダ)。
/// - 規則をもう一度かけると変わる・使えない名前(§5.1・§5.3)。実行ログに 1 回だけ残す。
///
/// ■ 見つからない対象(§6.2・§6.3)
/// ボリュームは繋がっているのにフォルダが無ければ、1 秒ほど置いて確かめ直してから、その対象を自動で OFF にする。そのうえで保存しておいた
/// ブックマークを解き、移動したと思われる場所を提案として出す(`moveSuggestions`)。
///
/// 名前の変更は `FileOperationService.rename`(RENAME_EXCL・名前を正確に保つ・宛先の名前の長さの上限・ロックされた項目は断る)。
/// ウインドウの ⌘Z の履歴には積まない(どのウインドウの操作でもない)。戻すのは実行ログから(段階 7)。
@MainActor
final class AutoRenameService: ObservableObject {
    struct MoveSuggestion: Identifiable, Equatable, Sendable {
        enum Status: Equatable, Sendable {
            /// 更新できる。
            case updatable
            case inTrash
            case outsideFavorites
            case networkVolume
            case noAccess
            /// ブックマークから場所が分からなかった。
            case notFound
        }

        /// 元の場所(同じパスの対象は規則をまたいで 1 行にまとめる)。
        var id: String { originalPath }
        let originalPath: String
        let foundPath: String?
        let status: Status
        let targetIDs: Set<UUID>
        let ruleNames: [String]
    }

    struct PreviewItem: Identifiable, Equatable, Sendable {
        var id: String { folder + "/" + name }
        let folder: String
        let name: String
        /// 変える名前。変えない(見送る)項目は nil で `skipMessage` を持つ。
        let newName: String?
        let skipMessage: String?
        let ruleNames: [String]
    }

    /// 対象ごとの、いま使えるか。
    @Published private(set) var availability: [UUID: AutoRenameTargetAvailability] = [:]
    /// 今ある項目に掛ける前の確認を待っている対象(§8 の 2)。
    @Published private(set) var targetsAwaitingConfirmation: Set<UUID> = []
    @Published private(set) var moveSuggestions: [MoveSuggestion] = []
    /// 読み取り専用モードで止まっている。
    @Published private(set) var isPausedForReadOnly = false
    /// 規則の変更のたびに、利用者の操作で開く確認を促す通し番号(画面は値の変化だけを見る)。
    @Published private(set) var revision: UInt64 = 0

    private let store: AutoRenameStore
    private let log: AutoRenameActivityLog
    private let favorites: FavoriteLocationStore
    private let preferences: AppPreferences
    private let fileOps: FileOperationService
    /// そのフォルダに読み書きの許可があるか。本番は `FolderAccessStore.isPathCovered`。テストはコンテナの中を許可済みとして渡す。
    private let hasAccess: @MainActor (URL) -> Bool
    /// ビューアで開いている本のパス。
    private let inUsePaths: @MainActor () -> [String]
    private let locale: @MainActor () -> Locale

    private var subscriptions: [AnyCancellable] = []
    private var watcher: FolderChangeWatcher?
    private var isStarted = false

    // 走査の待ち行列
    private var pendingFullScan = false
    private var pendingShallowFolders: Set<String> = []
    private var pendingDeepFolders: Set<String> = []
    private var runTask: Task<Void, Never>?
    private var runScheduled: Task<Void, Never>?
    /// 書き終わりの判定の前回の観測(項目のパスごと)。
    private var observations: [String: AutoRename.Observation] = [:]
    /// 見直しの予約(フォルダごと。二重に積まない)。
    private var rechecks: [String: Task<Void, Never>] = [:]
    /// 自分が名前を変えたパス(元と新しい方)。そのイベントは読み飛ばす。
    private var recentlyRenamed: [String: Date] = [:]
    /// 同じ見送りを何度も実行ログに書かない(パス + 理由)。
    private var loggedSkips: Set<String> = []
    /// 走査に使った対象ごとの中身(規則の並び + 印)。変わった対象だけを走査し直す。
    private var activeTargetKeys: [UUID: String] = [:]
    /// 見つからないと 1 回目に分かった時刻(1 秒置いて確かめ直す)。
    private var missingSince: [UUID: Date] = [:]
    private var availabilityTask: Task<Void, Never>?
    private var needsAnotherAvailabilityPass = false
    private var availabilityRecheck: Task<Void, Never>?
    private var missingRecheckTask: Task<Void, Never>?

    /// 見送った項目を見直すまでの待ち。
    var recheckDelay: TimeInterval = 1.0
    /// 開いている本を見直すまでの待ち。
    var inUseRecheckDelay: TimeInterval = 5.0
    /// 見つからない対象を OFF にする前に置く時間(§6.2)。
    var missingConfirmationDelay: TimeInterval = 1.0
    /// 変更をまとめる時間。
    var coalescingDelay: TimeInterval = 0.3

    init(
        store: AutoRenameStore,
        log: AutoRenameActivityLog,
        favorites: FavoriteLocationStore,
        preferences: AppPreferences,
        fileOps: FileOperationService = FileOperationService(),
        hasAccess: @escaping @MainActor (URL) -> Bool,
        inUsePaths: @escaping @MainActor () -> [String] = { [] },
        locale: @escaping @MainActor () -> Locale = { AppLanguage.currentLocale }
    ) {
        self.store = store
        self.log = log
        self.favorites = favorites
        self.preferences = preferences
        self.fileOps = fileOps
        self.hasAccess = hasAccess
        self.inUsePaths = inUsePaths
        self.locale = locale
    }

    /// 動かし始める(AppStores。テストの中で走る実物のアプリでは呼ばない ―― 開発機の本物のフォルダの名前を変えないため)。
    func start(folderAccessChanges: AnyPublisher<Void, Never>? = nil) {
        guard !isStarted else { return }
        isStarted = true
        store.$rules.dropFirst()
            .sink { [weak self] _ in self?.rulesDidChange() }
            .store(in: &subscriptions)
        favorites.$items.dropFirst()
            .sink { [weak self] _ in self?.refreshAvailabilitySoon() }
            .store(in: &subscriptions)
        preferences.$fileBrowserReadOnly.dropFirst().removeDuplicates()
            .sink { [weak self] _ in
                // didSet の前に届くので、1 ランループ後に読み直す。
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.readOnlyDidChange() } }
            }
            .store(in: &subscriptions)
        folderAccessChanges?
            .sink { [weak self] _ in self?.refreshAvailabilitySoon() }
            .store(in: &subscriptions)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.publisher(for: name)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshAvailabilitySoon() } }
                .store(in: &subscriptions)
        }
        isPausedForReadOnly = preferences.fileBrowserReadOnly
        refreshAvailability(thenScanEverything: true)
    }

    /// 止める(テストと終了)。
    func stop() {
        subscriptions.removeAll()
        watcher?.tearDown()
        watcher = nil
        runTask?.cancel()
        runScheduled?.cancel()
        availabilityTask?.cancel()
        availabilityRecheck?.cancel()
        missingRecheckTask?.cancel()
        rechecks.values.forEach { $0.cancel() }
        rechecks.removeAll()
        isStarted = false
    }

    // MARK: - 画面から

    /// 対象の状態(画面の淡色と理由)。
    func availability(of targetID: UUID) -> AutoRenameTargetAvailability? {
        availability[targetID]
    }

    /// 確認の一覧の中身(§8 の 2)。`targetIDs` の対象を確認したとして、今ある項目のどれがどう変わるか。
    func preview(targetIDs: Set<UUID>) async -> [PreviewItem] {
        let plan = makePlan(including: targetIDs)
        let roots = Set(store.rules.flatMap(\.targets).filter { targetIDs.contains($0.id) }.map(\.path))
        let currentLocale = locale()
        let results = await FileIO.perform { () -> [AutoRenameScanner.Result] in
            roots.sorted().map { root in
                AutoRenameScanner.examine(folder: root, recursive: true, plan: plan, takesSnapshots: false)
            }
        }
        var seen: Set<String> = []
        var items: [PreviewItem] = []
        for result in results {
            for candidate in result.candidates where seen.insert(candidate.path).inserted {
                items.append(PreviewItem(
                    folder: candidate.folder, name: candidate.name, newName: candidate.newName, skipMessage: nil,
                    ruleNames: candidate.ruleNames
                ))
            }
            for skip in result.skips where seen.insert(skip.path).inserted {
                items.append(PreviewItem(
                    folder: skip.folder, name: skip.name, newName: nil, skipMessage: skip.reason.message(locale: currentLocale),
                    ruleNames: skip.ruleNames
                ))
            }
        }
        return items
    }

    /// 確認した(§8 の 2)。
    func confirm(targetIDs: Set<UUID>) {
        store.confirm(targetIDs: targetIDs)
        targetsAwaitingConfirmation.subtract(targetIDs)
    }

    /// 移動の提案で「更新」する(§6.3)。新しい場所のボリュームとブックマークを読み直してから書き換える。
    func applyMoveSuggestions(_ suggestions: [MoveSuggestion]) async {
        for suggestion in suggestions where suggestion.status == .updatable {
            guard let found = suggestion.foundPath else { continue }
            let (volume, bookmark) = await FileIO.perform { Self.volumeAndBookmark(for: found) }
            store.relocate(targetIDs: suggestion.targetIDs, to: found, volumeUUID: volume, bookmark: bookmark)
        }
        refreshAvailability()
    }

    func suppressMoveSuggestions(_ suggestions: [MoveSuggestion]) {
        store.suppressMoveSuggestion(targetIDs: Set(suggestions.flatMap(\.targetIDs)))
        moveSuggestions.removeAll { suggestion in suggestions.contains { $0.id == suggestion.id } }
    }

    /// 対象として足すフォルダの材料(ボリュームの UUID とブックマーク)。**ブロッキングする**ので `FileIO` の上で。
    nonisolated static func volumeAndBookmark(for path: String) -> (String?, Data?) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let volume = MountTable.current().volumeIdentifier(url)
        // セキュリティスコープの無いブックマーク(AutoRenameTarget.bookmark のコメント)。
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return (volume, bookmark)
    }

    /// そのフォルダを対象にできるか(よく使う項目の配下のローカルのフォルダ。§6.1)。できなければ理由。
    func eligibility(ofFolder url: URL) -> AutoRenameTargetAvailability {
        let path = MountTable.normalized(url.standardizedFileURL.path)
        guard isUnderFavorite(path) else { return .outsideFavorites }
        if MountTable.current().isRemote(URL(fileURLWithPath: path)) { return .networkVolume }
        return .available
    }

    func isUnderFavorite(_ path: String) -> Bool {
        let path = MountTable.normalized(path)
        return favorites.items.contains { MountTable.path(path, isAtOrUnder: $0.path) }
    }

    // MARK: - 変化

    private func rulesDidChange() {
        revision &+= 1
        refreshAvailabilitySoon()
    }

    private func readOnlyDidChange() {
        isPausedForReadOnly = preferences.fileBrowserReadOnly
        if !isPausedForReadOnly {
            // 止めていた間の変化は見ていないので、全部読み直す。
            activeTargetKeys.removeAll()
            requestFullScan()
        }
        updateWatcher()
    }

    private func refreshAvailabilitySoon() {
        availabilityRecheck?.cancel()
        let delay = coalescingDelay
        availabilityRecheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refreshAvailability()
        }
    }

    /// 全部の対象の状態を読み直し、見つからない対象を OFF にし、確認を待つ対象と走査し直す対象を決める。
    func refreshAvailability(thenScanEverything: Bool = false) {
        if thenScanEverything { pendingFullScan = true }
        guard availabilityTask == nil else {
            needsAnotherAvailabilityPass = true
            return
        }
        availabilityTask = Task { [weak self] in
            await self?.performAvailabilityPass()
            guard let self else { return }
            self.availabilityTask = nil
            if self.needsAnotherAvailabilityPass {
                self.needsAnotherAvailabilityPass = false
                self.refreshAvailability()
            }
        }
    }

    private func performAvailabilityPass() async {
        let targets = store.rules.flatMap(\.targets)
        let inputs = targets.map { target in
            (target.id, AutoRenameTargetProbe.Input(
                path: target.path, volumeUUID: target.volumeUUID, isUnderFavorite: isUnderFavorite(target.path),
                hasAccess: hasAccess(target.url)
            ))
        }
        let probed = await FileIO.perform { () -> [UUID: AutoRenameTargetAvailability] in
            let mounts = MountTable.current()
            var result: [UUID: AutoRenameTargetAvailability] = [:]
            // 同じパスは 1 回だけ見る。
            var byPath: [String: AutoRenameTargetAvailability] = [:]
            for (id, input) in inputs {
                let key = [input.path, input.volumeUUID ?? "", input.isUnderFavorite ? "f" : "", input.hasAccess ? "a" : ""].joined(separator: "\u{0}")
                if let known = byPath[key] {
                    result[id] = known
                } else {
                    let value = AutoRenameTargetProbe.availability(input, mounts: mounts)
                    byPath[key] = value
                    result[id] = value
                }
            }
            return result
        }
        if availability != probed { availability = probed }

        // 見つからない対象: 1 回目は時刻を控えて確かめ直しを予約し、2 回目(置いた時間の後)で OFF にする(§6.2)。
        let now = Date()
        var confirmedMissing: Set<UUID> = []
        var needsRecheck = false
        for target in targets {
            guard probed[target.id] == .missing, target.state == .enabled else {
                missingSince[target.id] = nil
                continue
            }
            if let since = missingSince[target.id], now.timeIntervalSince(since) >= missingConfirmationDelay {
                confirmedMissing.insert(target.id)
                missingSince[target.id] = nil
            } else {
                if missingSince[target.id] == nil { missingSince[target.id] = now }
                needsRecheck = true
            }
        }
        if !confirmedMissing.isEmpty {
            store.markMissing(targetIDs: confirmedMissing)
        }
        if needsRecheck, missingRecheckTask == nil {
            let delay = missingConfirmationDelay
            missingRecheckTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay + 0.05))
                guard let self, !Task.isCancelled else { return }
                self.missingRecheckTask = nil
                self.refreshAvailability()
            }
        }
        await refreshMoveSuggestions()
        await refreshConfirmations()
        updateWatcher()
        scheduleScansForChangedTargets()
    }

    // MARK: - 確認(§8 の 2)

    /// 使える・ON・未確認の対象について、今ある項目に変わるものがあるかを見る。無ければ黙って印を付け、あれば確認を待つ。
    private func refreshConfirmations() async {
        var awaiting: Set<UUID> = []
        var noChanges: Set<UUID> = []
        for rule in store.rules where rule.isEnabled && rule.hasEffect {
            for target in rule.targets where target.state == .enabled && availability[target.id] == .available
                && !target.isConfirmed(for: rule) {
                let items = await preview(targetIDs: [target.id]).filter { item in
                    MountTable.path(item.folder, isAtOrUnder: target.path)
                        && (item.folder == target.path || target.includesSubfolders)
                }
                if items.isEmpty {
                    noChanges.insert(target.id)
                } else {
                    awaiting.insert(target.id)
                }
            }
        }
        if !noChanges.isEmpty {
            store.confirm(targetIDs: noChanges)
        }
        if targetsAwaitingConfirmation != awaiting { targetsAwaitingConfirmation = awaiting }
    }

    // MARK: - 移動の提案(§6.3)

    private func refreshMoveSuggestions() async {
        var groups: [String: (ids: Set<UUID>, rules: [String], bookmark: Data?)] = [:]
        let currentLocale = locale()
        for rule in store.rules {
            for target in rule.targets where target.state == .disabledMissing && !target.suppressesMoveSuggestion {
                var group = groups[target.path] ?? ([], [], nil)
                group.ids.insert(target.id)
                let name = rule.displayName(locale: currentLocale)
                if !group.rules.contains(name) { group.rules.append(name) }
                group.bookmark = group.bookmark ?? target.bookmark
                groups[target.path] = group
            }
        }
        guard !groups.isEmpty else {
            if !moveSuggestions.isEmpty { moveSuggestions = [] }
            return
        }
        let bookmarks = groups.mapValues(\.bookmark)
        let resolved = await FileIO.perform { () -> [String: String] in
            var paths: [String: String] = [:]
            for (original, data) in bookmarks {
                guard let data else { continue }
                var isStale = false
                if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                      bookmarkDataIsStale: &isStale) {
                    paths[original] = MountTable.normalized(url.standardizedFileURL.path)
                }
            }
            return paths
        }
        let mounts = MountTable.current()
        var suggestions: [MoveSuggestion] = []
        for (original, group) in groups.sorted(by: { $0.key < $1.key }) {
            let found = resolved[original]
            let status: MoveSuggestion.Status
            if let found {
                if found.contains("/.Trash/") || found.contains("/.Trashes/") || found.hasSuffix("/.Trash") {
                    status = .inTrash
                } else if mounts.isRemote(URL(fileURLWithPath: found)) {
                    status = .networkVolume
                } else if !isUnderFavorite(found) {
                    status = .outsideFavorites
                } else if !hasAccess(URL(fileURLWithPath: found, isDirectory: true)) {
                    status = .noAccess
                } else {
                    status = .updatable
                }
            } else {
                status = .notFound
            }
            suggestions.append(MoveSuggestion(
                originalPath: original, foundPath: found, status: status, targetIDs: group.ids, ruleNames: group.rules
            ))
        }
        if suggestions != moveSuggestions { moveSuggestions = suggestions }
    }

    // MARK: - 走査の計画

    /// いま名前を変えてよい対象の計画。`extraTargetIDs` は未確認でも含める(確認の一覧の中身を作るとき)。
    func makePlan(including extraTargetIDs: Set<UUID> = []) -> AutoRenamePlan {
        let currentLocale = locale()
        var rules: [AutoRenamePlan.Rule] = []
        var targets: [AutoRenamePlan.Target] = []
        for rule in store.rules where rule.isEnabled && rule.hasEffect {
            let active = rule.targets.filter { target in
                target.state == .enabled && availability[target.id] == .available
                    && (target.isConfirmed(for: rule) || extraTargetIDs.contains(target.id))
            }
            guard !active.isEmpty else { continue }
            let index = rules.count
            rules.append(.init(id: rule.id, name: rule.displayName(locale: currentLocale), text: .init(rule)))
            targets += active.map { .init(id: $0.id, ruleIndex: index, path: $0.path, includesSubfolders: $0.includesSubfolders) }
        }
        return AutoRenamePlan(rules: rules, targets: targets)
    }

    /// 走査に使う中身が変わった対象(新しく使えるようになった・確認した・規則の並びが変わった)の配下を走査し直す。
    private func scheduleScansForChangedTargets() {
        let plan = makePlan()
        var keys: [UUID: String] = [:]
        for target in plan.targets {
            let rule = plan.rules[target.ruleIndex]
            keys[target.id] = "\(target.ruleIndex)\u{0}\(rule.id)\u{0}\(target.path)\u{0}\(target.includesSubfolders)\u{0}\(rule.text)"
        }
        let changed = plan.targets.filter { activeTargetKeys[$0.id] != keys[$0.id] }
        activeTargetKeys = keys
        if pendingFullScan {
            pendingFullScan = false
            for root in plan.roots { pendingDeepFolders.insert(root) }
            scheduleRun()
        } else if !changed.isEmpty {
            for target in changed { pendingDeepFolders.insert(target.path) }
            scheduleRun()
        }
    }

    private func requestFullScan() {
        pendingFullScan = true
        refreshAvailability()
    }

    // MARK: - FSEvents

    private func updateWatcher() {
        let plan = makePlan()
        let paths = isPausedForReadOnly ? [] : Set(plan.targets.map(\.path))
        if watcher == nil, !paths.isEmpty {
            watcher = FolderChangeWatcher { [weak self] events in
                Task { @MainActor in self?.handle(events) }
            }
        }
        guard let watcher else { return }
        Task { await watcher.watch(paths) }
    }

    func handle(_ events: [FolderChangeWatcher.Event]) {
        let now = Date()
        recentlyRenamed = recentlyRenamed.filter { now.timeIntervalSince($0.value) < 5 }
        let plan = makePlan()
        let allTargetPaths = Set(store.rules.flatMap(\.targets).map(\.path))
        var touchesTargetRoot = false
        for event in events {
            let path = MountTable.normalized(FileBrowserState.pathOutsideDataVolume(event.path))
            if allTargetPaths.contains(where: { MountTable.path($0, isAtOrUnder: path) }) {
                // 対象そのもの(か祖先)が改名・削除された。WatchRoot が無くても対象自身のパスで届く(§9.1)。
                touchesTargetRoot = true
            }
            guard recentlyRenamed[path] == nil else { continue }
            if event.mustScanSubdirectories {
                if plan.isRelevant(folder: path) { pendingDeepFolders.insert(path) }
                continue
            }
            let parent = (path as NSString).deletingLastPathComponent
            if !plan.ruleIndices(forFolder: parent).isEmpty { pendingShallowFolders.insert(parent) }
            if event.isDirectoryCreatedOrRenamed, plan.isRelevant(folder: path) { pendingDeepFolders.insert(path) }
        }
        if touchesTargetRoot { refreshAvailabilitySoon() }
        scheduleRun()
    }

    // MARK: - 走査と名前の変更

    private func scheduleRun() {
        guard runScheduled == nil else { return }
        let delay = coalescingDelay
        runScheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.runScheduled = nil
            self.startRunIfNeeded()
        }
    }

    private func startRunIfNeeded() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.runPendingWork()
            guard let self else { return }
            self.runTask = nil
            if !self.pendingShallowFolders.isEmpty || !self.pendingDeepFolders.isEmpty {
                self.scheduleRun()
            }
        }
    }

    /// テストの待ち合わせ用: 予約済みの走査が終わるまで待つ。
    func waitUntilIdle() async {
        while true {
            if let availabilityTask { await availabilityTask.value; continue }
            if let runScheduled { await runScheduled.value; continue }
            if let runTask { await runTask.value; continue }
            if let missingRecheckTask { await missingRecheckTask.value; continue }
            if availabilityRecheck != nil, !(availabilityRecheck?.isCancelled ?? true) {
                await availabilityRecheck?.value
                availabilityRecheck = nil
                continue
            }
            break
        }
    }

    private func runPendingWork() async {
        guard !isPausedForReadOnly, !preferences.fileBrowserReadOnly else {
            pendingShallowFolders.removeAll()
            pendingDeepFolders.removeAll()
            return
        }
        let plan = makePlan()
        guard !plan.isEmpty else {
            pendingShallowFolders.removeAll()
            pendingDeepFolders.removeAll()
            return
        }
        // 深く読むフォルダの配下は浅く読む必要が無い。祖先を深く読むなら子を深く読む必要も無い。
        let deep = pendingDeepFolders.sorted { $0.count < $1.count }.reduce(into: [String]()) { kept, path in
            if !kept.contains(where: { MountTable.path(path, isAtOrUnder: $0) }) { kept.append(path) }
        }
        let shallow = pendingShallowFolders.filter { folder in !deep.contains { MountTable.path(folder, isAtOrUnder: $0) } }
        pendingDeepFolders.removeAll()
        pendingShallowFolders.removeAll()
        let jobs = deep.map { ($0, true) } + shallow.sorted().map { ($0, false) }
        let inUse = inUsePaths()
        for (folder, recursive) in jobs {
            guard !isPausedForReadOnly else { return }
            let result = await FileIO.perform {
                AutoRenameScanner.examine(folder: folder, recursive: recursive, plan: plan, inUsePaths: inUse, takesSnapshots: true)
            }
            await process(result, plan: plan)
        }
    }

    private func process(_ result: AutoRenameScanner.Result, plan: AutoRenamePlan) async {
        let currentLocale = locale()
        var entries: [AutoRenameActivityLog.Entry] = []
        for skip in result.skips {
            let key = skip.path + "\u{0}" + skip.reason.result
            guard loggedSkips.insert(key).inserted else { continue }
            entries.append(.init(
                folderPath: skip.folder, originalName: skip.name,
                outcome: .skipped(result: skip.reason.result, reason: skip.reason.message(locale: currentLocale)),
                ruleNames: skip.ruleNames
            ))
        }
        for folder in result.foldersWithItemsInUse {
            scheduleRecheck(folder: folder, after: inUseRecheckDelay)
        }
        let now = Date()
        for candidate in result.candidates {
            guard !isPausedForReadOnly else { break }
            guard let snapshot = candidate.snapshot else { continue }
            let observation = AutoRename.Observation(snapshot: snapshot, at: now)
            guard AutoRename.isSettled(observation, previous: observations[candidate.path]) else {
                observations[candidate.path] = observation
                scheduleRecheck(folder: candidate.folder, after: recheckDelay)
                continue
            }
            observations[candidate.path] = nil
            let item = URL(fileURLWithPath: candidate.path, isDirectory: candidate.isDirectory)
            recentlyRenamed[candidate.path] = Date()
            recentlyRenamed[candidate.folder + "/" + candidate.newName] = Date()
            do {
                let receipt = try await fileOps.rename(item, to: candidate.newName, keepsNameExactly: true)
                entries.append(.init(
                    folderPath: candidate.folder, originalName: candidate.name, outcome: .renamed(newName: candidate.newName),
                    ruleNames: candidate.ruleNames, identity: receipt.identity
                ))
            } catch FileOperationError.alreadyExists, FileOperationError.itemMissing {
                // 決めてから変えるまでの間に外で変わった。フォルダを読み直して決め直す。
                scheduleRecheck(folder: candidate.folder, after: recheckDelay)
            } catch {
                let key = candidate.path + "\u{0}failed\u{0}" + candidate.newName
                guard loggedSkips.insert(key).inserted else { continue }
                entries.append(.init(
                    folderPath: candidate.folder, originalName: candidate.name,
                    outcome: .failed(newName: candidate.newName, message: error.localizedDescription),
                    ruleNames: candidate.ruleNames
                ))
            }
        }
        log.append(entries)
    }

    private func scheduleRecheck(folder: String, after delay: TimeInterval) {
        guard rechecks[folder] == nil else { return }
        rechecks[folder] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.rechecks[folder] = nil
            self.pendingShallowFolders.insert(folder)
            self.scheduleRun()
        }
    }

    /// テストの待ち合わせ用: 見直しの予約があるか。
    var hasPendingRechecks: Bool { !rechecks.isEmpty }
}

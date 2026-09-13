import AppKit
import Combine
import Foundation

/// ファイルブラウザの書く操作の窓口(改善要望7 段階4、2026-09-13)。コピー・カット・ペースト・ゴミ箱・
/// 新規フォルダ・名前の変更・取り消し/やり直しを、リスト・アイコン・ツリー・メニューバーの全部が
/// **ここ1つ**を通して行う。
///
/// `FileBrowserState`が1つ持つ(ウインドウごと)。本を開いてファイルブラウザが画面から消えても生きているので、
/// 走っている操作は途中で捨てられない。
///
/// ■ 同時に走る操作は1本
/// 次の操作は前の操作が終わるのを待つ(`enqueue`)。2本を並べると、進捗の帯が2本要るうえ、
/// 前の操作の衝突の確認と次の操作の確認が重なる。
///
/// ■ 見せるのは`presenter`
/// 確認(完全削除・衝突)と問題の報告はここでは描かず、`FileBrowserOperationPresenting`へ渡す
/// (本番はウインドウのシート。テストは台本どおりに答える偽物)。**問題を見せる前に進捗の帯を片付ける**
/// (qooLibrary で、帯が出たままダイアログが出て「まだ動いている」ように見えた)。
///
/// ■ 「置き換える」
/// 置き換えの途中でアプリが落ちると、元の項目が隠しフォルダに退避されたまま残る(FileOperationServiceの
/// checkConflictのコメント)。退避は作る前に `ReplaceBackupJournal` へ記録し、次の起動で戻す
/// (`ReplaceBackupRecovery`)。それが入るまで(2026-09-13〜14)衝突の確認は「両方残す / スキップ / 中止」だけだった。
/// ゴミ箱の無い場所では置き換えた元をすぐに消すしかないので、確認の文でそう伝える(`replacingDeletesImmediately`)。
@MainActor
final class FileBrowserOperations: ObservableObject {
    /// いま走っている操作(進捗の帯)。nil なら帯を出さない。
    @Published private(set) var activity: FileBrowserActivity?

    weak var state: FileBrowserState?
    /// 確認と報告を見せる相手。ペインが出たときに本物を入れる。
    var presenter: (any FileBrowserOperationPresenting)?

    // 以下はテストで差し替える口(本番は既定のまま)。
    var fileOps: FileOperationService = .shared
    var pasteboard: NSPasteboard = .general
    /// ゴミ箱の有無の判定。FileIO の上で呼ばれる。
    var hasTrash: @Sendable (URL) -> Bool = { TrashAvailability.hasTrash(for: $0) }
    /// 帯を出すまでの猶予(一瞬で終わる操作で帯がちらつかないように)。
    var activityRevealDelay: Duration = .milliseconds(400)

    private var queueTail: Task<Void, Never>?
    private var activityCancellation: Cancellation?

    init() {}

    // MARK: - 取り消し・やり直し

    var commandStack: FileCommandStack? { state?.commandStack }

    @discardableResult
    func undo() -> Task<Void, Never> {
        enqueue { [weak self] in
            guard let self, let stack = self.commandStack else { return }
            let outcome = await stack.undo()
            self.didChangeFileSystem(inUnknownScope: true)
            self.presentIfNeeded(outcome, isRedo: false)
        }
    }

    @discardableResult
    func redo() -> Task<Void, Never> {
        enqueue { [weak self] in
            guard let self, let stack = self.commandStack else { return }
            let outcome = await stack.redo()
            self.didChangeFileSystem(inUnknownScope: true)
            self.presentIfNeeded(outcome, isRedo: true)
        }
    }

    // MARK: - コピー・カット・ペースト

    /// ⌘C。ペーストボードへファイルの URL を書く(Finder へ貼ればコピーになる)。
    func copy(_ entries: [FileBrowserEntry]) {
        write(entries, cut: false)
    }

    /// ⌘X。書く内容は⌘Cと同じで、**アプリの中で覚えておく**(ペーストしたときに一致すれば移動)。
    /// Finder のカットの判定は非公開の API なので、Finder へ貼るとコピーになる(検討メモ §3.2)。
    func cut(_ entries: [FileBrowserEntry]) {
        write(entries, cut: true)
    }

    /// ペーストボードにファイルがあるか(メニューの淡色の判定。ファイルシステムには触らない)。
    var canPaste: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: Self.fileURLOptions)
    }

    /// ⌘V(`forceMove` なら ⌥⌘V「ここに項目を移動」)。`folder` へ貼る。
    ///
    /// カットした集合と**ペーストボードの集合がそのまま一致したときだけ移動**(他のアプリで別のものを
    /// コピーした後に、前のカットの記憶で移動してしまわない)。移動したらカットの記憶を消す。
    /// 同じフォルダへのコピーは「両方残す」で複製にする(Finder の「のコピー」に当たる。名前は `name 2`)。
    ///
    /// **Finder などほかのアプリでコピーした項目も、許可の無い場所から貼れる**(2026-09-14、許可を持たない Debug で実測)。
    /// ペーストボードから読んだ URL には、**その項目自身**への読み書きの許可が付く(フォルダなら中身ごと)。
    /// 拡張を添えずに型のバイト列だけを置いた URL でも同じだったので、付けているのは書き手ではなくペーストボードの側。
    /// 親フォルダへの許可は付かないが、⌥⌘V の移動は通る(元の削除は項目自身の許可で足りる)。
    /// ただし**その移動の取り消しは、元のフォルダへ書けず「アクセス権がありません」で失敗する**(運んだものは宛先に残る)。
    @discardableResult
    func paste(into folder: URL, forceMove: Bool = false) -> Task<Void, Never> {
        let urls = readPasteboardURLs()
        guard !urls.isEmpty else { return Task {} }
        let isMove = forceMove || (!(state?.cutPaths.isEmpty ?? true) && Self.paths(of: urls) == state?.cutPaths)
        if isMove { state?.setCutPaths([]) }
        return transfer(urls, to: folder, isMove: isMove)
    }

    /// 移動またはコピー(ペースト)。
    @discardableResult
    func transfer(_ urls: [URL], to folder: URL, isMove: Bool) -> Task<Void, Never> {
        transfer(moving: isMove ? urls : [], copying: isMove ? [] : urls, to: folder)
    }

    /// ドラッグ&ドロップ(段階4b)。移動とコピーが混ざった 1 回のドロップは**1 回の取り消しで戻る**
    /// (`CompositeFileCommand`。検討メモ §9)。
    @discardableResult
    func drop(_ plan: FileDropPlan, into folder: URL) -> Task<Void, Never> {
        transfer(moving: plan.moves, copying: plan.copies, to: folder)
    }

    private func transfer(moving moves: [URL], copying copies: [URL], to folder: URL) -> Task<Void, Never> {
        enqueue { [weak self] in
            guard let self else { return }
            let destinationPath = FileBrowserState.id(for: folder)
            let isInDestination = { (url: URL) in FileBrowserState.id(for: url.deletingLastPathComponent()) == destinationPath }
            // 自分のフォルダへの移動は何もしない(エンジンの決まり)ので、同じフォルダの項目は外す。
            let movers = moves.filter { !isInDestination($0) }
            let duplicates = copies.filter(isInDestination)
            let copiers = copies.filter { !isInDestination($0) }
            let cancellation = Cancellation()
            let options = self.transferOptions(policy: .ask, cancellation: cancellation)
            var commands: [any FileCommand] = []
            if !movers.isEmpty {
                commands.append(MoveFilesCommand(items: movers, destination: folder, options: options, fileOps: self.fileOps))
            }
            if !duplicates.isEmpty {
                // 同じフォルダへのコピーは複製(「両方残す」。Finder の「のコピー」に当たる)。
                var duplicate = options
                duplicate.conflictPolicy = .keepBoth
                commands.append(CopyFilesCommand(items: duplicates, destination: folder, options: duplicate, fileOps: self.fileOps))
            }
            if !copiers.isEmpty {
                commands.append(CopyFilesCommand(items: copiers, destination: folder, options: options, fileOps: self.fileOps))
            }
            guard !commands.isEmpty else { return }
            let count = moves.count + copies.count
            let isMove = copies.isEmpty
            let urls = moves + copies
            let command: any FileCommand = commands.count == 1
                ? commands[0]
                : CompositeFileCommand(displayName: Self.transferName(count: count, isMove: isMove), children: commands)
            let title = Self.activityTitle(count: count, isMove: isMove)
            await self.run(command, title: title, cancellation: cancellation, affected: [folder] + urls.map { $0.deletingLastPathComponent() }) { result in
                // 運んだものを選ぶ(今のフォルダへ貼ったとき)。
                let placed = commands.flatMap { child -> [URL] in
                    (child as? MoveFilesCommand)?.outcome.receipts.map(\.destination)
                        ?? (child as? CopyFilesCommand)?.outcome.receipts.map(\.destination) ?? []
                }
                return placed
            }
        }
    }

    // MARK: - ゴミ箱

    /// ⌘⌫。ゴミ箱の無い場所(ネットワーク共有)が混ざっていれば、「すぐに削除されます」と確認してから
    /// 完全に削除する(決定事項 Q4。取り消せない)。
    @discardableResult
    func moveToTrash(_ entries: [FileBrowserEntry]) -> Task<Void, Never> {
        let urls = entries.filter { !$0.isVolume }.map(\.url)
        return enqueue { [weak self] in
            guard let self, !urls.isEmpty else { return }
            let hasTrash = self.hasTrash
            let canTrash = await FileIO.perform { TrashAvailability.hasTrash(forAll: urls, using: hasTrash) }
            if !canTrash {
                guard await self.presenter?.confirmImmediateDeletion(of: urls) == true else { return }
            }
            // ロックされた項目は確認してから(Finder と同じ「続ける / 中止」)。ゴミ箱へ送るなら項目自身のロックだけが
            // 邪魔をする(中にロックされた項目があるフォルダは送れる。実測)が、完全に削除するなら中の項目も見る。
            let locked = await FileIO.perform {
                urls.filter { canTrash ? FileOperationService.isLocked($0) : FileOperationService.containsLockedItem($0) }
            }
            var unlocking = false
            if !locked.isEmpty {
                guard await self.presenter?.confirmLockedItems(locked, deletesImmediately: !canTrash) == true else { return }
                unlocking = true
            }
            let command: any FileCommand = canTrash
                ? TrashFilesCommand(items: urls, unlockingLocked: unlocking, fileOps: self.fileOps)
                : DeleteFilesImmediatelyCommand(items: urls, unlockingLocked: unlocking, fileOps: self.fileOps)
            let locale = AppLanguage.currentLocale
            let title = urls.count == 1
                ? String(format: String(localized: "Moving “%@” to the Trash…", language: locale), urls[0].lastPathComponent)
                : String(format: String(localized: "Moving %lld items to the Trash…", language: locale), urls.count)
            await self.run(command, title: title, cancellation: nil, affected: urls.map { $0.deletingLastPathComponent() }) { _ in [] }
        }
    }

    // MARK: - 新規フォルダ・名前の変更

    /// 新規フォルダ。作ったら選んで、名前の編集を始めてもらう(`state.requestRename`)。
    @discardableResult
    func newFolder(in folder: URL) -> Task<Void, Never> {
        enqueue { [weak self] in
            guard let self else { return }
            let existing = await FileIO.perform {
                Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            }
            let name = FileNameValidation.untitledFolderName(existing: existing)
            let url = folder.appendingPathComponent(name, isDirectory: true)
            let command = CreateFolderCommand(url: url, fileOps: self.fileOps)
            await self.run(command, title: nil, cancellation: nil, affected: [folder]) { _ in [url] }
            if let state = self.state, FileBrowserState.id(of: state.currentFolder) == FileBrowserState.id(for: folder),
               await FileIO.perform({ FileOperationService.itemExists(at: url) }) {
                state.requestRename(FileBrowserState.id(for: url))
            }
        }
    }

    /// 名前の変更(インラインの編集が確定したとき)。同じ名前なら何もしない。
    @discardableResult
    func rename(_ entry: FileBrowserEntry, to newName: String) -> Task<Void, Never> {
        let url = entry.url
        return enqueue { [weak self] in
            guard let self else { return }
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != url.lastPathComponent else { return }
            let command = RenameFileCommand(item: url, newName: newName, fileOps: self.fileOps)
            await self.run(command, title: nil, cancellation: nil, affected: [url.deletingLastPathComponent()]) { _ in
                command.receipt.map { [$0.renamed] } ?? []
            }
        }
    }

    // MARK: - 進捗の帯

    /// 帯の中止ボタン。次の区切り(項目の境目・copyfile の callback)で止まる。
    func cancelActivity() {
        activityCancellation?.request()
    }

    /// 走っている(または待っている)操作が全部終わるまで待つ。**テストのための口。**
    func settle() async {
        while let task = queueTail {
            await task.value
            if queueTail == task { return }
        }
    }

    // MARK: - 下請け

    /// 前の操作が終わってから `work` を始める。
    @discardableResult
    private func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = queueTail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        queueTail = task
        return task
    }

    /// コマンドを積み場所で実行し、帯・読み直し・選択・報告までを済ませる。
    ///
    /// - Parameter placed: 成功後に選ぶ項目(今のフォルダの中のものだけが効く)。
    private func run(
        _ command: any FileCommand, title: String?, cancellation: Cancellation?, affected: [URL],
        placed: (FileCommandResult?) -> [URL]
    ) async {
        guard let stack = commandStack else { return }
        let token = title.map { beginActivity(title: $0, cancellation: cancellation) }
        var problem: FileBrowserProblem?
        var result: FileCommandResult?
        do {
            result = try await stack.run(command)
            if case let .partial(_, failures, wasCancelled)? = result, !failures.isEmpty, !wasCancelled {
                problem = FileBrowserProblem.partialFailure(operationName: command.displayName, failures: failures)
            }
        } catch {
            if !FileCommandStack.isCancellation(error) {
                problem = FileBrowserProblem(
                    title: String(
                        format: String(localized: "The operation “%@” couldn’t be completed.", language: AppLanguage.currentLocale),
                        command.displayName
                    ),
                    message: error.localizedDescription
                )
            }
        }
        if let token { endActivity(token) }
        didChangeFileSystem(affected: affected, selecting: placed(result))
        // **帯を片付けてから見せる**(型コメント)。
        if let problem { presenter?.showProblem(problem) }
    }

    private func beginActivity(title: String, cancellation: Cancellation?) -> UUID {
        let id = UUID()
        activityCancellation = cancellation
        let delay = activityRevealDelay
        let pending = FileBrowserActivity(id: id, title: title, progress: FileOperationProgress(), isCancellable: cancellation != nil)
        pendingActivity = pending
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, let pending = self.pendingActivity, pending.id == id else { return }
            self.activity = pending
        }
        return id
    }

    /// 帯を出す前(猶予の間)の進捗もここへ溜める(出した瞬間から正しい数字を見せる)。
    private var pendingActivity: FileBrowserActivity? {
        didSet {
            if activity != nil, let pendingActivity, activity?.id == pendingActivity.id { activity = pendingActivity }
        }
    }

    private func endActivity(_ id: UUID) {
        guard pendingActivity?.id == id else { return }
        pendingActivity = nil
        activity = nil
        activityCancellation = nil
    }

    private func report(_ progress: FileOperationProgress) {
        guard var pending = pendingActivity else { return }
        if pending.bytesStartedAt == nil, progress.completedBytes > 0 { pending.bytesStartedAt = Date() }
        pending.progress = progress
        pendingActivity = pending
    }

    private func transferOptions(policy: ConflictPolicy, cancellation: Cancellation) -> FileOperationOptions {
        let sink = ProgressSink { [weak self] progress in
            Task { @MainActor [weak self] in self?.report(progress) }
        }
        return FileOperationOptions(
            conflictPolicy: policy,
            conflictResolver: { [weak self] conflict in
                guard let self, let presenter = self.presenter else { return ConflictDecision(.skip) }
                let hasTrash = self.hasTrash
                let folder = conflict.destination.deletingLastPathComponent()
                let deletesImmediately = await FileIO.perform { !hasTrash(folder) }
                return await presenter.resolveConflict(conflict, replacingDeletesImmediately: deletesImmediately, cancellation: cancellation)
            },
            progress: sink,
            cancellation: cancellation
        )
    }

    /// 操作のあとで一覧とツリーを読み直す。ネットワークでは FSEvents が飛ばないので、待たずに明示的に読む。
    /// - Parameter inUnknownScope: 取り消し・やり直し。どのフォルダが変わったか分からないので、ツリーには全体を
    ///   見直してもらう(以前は何も知らせず、取り消しで戻ったフォルダがツリーに出てこなかった。実機 2026-09-13)。
    private func didChangeFileSystem(affected: [URL] = [], selecting placed: [URL] = [], inUnknownScope: Bool = false) {
        guard let state else { return }
        let current = FileBrowserState.id(of: state.currentFolder)
        let selectable = Set(placed.filter { FileBrowserState.id(for: $0.deletingLastPathComponent()) == current }
            .map(FileBrowserState.id(for:)))
        state.reload(selecting: selectable.isEmpty ? nil : selectable)
        if inUnknownScope {
            state.noteFileSystemChangeInUnknownScope()
        } else {
            state.noteFileSystemChange(in: affected)
        }
    }

    private func presentIfNeeded(_ outcome: FileUndoOutcome, isRedo: Bool) {
        guard outcome.needsAttention, let problem = FileBrowserProblem.undo(outcome, isRedo: isRedo) else { return }
        presenter?.showProblem(problem)
    }

    private func write(_ entries: [FileBrowserEntry], cut: Bool) {
        let urls = entries.filter { !$0.isVolume }.map(\.url)
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        state?.setCutPaths(cut ? Self.paths(of: urls) : [])
    }

    private func readPasteboardURLs() -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: Self.fileURLOptions) as? [URL]) ?? []
    }

    private static let fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    /// カットの判定に使うパスの集合。**読み戻した URL は末尾の `/` などで `==` が外れる**(qooLibrary 実測)ので、
    /// 標準化したパスで比べる。
    nonisolated static func paths(of urls: [URL]) -> Set<String> {
        Set(urls.map { MountTable.normalized($0.standardizedFileURL.path) })
    }

    private static func transferName(count: Int, isMove: Bool) -> String {
        let locale = AppLanguage.currentLocale
        return isMove
            ? String(format: String(localized: "Move of %lld Items", language: locale), count)
            : String(format: String(localized: "Copy of %lld Items", language: locale), count)
    }

    private static func activityTitle(count: Int, isMove: Bool) -> String {
        let locale = AppLanguage.currentLocale
        return isMove
            ? String(format: String(localized: "Moving %lld items…", language: locale), count)
            : String(format: String(localized: "Copying %lld items…", language: locale), count)
    }
}

/// 進捗の帯に出す 1 本の操作。
struct FileBrowserActivity: Equatable, Identifiable {
    let id: UUID
    let title: String
    var progress: FileOperationProgress
    /// 中止ボタンを出すか(ゴミ箱は途中で止められない)。
    let isCancellable: Bool
    /// バイトが動き始めた時刻(残り時間の見積りはここからの平均速度。計測 1 秒未満なら出さない)。
    var bytesStartedAt: Date?

    init(id: UUID, title: String, progress: FileOperationProgress, isCancellable: Bool) {
        self.id = id
        self.title = title
        self.progress = progress
        self.isCancellable = isCancellable
    }

    /// 残り秒数。総量が分からない・動き始めて 1 秒未満・まだ速度が出ていないなら nil。
    func estimatedSecondsRemaining(now: Date = Date()) -> TimeInterval? {
        guard let started = bytesStartedAt, progress.totalBytes > 0, progress.completedBytes > 0 else { return nil }
        let elapsed = now.timeIntervalSince(started)
        guard elapsed >= 1 else { return nil }
        let rate = Double(progress.completedBytes) / elapsed
        guard rate > 0 else { return nil }
        return max(0, Double(progress.totalBytes - progress.completedBytes) / rate)
    }
}

/// 利用者に見せる問題 1 件(何が / なぜ / 次に何ができるか を title と message に入れる)。
struct FileBrowserProblem: Equatable {
    let title: String
    let message: String

    /// 一覧に並べる失敗の上限(超えた分は件数だけ)。
    static let listedFailureLimit = 10

    static func partialFailure(operationName: String, failures: [FailedItem]) -> FileBrowserProblem {
        let locale = AppLanguage.currentLocale
        return FileBrowserProblem(
            title: String(
                format: String(localized: "Some items couldn’t be processed during “%@”.", language: locale),
                operationName
            ),
            message: listing(failures, locale: locale)
        )
    }

    static func undo(_ outcome: FileUndoOutcome, isRedo: Bool) -> FileBrowserProblem? {
        let locale = AppLanguage.currentLocale
        switch outcome {
        case .nothingToDo, .complete:
            return nil
        case let .partial(name, _, failures):
            return FileBrowserProblem(
                title: String(
                    format: isRedo
                        ? String(localized: "“%@” could only be partly redone.", language: locale)
                        : String(localized: "“%@” could only be partly undone.", language: locale),
                    name
                ),
                message: listing(failures, locale: locale)
            )
        case let .failed(name, reason):
            return FileBrowserProblem(
                title: String(
                    format: isRedo
                        ? String(localized: "“%@” couldn’t be redone.", language: locale)
                        : String(localized: "“%@” couldn’t be undone.", language: locale),
                    name
                ),
                message: reason
            )
        }
    }

    private static func listing(_ failures: [FailedItem], locale: Locale) -> String {
        var lines = failures.prefix(listedFailureLimit).map { "\($0.name): \($0.reason)" }
        if failures.count > listedFailureLimit {
            lines.append(String(
                format: String(localized: "…and %lld more.", language: locale),
                failures.count - listedFailureLimit
            ))
        }
        return lines.joined(separator: "\n")
    }
}

/// 確認と報告を見せる相手(本番はシート、テストは偽物)。
@MainActor
protocol FileBrowserOperationPresenting: AnyObject {
    /// 「すぐに削除されます。取り消せません」。削除してよければ true。
    func confirmImmediateDeletion(of urls: [URL]) async -> Bool
    /// ロックされた項目をゴミ箱へ送る(`deletesImmediately` なら完全に削除する)か。続けてよければ true。
    func confirmLockedItems(_ urls: [URL], deletesImmediately: Bool) async -> Bool
    /// 同じ名前の項目があった。「中止」は `cancellation.request()` してスキップを返す。
    /// - Parameter replacingDeletesImmediately: 宛先にゴミ箱が無く、「置き換える」と元の項目がすぐに消える。
    func resolveConflict(_ conflict: FileConflict, replacingDeletesImmediately: Bool, cancellation: Cancellation) async -> ConflictDecision
    func showProblem(_ problem: FileBrowserProblem)
}

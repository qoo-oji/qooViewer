import Foundation

/// ファイルブラウザの取り消せる操作 1 回ぶん(改善要望7 段階 2、2026-09-13。qooLibrary の `Command` を写したもの)。
///
/// ■ NSUndoManager を使わない理由(計画 §4.4)
/// 取り消しが非同期で、部分的にしか戻せないことがあり、「戻せなかった」を必ず見せなければならず、
/// 進捗と中止も要る ―― `registerUndo` のクロージャ 1 本では表せない。
///
/// ■ @MainActor
/// 作る・実行する・積むのは FileCommandStack(ウインドウごと)と画面だけで、アクターをまたいで
/// 受け渡さない。I/O は中で FileOperationService(actor)へ渡る。
@MainActor
protocol FileCommand: AnyObject {
    /// 編集メニューの「取り消す」「やり直す」の後ろに付く名前(「“X” の移動」)。表示言語で組む。
    var displayName: String { get }
    /// false なら FileCommandStack が積まない(ゴミ箱の無い場所での削除)。
    var isUndoable: Bool { get }
    /// 済んだときに鳴らす音(nil は無音)。**鳴らすのは FileCommandStack の 1 箇所だけ**
    /// (Finder と同じ構造。経路が増えても鳴らし忘れ・二重再生が起きない ―― qooLibrary)。
    var completionSound: SystemSoundEffect? { get }
    func execute() async throws -> FileCommandResult
    func undo() async throws -> FileUndoResult
    /// 既定は `execute()` のやり直し(undo が完全に元へ戻したことが前提 ―― 部分的な取り消しは
    /// FileCommandStack が redo へ積まない)。
    func redo() async throws -> FileCommandResult
    /// 進捗の帯と中止ボタンを付けた取り消し(2026-09-14 の 2 回目の監査 12。以前の取り消し・やり直しは帯も中止も無く、
    /// 別ボリュームへの移動の取り消しは全量を黙って写し直した)。既定は `undo()`(一瞬で終わる操作)。
    func undo(in context: FileCommandContext) async throws -> FileUndoResult
    /// 同じくやり直し。**実行時の中止の旗を使い回さない**(中止した操作をやり直すと、立ったままの旗で何もせずに終わっていた)。
    /// 既定は `redo()`。
    func redo(in context: FileCommandContext) async throws -> FileCommandResult
}

/// 取り消し・やり直しのときに、そのとき出している進捗の帯へ繋ぐもの。
nonisolated struct FileCommandContext: Sendable {
    var progress: ProgressSink?
    var cancellation: Cancellation
    /// やり直しの衝突を尋ねる口(nil なら実行時のものを使う)。
    var conflictResolver: (@MainActor @Sendable (FileConflict) async -> ConflictDecision)?

    init(
        progress: ProgressSink? = nil, cancellation: Cancellation = Cancellation(),
        conflictResolver: (@MainActor @Sendable (FileConflict) async -> ConflictDecision)? = nil
    ) {
        self.progress = progress
        self.cancellation = cancellation
        self.conflictResolver = conflictResolver
    }

    /// 実行時の Options の進捗・中止・尋ねる口をこのときのものへ差し替える。
    func applied(to options: FileOperationOptions) -> FileOperationOptions {
        var options = options
        options.progress = progress
        options.cancellation = cancellation
        if let conflictResolver { options.conflictResolver = conflictResolver }
        return options
    }
}

extension FileCommand {
    func redo() async throws -> FileCommandResult {
        try await execute()
    }

    func undo(in context: FileCommandContext) async throws -> FileUndoResult {
        try await undo()
    }

    func redo(in context: FileCommandContext) async throws -> FileCommandResult {
        try await redo()
    }

    /// 既定は無音(名前の変更・新規フォルダは一瞬で終わり、結果がすぐ画面で分かる)。
    var completionSound: SystemSoundEffect? { nil }
}

nonisolated enum FileCommandResult: Sendable, Equatable {
    case success
    /// 一部だけ済んだ。`succeeded` が 0 でも、衝突のスキップや中止で「何も起きなかった」ことを伝えるために使う。
    case partial(succeeded: Int, failures: [FailedItem], wasCancelled: Bool)

    /// 取り消す対象が 1 つでもあるか(0 件なら積まない ―― 積むと ⌘Z が「戻すものがありません」になるだけ)。
    var hasEffect: Bool {
        switch self {
        case .success: true
        case let .partial(succeeded, _, _): succeeded > 0
        }
    }

    /// TransferOutcome を結果へ畳む。手を付けなかった項目も「処理されませんでした」として失敗の列に並べる
    /// (「29 件成功・1 件失敗」だけだと残り 70 件の行方が分からない)。
    static func from(_ outcome: TransferOutcome) -> FileCommandResult {
        guard !outcome.isCompleteSuccess || !outcome.skipped.isEmpty else { return .success }
        let notProcessed = String(localized: "Not processed.", language: AppLanguage.currentLocale)
        return .partial(
            succeeded: outcome.receipts.count,
            failures: outcome.failures + outcome.unprocessed.map { FailedItem(url: $0, reason: notProcessed) },
            wasCancelled: outcome.wasCancelled
        )
    }
}

nonisolated enum FileUndoResult: Sendable, Equatable {
    case complete
    case partial(succeeded: Int, failures: [FailedItem])
    /// 何も戻らなかった(ファイルは取り消しを試す前のまま)。
    /// - Parameter canRetry: 戻す相手はそのまま残っていて、原因(権限・応答しない共有・元の場所にできた同じ名前の項目)
    ///   を取り除けばもう一度試せる。FileCommandStack は履歴に残す。false は相手がもう無い・別の項目に変わった
    ///   など、試し直しても戻らないもの(履歴から外す ―― 残すと、その下の古い操作まで ⌘Z で届かなくなる)。
    case impossible(reason: String, canRetry: Bool = false)
}

/// 取り消し・やり直しの結果。**見せるのは呼び出し側(段階 4 の帯とアラート)**。
/// FileCommandStack の中で見せない理由: アラートは閉じるまで返らないのでテストが永久に返らなくなり、
/// 進捗の帯を片付ける前にダイアログが出てしまう(qooLibrary で踏んだ)。
nonisolated enum FileUndoOutcome: Sendable, Equatable {
    case nothingToDo
    case complete(operationName: String)
    case partial(operationName: String, succeeded: Int, failures: [FailedItem])
    /// - Parameter canRetry: 履歴に残したので、もう一度 ⌘Z(やり直しなら ⇧⌘Z)で試せる。
    case failed(operationName: String, reason: String, canRetry: Bool = false)

    /// 利用者に知らせる必要があるか(成功と空振りは黙っていてよい)。**「戻せなかった」は必ず見せる。**
    var needsAttention: Bool {
        switch self {
        case .nothingToDo, .complete: false
        case .partial, .failed: true
        }
    }
}

/// 複数の操作を 1 つの取り消し単位にする(D&D でコピーと移動が混ざる、「〈名前〉に展開」= フォルダを作る + 展開)。
@MainActor
final class CompositeFileCommand: FileCommand {
    let children: [any FileCommand]
    let displayName: String

    init(displayName: String, children: [any FileCommand]) {
        self.displayName = displayName
        self.children = children
    }

    var isUndoable: Bool { children.allSatisfy(\.isUndoable) }

    /// 子のうち最初に音を持つものを 1 つだけ(コピーと移動が混ざっても鳴るのは 1 回)。
    var completionSound: SystemSoundEffect? { children.lazy.compactMap(\.completionSound).first }

    /// 実行した(投げずに返った)子と、その子に取り消す対象があるか。取り消し・やり直しはこれだけを相手にする。
    private var executed: [(command: any FileCommand, hasEffect: Bool)] = []

    func execute() async throws -> FileCommandResult {
        try await runChildren { try await $0.execute() }
    }

    func redo(in context: FileCommandContext) async throws -> FileCommandResult {
        try await runChildren { try await $0.redo(in: context) }
    }

    private func runChildren(_ perform: (any FileCommand) async throws -> FileCommandResult) async throws -> FileCommandResult {
        executed = []
        var succeeded = 0
        var failures: [FailedItem] = []
        for (index, child) in children.enumerated() {
            let result: FileCommandResult
            do {
                result = try await perform(child)
            } catch {
                // **中止のときだけ、実行済みの子を巻き戻す**(「〈名前〉に展開」を止めたのに空のフォルダだけが
                // 残り、しかも投げたので Undo にも積まれず片付ける手立てが無かった。qooLibrary 実機検証)。
                // 失敗(容量不足など)では巻き戻さない ―― 5 個中 3 個目の失敗で、済んだ 2 個まで消えるのは驚きが大きい。
                if FileCommandStack.isCancellation(error) {
                    try await rollBack(executed)
                    throw error
                }
                // **済んだ子に効果があれば、投げずに「一部だけ済んだ」で返す**(2026-09-14 の 2 回目の監査 10)。以前はそのまま投げたので
                // FileCommandStack が積まず、済んだ移動を ⌘Z で戻せず、報告にも出なかった(投げた子は 1 件も動かしていない ――
                // 移動・コピーは 1 件も動かなかったときだけ投げる)。
                guard executed.contains(where: \.hasEffect) else { throw error }
                let notProcessed = String(localized: "Not processed.", language: AppLanguage.currentLocale)
                failures.append(FailedItem(name: child.displayName, reason: error.localizedDescription))
                failures += children[(index + 1)...].map { FailedItem(name: $0.displayName, reason: notProcessed) }
                return .partial(succeeded: succeeded, failures: failures, wasCancelled: false)
            }
            executed.append((child, result.hasEffect))
            switch result {
            case .success:
                succeeded += 1
            case let .partial(childSucceeded, childFailures, wasCancelled):
                if wasCancelled {
                    try await rollBack(executed)
                    throw CancellationError()
                }
                succeeded += childSucceeded > 0 ? 1 : 0
                failures += childFailures
            }
        }
        return failures.isEmpty ? .success : .partial(succeeded: succeeded, failures: failures, wasCancelled: false)
    }

    /// 子を逆順に取り消す。戻せなかった子は失敗として集める。
    /// **どの子も何も戻さず、どれも試し直せる**ときだけ「試し直せる取り消せなかった」を返す(1 つでも戻った子があれば
    /// 状態が割れているので、もう一度全体を取り消すと戻った子を二重に戻そうとする)。
    /// 取り消すのは**実行した子のうち効果のあったもの**だけ(途中で失敗して返したとき、動かなかった子の「戻すものがありません」を
    /// 失敗として並べない)。
    func undo() async throws -> FileUndoResult {
        try await undo(in: FileCommandContext())
    }

    func undo(in context: FileCommandContext) async throws -> FileUndoResult {
        var succeeded = 0
        var failures: [FailedItem] = []
        var changedAnything = false
        var allRetryable = true
        for child in executed.reversed().filter(\.hasEffect).map(\.command) {
            do {
                switch try await child.undo(in: context) {
                case .complete:
                    succeeded += 1
                    changedAnything = true
                case let .partial(childSucceeded, childFailures):
                    succeeded += childSucceeded
                    failures += childFailures
                    changedAnything = true
                case let .impossible(reason, canRetry):
                    failures.append(FailedItem(name: child.displayName, reason: reason))
                    allRetryable = allRetryable && canRetry
                }
            } catch {
                failures.append(FailedItem(name: child.displayName, reason: error.localizedDescription))
                allRetryable = false
            }
        }
        if failures.isEmpty { return .complete }
        if !changedAnything { return .impossible(reason: failures[0].reason, canRetry: allRetryable) }
        return .partial(succeeded: succeeded, failures: failures)
    }

    /// 中止のときの巻き戻し。**取り消せない子(元のフォルダへ書けない移動)は戻そうとしない** ―― 以前は `try?` で
    /// 試して黙って失敗し、運んだ項目が宛先に残ったのに何も言わなかった(計画 §4.14)。戻せなかったものは
    /// `CompositeRollbackError` で伝える(中止ではなく問題として見せる)。
    private func rollBack(_ executed: [(command: any FileCommand, hasEffect: Bool)]) async throws {
        let locale = AppLanguage.currentLocale
        var failures: [FailedItem] = []
        for done in executed.reversed() {
            guard done.command.isUndoable else {
                if done.hasEffect {
                    failures.append(FailedItem(
                        name: done.command.displayName,
                        reason: String(localized: "This part can’t be undone, so it was left as it is.", language: locale)
                    ))
                }
                continue
            }
            // 何も済まなかった子も取り消しを呼ぶ(0 件と数えても、途中まで作ったものを片付ける子がありうる ――
            // 段階 6 の展開)。ただし戻すものが無いのは当然なので、その子の「戻せなかった」は数えない。
            let result: FileUndoResult
            do {
                result = try await done.command.undo()
            } catch {
                if done.hasEffect { failures.append(FailedItem(name: done.command.displayName, reason: error.localizedDescription)) }
                continue
            }
            guard done.hasEffect else { continue }
            switch result {
            case .complete:
                break
            case let .partial(_, childFailures):
                failures += childFailures
            case let .impossible(reason, _):
                failures.append(FailedItem(name: done.command.displayName, reason: reason))
            }
        }
        if !failures.isEmpty { throw CompositeRollbackError(operationName: displayName, failures: failures) }
    }
}

/// まとめた操作を中止したが、済んだ子を戻しきれなかった。**中止ではなく問題として見せる**(運んだ項目が宛先に残っている)。
nonisolated struct CompositeRollbackError: Error, Equatable, LocalizedError {
    let operationName: String
    let failures: [FailedItem]

    var errorDescription: String? {
        String(
            format: String(localized: "%@ was stopped, but some items couldn’t be put back.", language: AppLanguage.currentLocale),
            operationName
        )
    }
}

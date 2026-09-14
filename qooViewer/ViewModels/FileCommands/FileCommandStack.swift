import Combine
import Foundation

/// ファイルブラウザの取り消し・やり直しの積み場所(改善要望7 段階 2、2026-09-13。qooLibrary の `CommandStack` を写したもの)。
///
/// **ウインドウごとに 1 つ**(段階 3 の FileBrowserState が持つ)。qooLibrary はアプリ全体で 1 つだったが、
/// qooViewer の編集メニューはフォーカスのあるウインドウの `FocusedValue` から題を引く形(AppState と同じ)なので、
/// ウインドウの外の操作が ⌘Z で戻ると何が戻ったのか見えない。
@MainActor
final class FileCommandStack: ObservableObject {
    /// 積む深さ。超えたら古いものから捨てる。
    static let depth = 50

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var undoTitle: String?
    @Published private(set) var redoTitle: String?

    private var undoStack: [any FileCommand] = [] {
        didSet { publish() }
    }

    private var redoStack: [any FileCommand] = [] {
        didSet { publish() }
    }

    private let soundPlayer: any SystemSoundPlaying

    init(soundPlayer: any SystemSoundPlaying = SystemSoundPlayer.shared) {
        self.soundPlayer = soundPlayer
    }

    /// 実行して積む。新しい操作をしたら redo は捨てる(分岐した「やり直し」先は残さない)。
    ///
    /// 投げた(1 件も動かなかった)ときは積まない。部分的に済んだときは積む ―― 動いた分を ⌘Z で戻せるように
    /// (捨てると、動いたファイルを戻す手段が無くなる)。
    @discardableResult
    func run(_ command: any FileCommand) async throws -> FileCommandResult {
        let result: FileCommandResult
        do {
            result = try await command.execute()
        } catch let error as CompositeRollbackError {
            // 中止したが済んだ子を戻しきれなかった ―― ファイルは変わっているので、古いやり直し先は捨てる(2026-09-15 の 3 回目の監査)。
            redoStack.removeAll()
            throw error
        }
        await playCompletionSound(for: command, result: result)
        if result.hasEffect {
            // **取り消せない操作でも、効果があればやり直し先は捨てる**(2026-09-14 の 2 回目の監査。以前は積まない操作では残したので、
            // すぐに削除・取り消せない移動の後の ⇧⌘Z が、変わった後のファイルに古い操作をもう一度走らせた)。
            redoStack.removeAll()
            if command.isUndoable {
                undoStack.append(command)
                if undoStack.count > Self.depth { undoStack.removeFirst() }
            }
        }
        return result
    }

    /// 次に取り消す操作・やり直す操作(⌘Z を押した時点のものを控える。`undo(in:expecting:)`)。
    var nextUndo: (any FileCommand)? { undoStack.last }
    var nextRedo: (any FileCommand)? { redoStack.last }

    /// - Parameter expected: **押した時点の一番上**。一番上がそれでなくなっていたら何もしない(2026-09-14 の 2 回目の監査 11)。
    ///   走っている操作の最中に押した ⌘Z は列の後ろに並ぶので、以前は操作が終わった直後に**その操作を**戻していた
    ///   (利用者が戻したかったのは、押したときにメニューに出ていた前の操作)。nil なら控えずに一番上を戻す。
    func undo(in context: FileCommandContext = FileCommandContext(), expecting expected: (any FileCommand)? = nil) async -> FileUndoOutcome {
        if let expected, nextUndo !== expected { return .nothingToDo }
        guard let command = undoStack.popLast() else { return .nothingToDo }
        do {
            switch try await command.undo(in: context) {
            case .complete:
                redoStack.append(command)
                return .complete(operationName: command.displayName)
            case let .partial(succeeded, failures):
                // **redo へ積まない。** 一部しか戻っていない状態でやり直すと、元の項目で execute し直して
                // 「移動元がありません」になる(qooLibrary で監査により発見)。取り消しもやり直しも正しく
                // 再現できないので、スタックから外す。
                return .partial(operationName: command.displayName, succeeded: succeeded, failures: failures)
            case let .impossible(reason, canRetry):
                // **試し直せるなら履歴へ戻す**(2026-09-14、計画 §4.12 の「取り消しに失敗した操作は履歴から消える」)。
                // 権限や応答しない共有のように、原因を取り除けば戻せるのに、以前は 1 回の失敗で戻す手段が無くなった。
                // 何も戻っていない(impossible の約束)ので、同じ取り消しをもう一度走らせても二重には戻らない。
                // 試し直しても直らないもの(相手が消えた・別の項目に変わった)は外す ―― 残すと、その下の古い操作まで
                // ⌘Z で届かなくなる。
                if canRetry { undoStack.append(command) }
                return .failed(operationName: command.displayName, reason: reason, canRetry: canRetry)
            case let .stopped(_, failures):
                // 中止で止めた。コマンドは戻した分を外してあるので、残りを取り消せるよう履歴へ戻す(2026-09-15 の 3 回目の監査)。
                undoStack.append(command)
                return .cancelled(operationName: command.displayName, failures: failures)
            }
        } catch {
            return .failed(operationName: command.displayName, reason: error.localizedDescription)
        }
    }

    func redo(in context: FileCommandContext = FileCommandContext(), expecting expected: (any FileCommand)? = nil) async -> FileUndoOutcome {
        if let expected, nextRedo !== expected { return .nothingToDo }
        guard let command = redoStack.popLast() else { return .nothingToDo }
        do {
            let result = try await command.redo(in: context)
            await playCompletionSound(for: command, result: result)
            // **効果があったときだけ取り消しの履歴へ**(2026-09-15 の 3 回目の監査。以前は中止で 0 件でも積み、⌘Z が「取り消すものが
            // ありません」になった)。何も起きずに中止したなら、もう一度やり直せるようやり直しの履歴へ戻す。
            if result.hasEffect {
                undoStack.append(command)
            } else if case .partial(_, _, true) = result {
                redoStack.append(command)
            }
            switch result {
            case .success:
                return .complete(operationName: command.displayName)
            case let .partial(_, failures, true):
                // 利用者の中止は「一部だけやり直した」として見せない(手を付けなかった項目は並べない)。
                return .cancelled(operationName: command.displayName, failures: failures.filter { $0.reason != Self.notProcessedReason })
            case let .partial(succeeded, failures, false):
                return .partial(operationName: command.displayName, succeeded: succeeded, failures: failures)
            }
        } catch {
            if Self.isCancellation(error) {
                // 投げた中止は何も残していない(まとめた操作は巻き戻してから投げる)。もう一度やり直せる。
                redoStack.append(command)
                return .cancelled(operationName: command.displayName, failures: [])
            }
            return .failed(operationName: command.displayName, reason: error.localizedDescription)
        }
    }

    /// 利用者自身の中止か(失敗として見せない)。ゴミ箱の無い場所で `NSWorkspace.recycle` が出す OS の確認を
    /// キャンセルすると `NSUserCancelledError` が返る(qooLibrary 実測)ので、それも含める。
    /// `FileCommandResult.from` が手を付けなかった項目に付ける理由。
    nonisolated static var notProcessedReason: String {
        String(localized: "Not processed.", language: AppLanguage.currentLocale)
    }

    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    /// 済んだ音。**完全に済んだときだけ**(部分的な成功・中止では鳴らさない ―― Finder も鳴らす前に
    /// エラーの有無を見ている)。**取り消しでは鳴らさない**: 音は「その操作が起きた」ことに付くもので、
    /// ⌘Z でゴミ箱の音が鳴るのは意味が逆。やり直しは操作をもう一度起こすので鳴らす(qooLibrary と同じ判断)。
    /// 積まない操作(完全削除)でも鳴らす。
    private func playCompletionSound(for command: any FileCommand, result: FileCommandResult) async {
        guard case .success = result, let effect = command.completionSound else { return }
        await soundPlayer.play(effect)
    }

    private func publish() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        undoTitle = undoStack.last?.displayName
        redoTitle = redoStack.last?.displayName
    }
}

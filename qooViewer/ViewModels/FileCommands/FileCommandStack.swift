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

    /// 実行して積む。新しい操作をしたら redo は捨てる(分岐した「やり直し」先は残さない)。
    ///
    /// 投げた(1 件も動かなかった)ときは積まない。部分的に済んだときは積む ―― 動いた分を ⌘Z で戻せるように
    /// (捨てると、動いたファイルを戻す手段が無くなる)。
    @discardableResult
    func run(_ command: any FileCommand) async throws -> FileCommandResult {
        let result = try await command.execute()
        if command.isUndoable, result.hasEffect {
            undoStack.append(command)
            if undoStack.count > Self.depth { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        return result
    }

    func undo() async -> FileUndoOutcome {
        guard let command = undoStack.popLast() else { return .nothingToDo }
        do {
            switch try await command.undo() {
            case .complete:
                redoStack.append(command)
                return .complete(operationName: command.displayName)
            case let .partial(succeeded, failures):
                // **redo へ積まない。** 一部しか戻っていない状態でやり直すと、元の項目で execute し直して
                // 「移動元がありません」になる(qooLibrary で監査により発見)。取り消しもやり直しも正しく
                // 再現できないので、スタックから外す。
                return .partial(operationName: command.displayName, succeeded: succeeded, failures: failures)
            case let .impossible(reason):
                // 戻さない(同じ取り消しを試し直しても直らない)。
                return .failed(operationName: command.displayName, reason: reason)
            }
        } catch {
            return .failed(operationName: command.displayName, reason: error.localizedDescription)
        }
    }

    func redo() async -> FileUndoOutcome {
        guard let command = redoStack.popLast() else { return .nothingToDo }
        do {
            let result = try await command.redo()
            undoStack.append(command)
            switch result {
            case .success:
                return .complete(operationName: command.displayName)
            case let .partial(succeeded, failures, _):
                return .partial(operationName: command.displayName, succeeded: succeeded, failures: failures)
            }
        } catch {
            return .failed(operationName: command.displayName, reason: error.localizedDescription)
        }
    }

    /// 利用者自身の中止か(失敗として見せない)。ゴミ箱の無い場所で `NSWorkspace.recycle` が出す OS の確認を
    /// キャンセルすると `NSUserCancelledError` が返る(qooLibrary 実測)ので、それも含める。
    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    private func publish() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        undoTitle = undoStack.last?.displayName
        redoTitle = redoStack.last?.displayName
    }
}

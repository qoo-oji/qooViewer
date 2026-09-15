import Foundation
import Testing

@testable import qooViewer

/// 取り消し・やり直しの積み場所(ViewModels/FileCommands/FileCommandStack.swift)の規則。
/// ファイルに触らない偽のコマンドで確かめる。
@MainActor
struct FileCommandStackTests {
    /// 実行・取り消しの結果を決めておける偽のコマンド。
    final class ScriptedCommand: FileCommand {
        let displayName: String
        var isUndoable = true
        var executeResult: FileCommandResult = .success
        var executeError: (any Error)?
        var undoResult: FileUndoResult = .complete
        private(set) var executions = 0
        private(set) var undos = 0

        init(_ name: String) {
            displayName = name
        }

        func execute() async throws -> FileCommandResult {
            executions += 1
            if let executeError { throw executeError }
            return executeResult
        }

        func undo() async throws -> FileUndoResult {
            undos += 1
            return undoResult
        }
    }

    @Test("実行したものを積み、取り消すと redo へ移り、新しい実行で redo は消える")
    func basicUndoRedo() async throws {
        let stack = FileCommandStack()
        let first = ScriptedCommand("first")
        try await stack.run(first)
        #expect(stack.canUndo && !stack.canRedo)
        #expect(stack.undoTitle == "first")

        #expect(await stack.undo() == .complete(operationName: "first"))
        #expect(!stack.canUndo && stack.canRedo)
        #expect(stack.redoTitle == "first")

        #expect(await stack.redo() == .complete(operationName: "first"))
        #expect(first.executions == 2)

        _ = await stack.undo()
        try await stack.run(ScriptedCommand("second"))
        #expect(!stack.canRedo, "新しい操作をしたら、分岐したやり直し先は残さない")
        #expect(stack.undoTitle == "second")
    }

    @Test("途中で止めた取り消しは履歴に残り、続きを取り消せる。やり直しの中止は、何も起きなければやり直しの履歴へ戻る")
    func stoppedUndoAndCancelledRedoStayInHistory() async throws {
        // 3 回目の監査 3・4。
        let stack = FileCommandStack()
        let command = ScriptedCommand("stopped")
        command.undoResult = .stopped(succeeded: 1, failures: [])
        try await stack.run(command)
        #expect(await stack.undo() == .cancelled(operationName: "stopped", failures: []))
        #expect(stack.canUndo && !stack.canRedo)
        #expect(!FileUndoOutcome.cancelled(operationName: "stopped", failures: []).needsAttention)

        command.undoResult = .complete
        #expect(await stack.undo() == .complete(operationName: "stopped"))
        command.executeResult = .partial(succeeded: 0, failures: [], wasCancelled: true)
        #expect(await stack.redo() == .cancelled(operationName: "stopped", failures: []))
        #expect(!stack.canUndo, "何も起きなかったやり直しは取り消しの履歴へ積まない")
        #expect(stack.canRedo)
        command.executeError = CancellationError()
        #expect(await stack.redo() == .cancelled(operationName: "stopped", failures: []))
        #expect(stack.canRedo)
    }

    @Test("深さは 50。超えたら古いものから捨てる")
    func depthIsLimited() async throws {
        let stack = FileCommandStack()
        for index in 0..<(FileCommandStack.depth + 5) {
            try await stack.run(ScriptedCommand("c\(index)"))
        }
        var undone = 0
        while case .complete = await stack.undo() { undone += 1 }
        #expect(undone == FileCommandStack.depth)
    }

    @Test("部分的にしか戻せなかった取り消しは redo へ積まない")
    func partialUndoIsNotRedoable() async throws {
        let stack = FileCommandStack()
        let command = ScriptedCommand("partial")
        command.undoResult = .partial(succeeded: 1, failures: [FailedItem(name: "x", reason: "r")])
        try await stack.run(command)
        let outcome = await stack.undo()
        #expect(outcome.needsAttention)
        #expect(!stack.canRedo)
        #expect(!stack.canUndo)
    }

    @Test("取り消せなかったら「戻せなかった」を返し、どちらにも積まない")
    func impossibleUndoIsReported() async throws {
        let stack = FileCommandStack()
        let command = ScriptedCommand("impossible")
        command.undoResult = .impossible(reason: "gone")
        try await stack.run(command)
        #expect(await stack.undo() == .failed(operationName: "impossible", reason: "gone"))
        #expect(!stack.canUndo && !stack.canRedo)
    }

    @Test("試し直せる「取り消せなかった」は履歴に残し、もう一度取り消せる")
    func retryableImpossibleUndoStays() async throws {
        let stack = FileCommandStack()
        let command = ScriptedCommand("retry")
        command.undoResult = .impossible(reason: "denied", canRetry: true)
        try await stack.run(command)
        #expect(await stack.undo() == .failed(operationName: "retry", reason: "denied", canRetry: true))
        #expect(stack.canUndo && !stack.canRedo)
        #expect(stack.undoTitle == "retry")

        command.undoResult = .complete
        #expect(await stack.undo() == .complete(operationName: "retry"))
        #expect(!stack.canUndo && stack.canRedo)
    }

    @Test("まとめた操作の取り消しで、どの子も戻らずどれも試し直せるなら、全体も試し直せる")
    func compositeUndoRetryability() async throws {
        let first = ScriptedCommand("a")
        let second = ScriptedCommand("b")
        first.undoResult = .impossible(reason: "x", canRetry: true)
        second.undoResult = .impossible(reason: "y", canRetry: true)
        let composite = CompositeFileCommand(displayName: "both", children: [first, second])
        // 取り消すのは実行して効果のあった子だけ。
        _ = try await composite.execute()
        guard case .impossible(_, true) = try await composite.undo() else {
            Issue.record("試し直せるにならなかった")
            return
        }
        second.undoResult = .complete
        guard case .partial = try await composite.undo() else {
            Issue.record("一部戻ったのに部分的にならなかった")
            return
        }
    }

    @Test("まとめた操作の中止で、取り消せない子は戻そうとせず、戻せなかったと投げる")
    func compositeRollbackReportsIrreversibleChildren() async throws {
        let first = ScriptedCommand("move")
        first.isUndoable = false
        let second = ScriptedCommand("copy")
        second.executeResult = .partial(succeeded: 0, failures: [], wasCancelled: true)
        let composite = CompositeFileCommand(displayName: "both", children: [first, second])
        await #expect(throws: CompositeRollbackError.self) { _ = try await composite.execute() }
        #expect(first.undos == 0)
        #expect(second.undos == 1)
    }

    @Test("取り消せない操作でも、効果があればやり直し先は捨てる(2 回目の監査)")
    func irreversibleOperationsClearRedo() async throws {
        let stack = FileCommandStack()
        try await stack.run(ScriptedCommand("first"))
        _ = await stack.undo()
        #expect(stack.canRedo)
        let nothing = ScriptedCommand("nothing")
        nothing.isUndoable = false
        nothing.executeResult = .partial(succeeded: 0, failures: [], wasCancelled: true)
        try await stack.run(nothing)
        #expect(stack.canRedo, "何も起きなかった操作では残す")
        let permanent = ScriptedCommand("permanent")
        permanent.isUndoable = false
        try await stack.run(permanent)
        #expect(!stack.canRedo && !stack.canUndo)
    }

    @Test("投げた実行・何も起きなかった実行・取り消せない操作は積まない")
    func unrecordableRunsAreNotStacked() async throws {
        let stack = FileCommandStack()
        let failing = ScriptedCommand("failing")
        failing.executeError = CocoaError(.fileWriteNoPermission)
        await #expect(throws: CocoaError.self) { try await stack.run(failing) }

        let nothing = ScriptedCommand("nothing")
        nothing.executeResult = .partial(succeeded: 0, failures: [], wasCancelled: true)
        try await stack.run(nothing)

        let permanent = ScriptedCommand("permanent")
        permanent.isUndoable = false
        try await stack.run(permanent)

        #expect(!stack.canUndo)
        #expect(await stack.undo() == .nothingToDo)
    }

    @Test("まとめた操作は、子が中止されたら済んだ子を巻き戻して投げる")
    func compositeRollsBackOnCancellation() async throws {
        let first = ScriptedCommand("create")
        let second = ScriptedCommand("extract")
        second.executeResult = .partial(succeeded: 0, failures: [], wasCancelled: true)
        let composite = CompositeFileCommand(displayName: "both", children: [first, second])
        await #expect(throws: CancellationError.self) { _ = try await composite.execute() }
        #expect(first.undos == 1)
        #expect(second.undos == 1)
    }

    @Test("まとめた操作は、失敗(中止ではない)では巻き戻さず、済んだ子があれば「一部だけ済んだ」で返して積む。取り消しは済んだ子だけ")
    func compositeDoesNotRollBackOnFailure() async throws {
        // 2 回目の監査 10: 以前は投げたので積まれず、済んだ子(移動など)を ⌘Z で戻せず報告にも出なかった。
        let stack = FileCommandStack()
        let first = ScriptedCommand("create")
        let second = ScriptedCommand("extract")
        let third = ScriptedCommand("later")
        second.executeError = CocoaError(.fileWriteOutOfSpace)
        let composite = CompositeFileCommand(displayName: "all", children: [first, second, third])
        guard case let .partial(succeeded, failures, wasCancelled) = try await stack.run(composite) else {
            Issue.record("一部だけ済んだにならなかった")
            return
        }
        #expect(succeeded == 1 && !wasCancelled)
        #expect(failures.map(\.name) == ["extract", "later"])
        #expect(first.undos == 0 && third.executions == 0)
        #expect(stack.undoTitle == "all")

        #expect(await stack.undo() == .complete(operationName: "all"))
        #expect(first.undos == 1 && second.undos == 0 && third.undos == 0, "動かなかった子の「戻すものがありません」を並べない")

        // 最初の子が投げたなら、戻すものが無いので今までどおり投げる。
        let failing = ScriptedCommand("failing")
        failing.executeError = CocoaError(.fileWriteOutOfSpace)
        await #expect(throws: CocoaError.self) {
            _ = try await CompositeFileCommand(displayName: "none", children: [failing, ScriptedCommand("x")]).execute()
        }
    }

    @Test("押した時点の一番上でなくなっていたら、取り消し・やり直しは何もしない")
    func undoAndRedoOnlyActOnTheExpectedCommand() async throws {
        let stack = FileCommandStack()
        let first = ScriptedCommand("first")
        let second = ScriptedCommand("second")
        try await stack.run(first)
        let expected = try #require(stack.nextUndo)
        try await stack.run(second)
        #expect(await stack.undo(expecting: expected) == .nothingToDo)
        #expect(first.undos == 0 && second.undos == 0)

        #expect(await stack.undo(expecting: second) == .complete(operationName: "second"))
        let redoExpected = try #require(stack.nextRedo)
        try await stack.run(ScriptedCommand("third"))
        #expect(await stack.redo(expecting: redoExpected) == .nothingToDo)
    }
}

/// 実際のファイルを動かすコマンドの取り消し(ViewModels/FileCommands/FileCommands.swift)。
@MainActor
struct FileCommandsTests {
    private let temporary: TemporaryDirectory
    private let fileOps: FileOperationService

    init() throws {
        temporary = try TemporaryDirectory("file-commands")
        fileOps = FileOperationService(environment: .pseudoTrash(at: try temporary.directory("PseudoTrash")))
    }

    private func write(_ text: String, to relativePath: String) throws -> URL {
        let url = temporary.file(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test("移動を取り消すと元の場所へ戻り、やり直すともう一度動く")
    func moveUndoRedo() async throws {
        let file = try write("x", to: "src/a.txt")
        let destination = try temporary.directory("dst")
        let stack = FileCommandStack()
        let command = MoveFilesCommand(items: [file], destination: destination, options: .init(conflictPolicy: .ask), fileOps: fileOps)
        #expect(try await stack.run(command) == .success)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path))

        #expect(await stack.undo() == .complete(operationName: command.displayName))
        #expect(FileManager.default.fileExists(atPath: file.path))

        #expect(await stack.redo() == .complete(operationName: command.displayName))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("移動の取り消しで元の場所に同名の項目ができていたら、壊さず name 2 で戻して「部分的」と伝える")
    func moveUndoKeepsBothWhenTheOriginalPlaceIsTaken() async throws {
        let file = try write("moved", to: "src2/a.txt")
        let destination = try temporary.directory("dst2")
        let command = MoveFilesCommand(items: [file], destination: destination, options: .init(conflictPolicy: .ask), fileOps: fileOps)
        _ = try await command.execute()
        _ = try write("newcomer", to: "src2/a.txt")
        guard case let .partial(succeeded, failures) = try await command.undo() else {
            Issue.record("部分的な取り消しにならなかった")
            return
        }
        #expect(succeeded == 0)
        #expect(failures.count == 1)
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == "newcomer")
        #expect(FileManager.default.fileExists(atPath: temporary.file("src2/a 2.txt").path))
    }

    @Test("置き換えた移動を取り消すと、置き換えられた元の項目もゴミ箱から戻る")
    func replaceMoveUndoRestoresTheReplacedItem() async throws {
        let file = try write("new", to: "src3/a.txt")
        let old = try write("old", to: "dst3/a.txt")
        let command = MoveFilesCommand(
            items: [file], destination: old.deletingLastPathComponent(), options: .init(conflictPolicy: .replace), fileOps: fileOps
        )
        _ = try await command.execute()
        #expect(try await command.undo() == .complete)
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == "new")
        #expect(String(decoding: try Data(contentsOf: old), as: UTF8.self) == "old")
    }

    @Test("コピーを取り消すと作ったものがゴミ箱へ行き、元は残る")
    func copyUndoTrashesTheCopies() async throws {
        let file = try write("x", to: "copy-src/a.txt")
        let destination = try temporary.directory("copy-dst")
        let command = CopyFilesCommand(items: [file], destination: destination, options: .init(conflictPolicy: .ask), fileOps: fileOps)
        _ = try await command.execute()
        #expect(try await command.undo() == .complete)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test("名前の変更とゴミ箱は取り消せる")
    func renameAndTrashUndo() async throws {
        let file = try write("x", to: "misc/a.txt")
        let rename = RenameFileCommand(item: file, newName: "b.txt", fileOps: fileOps)
        _ = try await rename.execute()
        #expect(try await rename.undo() == .complete)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let trash = TrashFilesCommand(items: [file], fileOps: fileOps)
        #expect(try await trash.execute() == .success)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try await trash.undo() == .complete)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("コピーの取り消しは、作ったものが同じ名前の別の項目に変わっていたら触らない")
    func copyUndoLeavesReplacedItems() async throws {
        let file = try write("x", to: "identity-src/a.txt")
        let destination = try temporary.directory("identity-dst")
        let command = CopyFilesCommand(items: [file], destination: destination, options: .init(conflictPolicy: .ask), fileOps: fileOps)
        _ = try await command.execute()
        let copy = destination.appendingPathComponent("a.txt")
        try FileManager.default.removeItem(at: copy)
        try Data("stranger".utf8).write(to: copy)
        guard case .impossible(_, false) = try await command.undo() else {
            Issue.record("別の項目に変わったのに取り消そうとした")
            return
        }
        #expect(String(decoding: try Data(contentsOf: copy), as: UTF8.self) == "stranger")
    }

    @Test("名前の変更の取り消しは、元の名前が埋まっていれば試し直せる")
    func renameUndoIsRetryableWhenTheNameIsTaken() async throws {
        let file = try write("x", to: "rename-retry/a.txt")
        let rename = RenameFileCommand(item: file, newName: "b.txt", fileOps: fileOps)
        _ = try await rename.execute()
        try Data("newcomer".utf8).write(to: file)
        guard case .impossible(_, true) = try await rename.undo() else {
            Issue.record("試し直せるにならなかった")
            return
        }
        try FileManager.default.removeItem(at: file)
        #expect(try await rename.undo() == .complete)
    }

    @Test("一括リネームは 1 件が失敗しても残りを変え、取り消しは変えた分だけ戻す。末尾の空白も名前のまま残す")
    func bulkRenameContinuesPastFailures() async throws {
        let first = try write("1", to: "bulk/a.txt")
        let second = try write("2", to: "bulk/b.txt")
        let third = try write("3", to: "bulk/c.txt")
        // 計画した後に、2 件目の行き先が外で作られた。
        _ = try write("stranger", to: "bulk/2ファイル .txt")
        let command = BulkRenameFileCommand(
            renames: [(first, "1ファイル .txt"), (second, "2ファイル .txt"), (third, "3ファイル ")], fileOps: fileOps
        )
        guard case let .partial(succeeded, failures, wasCancelled) = try await command.execute() else {
            Issue.record("失敗が報告されなかった")
            return
        }
        #expect(succeeded == 2 && failures.compactMap(\.url) == [second] && !wasCancelled)
        let folder = first.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("3ファイル ").path))

        #expect(try await command.undo() == .complete)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["a.txt", "b.txt", "c.txt", "2ファイル .txt"])
    }

    @Test("一括リネームの中止は項目の境目で止まり、取り消しは同じ名前の別の項目に触らない")
    func bulkRenameStopsAndUndoChecksIdentity() async throws {
        let first = try write("1", to: "bulk-stop/a.txt")
        let second = try write("2", to: "bulk-stop/b.txt")
        let cancellation = Cancellation()
        let sink = ProgressSink { progress in
            // 2 件目に取りかかる前に中止ボタンが押された。
            if progress.completedItems == 1 { cancellation.request() }
        }
        let command = BulkRenameFileCommand(
            renames: [(first, "x.txt"), (second, "y.txt")], progress: sink, cancellation: cancellation, fileOps: fileOps
        )
        guard case .partial(1, _, true) = try await command.execute() else {
            Issue.record("中止で止まらなかった")
            return
        }
        let folder = first.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: second.path))

        let renamed = folder.appendingPathComponent("x.txt")
        try FileManager.default.removeItem(at: renamed)
        try Data("stranger".utf8).write(to: renamed)
        guard case .impossible(_, false) = try await command.undo() else {
            Issue.record("別の項目に変わったのに取り消そうとした")
            return
        }
        #expect(FileManager.default.fileExists(atPath: renamed.path))
    }

    @Test("ゴミ箱の無い場所への操作の取り消しは、試し直せる扱いにしない(履歴の一番上に居座らない)")
    func undoWhereThereIsNoTrashIsNotRetryable() async throws {
        // 2 回目の監査 13: 以前は trashUnavailable でも canRetry のまま履歴に残り、その下の操作へ ⌘Z が届かなかった。
        let noTrash = FileOperationService(environment: .pseudoTrash(at: try temporary.directory("NoTrash"), hasTrash: { _ in false }))
        let file = try write("x", to: "no-trash-undo/a.txt")
        let destination = try temporary.directory("no-trash-undo/dst")
        let stack = FileCommandStack()
        try await stack.run(olderFolder(url: temporary.file("no-trash-undo/older"), fileOps: noTrash))
        let copy = CopyFilesCommand(items: [file], destination: destination, options: .init(conflictPolicy: .ask), fileOps: noTrash)
        try await stack.run(copy)

        guard case .failed(_, _, false) = await stack.undo() else {
            Issue.record("試し直せる扱いになった")
            return
        }
        #expect(stack.undoTitle == String(localized: "New Folder", language: AppLanguage.currentLocale), "下の操作が一番上に出る")
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path), "黙って完全に削除しない")
    }

    @Test("移動の取り消しは中止でき、何も戻っていなければ試し直せる。やり直しは実行時の中止の旗を使い回さない")
    func moveUndoCanBeCancelledAndRedoUsesAFreshCancellation() async throws {
        let file = try write("x", to: "undo-cancel/src/a.txt")
        let destination = try temporary.directory("undo-cancel/dst")
        let original = Cancellation()
        let command = MoveFilesCommand(
            items: [file], destination: destination, options: .init(conflictPolicy: .ask, cancellation: original), fileOps: fileOps
        )
        _ = try await command.execute()

        let stopped = Cancellation()
        stopped.request()
        guard case .stopped(0, []) = try await command.undo(in: FileCommandContext(cancellation: stopped)) else {
            Issue.record("中止した取り消しが「止めた」にならなかった")
            return
        }
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path))

        #expect(try await command.undo() == .complete)
        #expect(FileManager.default.fileExists(atPath: file.path))
        // 実行時の操作が後から中止された(帯の中止ボタン)ことにする。やり直しはこのときの旗を使う。
        original.request()
        #expect(try await command.redo(in: FileCommandContext()) == .success)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("移動の取り消しを途中で止めると、戻した分を外し、続きを取り消せる(最後に戻した項目を「中止」と数えない)")
    func stoppedMoveUndoKeepsTheRestUndoable() async throws {
        // 3 回目の監査 2・3: 1 件を戻し終えた直後に中止ボタンが押された形(進捗の「1 件済んだ」で旗を立てる)。
        let a = try write("a", to: "undo-stop/src/a.txt")
        let b = try write("b", to: "undo-stop/src/b.txt")
        let c = try write("c", to: "undo-stop/src/c.txt")
        let destination = try temporary.directory("undo-stop/dst")
        let command = MoveFilesCommand(items: [a, b, c], destination: destination, options: .init(conflictPolicy: .ask), fileOps: fileOps)
        _ = try await command.execute()

        let cancellation = Cancellation()
        let sink = ProgressSink { progress in
            if progress.completedItems >= 1 { cancellation.request() }
        }
        let result = try await command.undo(in: FileCommandContext(progress: sink, cancellation: cancellation))
        #expect(result == .stopped(succeeded: 1, failures: []))
        #expect(FileManager.default.fileExists(atPath: c.path), "後に運んだものから戻す")
        #expect(command.outcome.receipts.map(\.source) == [a, b])
        // 題は残りの件数で名乗る(実機検証: 「4000 項目の移動を取り消す」のままだった)。
        let locale = AppLanguage.currentLocale
        #expect(command.displayName == String(format: String(localized: "Move of %lld Items", language: locale), 2))

        #expect(try await command.undo() == .complete)
        #expect(command.displayName == String(format: String(localized: "Move of %lld Items", language: locale), 3), "戻し終えたら、やり直す全部の件数へ戻る")
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    }

    @Test("移動の取り消しは元のフォルダごとにまとめて戻し、進み具合は全体の件数で出す。消えた項目・同じ名前ができた項目があっても残りは戻る")
    func moveUndoPutsBackPerFolderInOneBatch() async throws {
        // 3 回目の監査の実機検証: 以前は 1 件ずつ移動を呼び、帯が「全 1 件」を 1 件ごとに出し直した。
        let first = try (0..<5).map { try write("a\($0)", to: "undo-batch/one/a\($0).txt") }
        let second = try (0..<3).map { try write("b\($0)", to: "undo-batch/two/b\($0).txt") }
        let destination = try temporary.directory("undo-batch/dst")
        let command = MoveFilesCommand(
            items: first + second, destination: destination, options: .init(conflictPolicy: .ask), fileOps: fileOps
        )
        #expect(try await command.execute() == .success)
        // 1 件は運んだ先で消え、1 件は元の場所に同じ名前ができた。
        try FileManager.default.removeItem(at: destination.appendingPathComponent("a1.txt"))
        _ = try write("other", to: "undo-batch/two/b2.txt")

        let reports = ReportLog()
        let sink = ProgressSink { reports.append($0) }
        guard case let .partial(succeeded, failures) = try await command.undo(in: FileCommandContext(progress: sink)) else {
            Issue.record("一部だけ戻したにならなかった")
            return
        }
        #expect(succeeded == 6)
        #expect(failures.count == 2)
        for (index, url) in first.enumerated() where index != 1 {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(FileManager.default.fileExists(atPath: second[0].path) && FileManager.default.fileExists(atPath: second[1].path))
        #expect(String(decoding: try Data(contentsOf: second[2]), as: UTF8.self) == "other")
        #expect(FileManager.default.fileExists(atPath: second[2].deletingLastPathComponent().appendingPathComponent("b2 2.txt").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        // 組が 2 つなので、件数は全体(戻す 7 件)で数える。
        #expect(reports.values.allSatisfy { $0.totalItems == 7 })
        #expect(reports.values.map(\.completedItems).max() == 7)
    }

    @Test("まとめた取り消しが事前検査で断られたら、半分ずつに割って運び、残り全体での呼び直しを繰り返さない")
    @MainActor
    func moveUndoSplitsARefusedBatchInsteadOfRetryingTheWholeRest() async throws {
        // 4 回目の監査 2: 以前は先頭 1 件を試してから残り全体で呼び直したので、空き容量の不足のように「まとまり全体」で決まる断りでは
        // 1 件ごとに残り全部の事前検査(木の走査)をやり直し、項目数の 2 乗になった。
        let count = 64
        let originals = (0..<count).map { temporary.file("undo-split/src/f\($0).txt") }
        try FileManager.default.createDirectory(at: originals[0].deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try temporary.directory("undo-split/dst")
        var receipts: [TransferReceipt] = []
        for original in originals {
            let placed = destination.appendingPathComponent(original.lastPathComponent)
            try Data("x".utf8).write(to: placed)
            receipts.append(TransferReceipt(source: original, destination: placed, replacedItemInTrash: nil, identity: FileIdentity.of(placed)))
        }

        // 8 件より大きいまとまりは、事前検査で断られる(空き容量の不足の代わり)。
        var requestedSizes: [Int] = []
        let fileOps = fileOps
        let undone = try await TransferUndo.undo(receipts, fileOps: fileOps) { items, folder, progress in
            requestedSizes.append(items.count)
            guard items.count <= 8 else {
                throw FileOperationError.insufficientFreeSpace(required: 2, available: 1, destination: folder)
            }
            return try await fileOps.move(items, to: folder, options: FileOperationOptions(conflictPolicy: .keepBoth, progress: progress))
        }

        #expect(undone.result == .complete)
        #expect(undone.resolvedIndices == Set(receipts.indices))
        for original in originals {
            #expect(FileManager.default.fileExists(atPath: original.path))
        }
        // 64 → 32 → 16 → 8 と割るだけ(断られたまとまりの合計 64 × 3 と、運べた 8 件ずつの 64)。以前の形では 2000 件を超えた。
        #expect(requestedSizes.reduce(0, +) <= count * 4)
    }

    /// 進捗の受け口はどのスレッドから呼ばれるか分からない。
    private final class ReportLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [FileOperationProgress] = []
        func append(_ value: FileOperationProgress) {
            lock.lock()
            stored.append(value)
            lock.unlock()
        }
        var values: [FileOperationProgress] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    @Test("進捗の中継は最新の値だけを、新しい順にメインアクターへ渡す")
    func progressRelayDeliversOnlyTheLatestInOrder() async throws {
        // 実機検証: 報告ごとに Task を作っていたので、メインが追いつかず帯のバーが遅れ、順番も保証されなかった。
        let relay = ProgressRelay()
        let delivered = DeliveredLog()
        DispatchQueue.concurrentPerform(iterations: 1) { _ in
            for index in 1...5000 {
                relay.push(FileOperationProgress(completedItems: index, totalItems: 5000)) { delivered.values.append($0.completedItems) }
            }
        }
        for _ in 0..<100 where delivered.values.last != 5000 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(delivered.values.last == 5000)
        #expect(delivered.values == delivered.values.sorted())
        #expect(delivered.values.count < 100, "報告の数だけ渡さない")
    }

    @MainActor
    private final class DeliveredLog {
        var values: [Int] = []
    }

    @Test("新規フォルダの取り消しは、読めないフォルダを空とみなさない")
    func createFolderUndoDoesNotTreatAnUnreadableFolderAsEmpty() async throws {
        let folder = temporary.file("unreadable-new")
        let command = CreateFolderCommand(url: folder, fileOps: fileOps)
        _ = try await command.execute()
        try Data("x".utf8).write(to: folder.appendingPathComponent("inner.txt"))
        #expect(chmod(folder.path, 0o000) == 0)
        defer { chmod(folder.path, 0o755) }
        guard case .impossible = try await command.undo() else {
            Issue.record("読めないフォルダを取り消してしまった")
            return
        }
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    /// 取り消しの下に積む、ゴミ箱を使う別の操作(新規フォルダ)。
    private func olderFolder(url: URL, fileOps: FileOperationService) -> CreateFolderCommand {
        CreateFolderCommand(url: url, fileOps: fileOps)
    }

    @Test("新規フォルダの取り消しは、空のときだけゴミ箱へ送る")
    func createFolderUndoOnlyWhenEmpty() async throws {
        let emptyFolder = temporary.file("empty-new")
        let empty = CreateFolderCommand(url: emptyFolder, fileOps: fileOps)
        _ = try await empty.execute()
        #expect(try await empty.undo() == .complete)
        #expect(!FileManager.default.fileExists(atPath: emptyFolder.path))

        let filledFolder = temporary.file("filled-new")
        let filled = CreateFolderCommand(url: filledFolder, fileOps: fileOps)
        _ = try await filled.execute()
        try Data("x".utf8).write(to: filledFolder.appendingPathComponent("inner.txt"))
        guard case .impossible = try await filled.undo() else {
            Issue.record("中身のあるフォルダを取り消してしまった")
            return
        }
        #expect(FileManager.default.fileExists(atPath: filledFolder.appendingPathComponent("inner.txt").path))
    }
}

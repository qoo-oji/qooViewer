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

    @Test("まとめた操作は、失敗(中止ではない)では巻き戻さない")
    func compositeDoesNotRollBackOnFailure() async throws {
        let first = ScriptedCommand("create")
        let second = ScriptedCommand("extract")
        second.executeError = CocoaError(.fileWriteOutOfSpace)
        let composite = CompositeFileCommand(displayName: "both", children: [first, second])
        await #expect(throws: CocoaError.self) { _ = try await composite.execute() }
        #expect(first.undos == 0)
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

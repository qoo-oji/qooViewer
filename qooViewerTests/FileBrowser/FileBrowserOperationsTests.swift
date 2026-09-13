import AppKit
import Foundation
import Testing

@testable import qooViewer

/// ファイルブラウザの書く操作の窓口(ViewModels/FileBrowserOperations.swift)。
///
/// **共有の状態に触れない**: ペーストボードは名前付きの使い捨て(`NSPasteboard.withUniqueName()`)、
/// ゴミ箱は疑似ゴミ箱(`FileOperationEnvironment.pseudoTrash`)、ゴミ箱の有無の判定も差し替える。
/// 確認と報告は台本どおりに答える偽物(`ScriptedPresenter`)。待ち合わせは`settle()`で、時間では待たない。
@MainActor
struct FileBrowserOperationsTests {
    final class ScriptedPresenter: FileBrowserOperationPresenting {
        var confirmsDeletion = false
        var confirmsLockedItems = false
        var conflictAnswer = ConflictDecision(.skip)
        private(set) var deletionPrompts: [[URL]] = []
        private(set) var lockedPrompts: [(urls: [URL], deletesImmediately: Bool)] = []
        private(set) var conflicts: [FileConflict] = []
        /// 尋ねたときの「置き換えるとすぐに消える」の値(衝突 1 件ごと)。
        private(set) var replacingDeletesImmediately: [Bool] = []
        private(set) var problems: [FileBrowserProblem] = []

        func confirmImmediateDeletion(of urls: [URL]) async -> Bool {
            deletionPrompts.append(urls)
            return confirmsDeletion
        }

        func confirmLockedItems(_ urls: [URL], deletesImmediately: Bool) async -> Bool {
            lockedPrompts.append((urls, deletesImmediately))
            return confirmsLockedItems
        }

        func resolveConflict(_ conflict: FileConflict, replacingDeletesImmediately: Bool, cancellation: Cancellation) async -> ConflictDecision {
            conflicts.append(conflict)
            self.replacingDeletesImmediately.append(replacingDeletesImmediately)
            return conflictAnswer
        }

        func showProblem(_ problem: FileBrowserProblem) {
            problems.append(problem)
        }
    }

    private struct Fixture {
        let temporary: TemporaryDirectory
        let suite: PreferencesSuite
        let preferences: AppPreferences
        let state: FileBrowserState
        let presenter = ScriptedPresenter()
        let pasteboard = NSPasteboard.withUniqueName()
        /// `root/{a.txt, sub/}` と `other/`。
        let root: URL
        let sub: URL
        let other: URL
        let trash: URL

        init(_ label: String, hasTrash: Bool = true) throws {
            temporary = try TemporaryDirectory(label)
            suite = PreferencesSuite(label: label)
            preferences = suite.makePreferences()
            state = FileBrowserState(defaults: suite.defaults)
            state.preferences = preferences
            root = try temporary.directory("root")
            sub = try temporary.directory("root/sub")
            other = try temporary.directory("other")
            trash = try temporary.directory("PseudoTrash")
            try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
            let operations = state.operations
            operations.fileOps = FileOperationService(environment: .pseudoTrash(at: trash, hasTrash: { _ in hasTrash }))
            operations.hasTrash = { _ in hasTrash }
            operations.pasteboard = pasteboard
            operations.presenter = presenter
        }

        func entry(_ url: URL) -> FileBrowserEntry {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            return FileBrowserEntry(
                url: url, displayName: url.lastPathComponent, isDirectory: isDirectory, isPackage: false,
                isSymbolicLink: false, isVolume: false, fileSize: nil, typeDescription: nil, creationDate: nil,
                modificationDate: nil
            )
        }

        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path)
        }

        func names(in folder: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        }

        func showRoot() async {
            state.navigate(to: root)
            await state.settle()
        }

        func finish() async {
            await state.operations.settle()
            await state.settle()
        }
    }

    // MARK: - コピー・カット・ペースト

    @Test("コピーしてペーストするとコピーになり、元は残る。貼ったものが選ばれる")
    func copyThenPasteCopies() async throws {
        let fixture = try Fixture("fbops-copy")
        await fixture.showRoot()
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.copy([fixture.entry(file)])
        #expect(fixture.state.cutPaths.isEmpty)

        fixture.state.navigate(to: fixture.other)
        await fixture.state.settle()
        fixture.state.operations.paste(into: fixture.other)
        await fixture.finish()

        #expect(fixture.exists(file))
        #expect(fixture.names(in: fixture.other) == ["a.txt"])
        #expect(fixture.state.selection == [FileBrowserState.id(for: fixture.other.appendingPathComponent("a.txt"))])
        #expect(fixture.state.commandStack.canUndo)
    }

    @Test("カットしてペーストすると移動になり、カットの記憶は消える。取り消すと元へ戻る")
    func cutThenPasteMovesAndUndoes() async throws {
        let fixture = try Fixture("fbops-cut")
        await fixture.showRoot()
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.cut([fixture.entry(file)])
        #expect(fixture.state.isCut(fixture.entry(file)))

        fixture.state.operations.paste(into: fixture.other)
        await fixture.finish()
        #expect(!fixture.exists(file))
        #expect(fixture.names(in: fixture.other) == ["a.txt"])
        #expect(fixture.state.cutPaths.isEmpty)

        fixture.state.operations.undo()
        await fixture.finish()
        #expect(fixture.exists(file))
        #expect(fixture.names(in: fixture.other).isEmpty)
        #expect(fixture.presenter.problems.isEmpty)
    }

    @Test("カットの後に別のものがペーストボードに載ったら、ペーストはコピーになる")
    func cutIsForgottenWhenPasteboardChanges() async throws {
        let fixture = try Fixture("fbops-cut-stale")
        let file = fixture.root.appendingPathComponent("a.txt")
        let second = fixture.root.appendingPathComponent("b.txt")
        try Data("b".utf8).write(to: second)
        fixture.state.operations.cut([fixture.entry(file)])
        // 他のアプリがコピーした、の代わり(アプリの外からの書き込みはカットの記憶を消さない)。
        fixture.pasteboard.clearContents()
        fixture.pasteboard.writeObjects([second as NSURL])

        fixture.state.operations.paste(into: fixture.other)
        await fixture.finish()
        #expect(fixture.exists(second))
        #expect(fixture.exists(file))
        #expect(fixture.names(in: fixture.other) == ["b.txt"])
    }

    @Test("⌥⌘V はカットしていなくても移動になる")
    func forceMovePasteMoves() async throws {
        let fixture = try Fixture("fbops-forcemove")
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.copy([fixture.entry(file)])
        fixture.state.operations.paste(into: fixture.other, forceMove: true)
        await fixture.finish()
        #expect(!fixture.exists(file))
        #expect(fixture.names(in: fixture.other) == ["a.txt"])
    }

    @Test("同じフォルダへのペーストは尋ねずに複製する(name 2)")
    func pasteIntoSameFolderDuplicates() async throws {
        let fixture = try Fixture("fbops-dup")
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.copy([fixture.entry(file)])
        fixture.state.operations.paste(into: fixture.root)
        await fixture.finish()
        #expect(fixture.names(in: fixture.root) == ["a 2.txt", "a.txt", "sub"])
        #expect(fixture.presenter.conflicts.isEmpty)
    }

    // MARK: - ドラッグ&ドロップ

    @Test("ドロップで移動とコピーが混ざっても 1 回の取り消しで両方戻る")
    func mixedDropUndoesAsOneStep() async throws {
        let fixture = try Fixture("fbops-drop-mixed")
        let file = fixture.root.appendingPathComponent("a.txt")
        let away = fixture.other.appendingPathComponent("b.txt")
        try Data("b".utf8).write(to: away)
        let plan = FileDropPlan(moves: [file], copies: [away])
        fixture.state.operations.drop(plan, into: fixture.sub)
        await fixture.finish()
        #expect(!fixture.exists(file))
        #expect(fixture.exists(away))
        #expect(fixture.names(in: fixture.sub) == ["a.txt", "b.txt"])

        fixture.state.operations.undo()
        await fixture.finish()
        #expect(fixture.exists(file))
        #expect(fixture.names(in: fixture.sub).isEmpty)
        #expect(!fixture.state.commandStack.canUndo)
        #expect(fixture.presenter.problems.isEmpty)
    }

    @Test("⌥ で同じフォルダへ落としたコピーは尋ねずに複製し、表示中なら選ぶ")
    func optionDropIntoSameFolderDuplicates() async throws {
        let fixture = try Fixture("fbops-drop-dup")
        await fixture.showRoot()
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.drop(FileDropPlan(moves: [], copies: [file]), into: fixture.root)
        await fixture.finish()
        #expect(fixture.names(in: fixture.root) == ["a 2.txt", "a.txt", "sub"])
        #expect(fixture.presenter.conflicts.isEmpty)
        #expect(fixture.state.selection == [FileBrowserState.id(for: fixture.root.appendingPathComponent("a 2.txt"))])
    }

    @Test("別のフォルダで名前がぶつかったら尋ね、「スキップ」なら何も起きず、積まれない")
    func conflictAsksAndSkips() async throws {
        let fixture = try Fixture("fbops-conflict")
        let file = fixture.root.appendingPathComponent("a.txt")
        try Data("other".utf8).write(to: fixture.other.appendingPathComponent("a.txt"))
        fixture.presenter.conflictAnswer = ConflictDecision(.skip)
        fixture.state.operations.copy([fixture.entry(file)])
        fixture.state.operations.paste(into: fixture.other)
        await fixture.finish()
        #expect(fixture.presenter.conflicts.count == 1)
        #expect(try String(contentsOf: fixture.other.appendingPathComponent("a.txt"), encoding: .utf8) == "other")
        #expect(!fixture.state.commandStack.canUndo)
    }

    @Test("「両方残す」なら name 2 で置く")
    func conflictKeepBoth() async throws {
        let fixture = try Fixture("fbops-keepboth")
        let file = fixture.root.appendingPathComponent("a.txt")
        try Data("other".utf8).write(to: fixture.other.appendingPathComponent("a.txt"))
        fixture.presenter.conflictAnswer = ConflictDecision(.keepBoth)
        fixture.state.operations.copy([fixture.entry(file)])
        fixture.state.operations.paste(into: fixture.other)
        await fixture.finish()
        #expect(fixture.names(in: fixture.other) == ["a 2.txt", "a.txt"])
    }

    @Test("「置き換える」なら元の項目をゴミ箱へ送って置き、取り消すと元の項目が戻る")
    func conflictReplaceAndUndo() async throws {
        let fixture = try Fixture("fbops-replace")
        let file = fixture.root.appendingPathComponent("a.txt")
        let existing = fixture.other.appendingPathComponent("a.txt")
        try Data("other".utf8).write(to: existing)
        fixture.presenter.conflictAnswer = ConflictDecision(.replace)
        fixture.state.operations.copy([fixture.entry(file)])
        fixture.state.operations.paste(into: fixture.other)
        await fixture.finish()
        #expect(fixture.presenter.replacingDeletesImmediately == [false])
        #expect(try String(contentsOf: existing, encoding: .utf8) == "a")
        #expect(fixture.names(in: fixture.other) == ["a.txt"], "退避用の隠しフォルダが残っている")
        #expect(fixture.names(in: fixture.trash) == ["a.txt"])

        fixture.state.operations.undo()
        await fixture.finish()
        #expect(try String(contentsOf: existing, encoding: .utf8) == "other")
        #expect(fixture.presenter.problems.isEmpty)
    }

    @Test("ゴミ箱の無い場所への衝突は「置き換えるとすぐに消える」と伝えて尋ねる")
    func conflictWithoutTrashSaysReplacingDeletes() async throws {
        let fixture = try Fixture("fbops-replace-notrash", hasTrash: false)
        let file = fixture.root.appendingPathComponent("a.txt")
        try Data("other".utf8).write(to: fixture.other.appendingPathComponent("a.txt"))
        fixture.presenter.conflictAnswer = ConflictDecision(.skip)
        fixture.state.operations.copy([fixture.entry(file)])
        fixture.state.operations.paste(into: fixture.other)
        await fixture.finish()
        #expect(fixture.presenter.replacingDeletesImmediately == [true])
    }

    @Test("ペーストボードの読み戻しは末尾の / が違ってもカットと一致する")
    func cutPathsIgnoreTrailingSlash() {
        let plain = URL(fileURLWithPath: "/tmp/qooViewerTests-never/folder")
        let slashed = URL(fileURLWithPath: "/tmp/qooViewerTests-never/folder/", isDirectory: true)
        #expect(FileBrowserOperations.paths(of: [plain]) == FileBrowserOperations.paths(of: [slashed]))
    }

    // MARK: - ゴミ箱

    @Test("ゴミ箱のある場所ではゴミ箱へ送り、確認しない。取り消すと戻る")
    func trashWithoutConfirmation() async throws {
        let fixture = try Fixture("fbops-trash")
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.moveToTrash([fixture.entry(file)])
        await fixture.finish()
        #expect(!fixture.exists(file))
        #expect(fixture.names(in: fixture.trash) == ["a.txt"])
        #expect(fixture.presenter.deletionPrompts.isEmpty)

        fixture.state.operations.undo()
        await fixture.finish()
        #expect(fixture.exists(file))
    }

    @Test("ロックされた項目は確認し、断れば何もしない。続ければゴミ箱の中でもロックされ、取り消すとロックごと戻る")
    func trashingLockedItemsAsks() async throws {
        let fixture = try Fixture("fbops-trash-locked")
        let file = fixture.root.appendingPathComponent("a.txt")
        let plain = fixture.root.appendingPathComponent("b.txt")
        try Data("b".utf8).write(to: plain)
        FileOperationService.setLocked(file, true)

        fixture.presenter.confirmsLockedItems = false
        fixture.state.operations.moveToTrash([fixture.entry(file), fixture.entry(plain)])
        await fixture.finish()
        #expect(fixture.presenter.lockedPrompts.map(\.urls) == [[file]])
        #expect(fixture.presenter.lockedPrompts.map(\.deletesImmediately) == [false])
        #expect(fixture.exists(file))
        #expect(fixture.exists(plain), "断ったのにロックされていない項目だけ送った")

        fixture.presenter.confirmsLockedItems = true
        fixture.state.operations.moveToTrash([fixture.entry(file), fixture.entry(plain)])
        await fixture.finish()
        #expect(!fixture.exists(file))
        #expect(FileOperationService.isLocked(fixture.trash.appendingPathComponent("a.txt")))
        #expect(fixture.presenter.problems.isEmpty)

        fixture.state.operations.undo()
        await fixture.finish()
        #expect(fixture.exists(file))
        #expect(FileOperationService.isLocked(file))
    }

    @Test("ゴミ箱の無い場所では、中にロックされた項目があるフォルダも確認してから消す")
    func deletingFoldersWithLockedItemsAsks() async throws {
        let fixture = try Fixture("fbops-delete-locked", hasTrash: false)
        let inner = fixture.sub.appendingPathComponent("inner.txt")
        try Data("x".utf8).write(to: inner)
        FileOperationService.setLocked(inner, true)
        fixture.presenter.confirmsDeletion = true

        fixture.presenter.confirmsLockedItems = false
        fixture.state.operations.moveToTrash([fixture.entry(fixture.sub)])
        await fixture.finish()
        #expect(fixture.presenter.lockedPrompts.map(\.deletesImmediately) == [true])
        #expect(fixture.exists(inner))

        fixture.presenter.confirmsLockedItems = true
        fixture.state.operations.moveToTrash([fixture.entry(fixture.sub)])
        await fixture.finish()
        #expect(!fixture.exists(fixture.sub))
        #expect(fixture.presenter.problems.isEmpty)
    }

    @Test("ゴミ箱の無い場所では確認し、断れば何も消えない")
    func noTrashAsksAndCancels() async throws {
        let fixture = try Fixture("fbops-notrash-cancel", hasTrash: false)
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.presenter.confirmsDeletion = false
        fixture.state.operations.moveToTrash([fixture.entry(file)])
        await fixture.finish()
        #expect(fixture.presenter.deletionPrompts.count == 1)
        #expect(fixture.exists(file))
    }

    @Test("ゴミ箱の無い場所で承諾すると完全に削除し、取り消しには積まない")
    func noTrashDeletesImmediately() async throws {
        let fixture = try Fixture("fbops-notrash-delete", hasTrash: false)
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.presenter.confirmsDeletion = true
        fixture.state.operations.moveToTrash([fixture.entry(file)])
        await fixture.finish()
        #expect(!fixture.exists(file))
        #expect(fixture.names(in: fixture.trash).isEmpty)
        #expect(!fixture.state.commandStack.canUndo)
    }

    // MARK: - 新規フォルダ・名前の変更

    @Test("新規フォルダは「名称未設定フォルダ」で作り、表示中なら名前の編集を頼む。2つ目は番号付き")
    func newFolderRequestsRename() async throws {
        let fixture = try Fixture("fbops-newfolder")
        await fixture.showRoot()
        let untitled = String(localized: "untitled folder", language: AppLanguage.currentLocale)

        fixture.state.operations.newFolder(in: fixture.root)
        await fixture.finish()
        let first = fixture.root.appendingPathComponent(untitled)
        #expect(fixture.exists(first))
        #expect(fixture.state.renameRequest?.id == FileBrowserState.id(for: first))
        #expect(fixture.state.selection == [FileBrowserState.id(for: first)])

        fixture.state.operations.newFolder(in: fixture.root)
        await fixture.finish()
        #expect(fixture.exists(fixture.root.appendingPathComponent("\(untitled) 2")))
    }

    @Test("名前を変えると選んだまま、取り消すと元の名前。使えない名前は報告して何もしない")
    func renameAndUndo() async throws {
        let fixture = try Fixture("fbops-rename")
        await fixture.showRoot()
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.rename(fixture.entry(file), to: "renamed.txt")
        await fixture.finish()
        let renamed = fixture.root.appendingPathComponent("renamed.txt")
        #expect(fixture.exists(renamed))
        #expect(fixture.state.selection == [FileBrowserState.id(for: renamed)])

        fixture.state.operations.undo()
        await fixture.finish()
        #expect(fixture.exists(file))

        fixture.state.operations.rename(fixture.entry(file), to: "bad/name")
        await fixture.finish()
        #expect(fixture.exists(file))
        #expect(fixture.presenter.problems.count == 1)
    }

    @Test("同じ名前への変更は何もせず、積まない")
    func renameToSameNameDoesNothing() async throws {
        let fixture = try Fixture("fbops-rename-same")
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.rename(fixture.entry(file), to: "a.txt")
        await fixture.finish()
        #expect(!fixture.state.commandStack.canUndo)
        #expect(fixture.presenter.problems.isEmpty)
    }

    @Test("操作は1本ずつ順に走る(後の操作は前の結果を見る)")
    func operationsRunSerially() async throws {
        let fixture = try Fixture("fbops-serial")
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.rename(fixture.entry(file), to: "b.txt")
        // 前の名前の変更が済んでから走るので、b.txt をゴミ箱へ送れる。
        fixture.state.operations.moveToTrash([fixture.entry(fixture.root.appendingPathComponent("b.txt"))])
        await fixture.finish()
        #expect(fixture.names(in: fixture.trash) == ["b.txt"])
        #expect(fixture.names(in: fixture.root) == ["sub"])
    }

    @Test("操作のあと、変わったフォルダをツリーへ知らせる")
    func notifiesTreeOfChangedFolders() async throws {
        let fixture = try Fixture("fbops-notify")
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.copy([fixture.entry(file)])
        fixture.state.operations.paste(into: fixture.other)
        await fixture.finish()
        let change = try #require(fixture.state.fileSystemChange)
        #expect(change.folderIDs.contains(FileBrowserState.id(for: fixture.other)))
        #expect(!change.isUnknownScope)

        // 取り消しはどのフォルダが変わったかを返さないので、全体を見直してもらう。
        fixture.state.operations.undo()
        await fixture.finish()
        let undoChange = try #require(fixture.state.fileSystemChange)
        #expect(undoChange.isUnknownScope)
        #expect(undoChange.serial > change.serial)
    }

    // MARK: - 進捗・報告

    @Test("残り時間は動き始めて1秒未満・総量不明なら出さない")
    func remainingTimeEstimate() {
        var activity = FileBrowserActivity(id: UUID(), title: "t", progress: FileOperationProgress(), isCancellable: true)
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        activity.bytesStartedAt = start
        activity.progress = FileOperationProgress(completedBytes: 100, totalBytes: 400, completedItems: 0, totalItems: 1)
        #expect(activity.estimatedSecondsRemaining(now: start.addingTimeInterval(0.5)) == nil)
        #expect(activity.estimatedSecondsRemaining(now: start.addingTimeInterval(2)) == 6)
        activity.progress.totalBytes = 0
        #expect(activity.estimatedSecondsRemaining(now: start.addingTimeInterval(2)) == nil)
    }

    @Test("失敗の一覧は上限で打ち切り、残りは件数で書く")
    func problemListingIsCapped() {
        let failures = (0..<13).map { FailedItem(name: "item\($0)", reason: "r") }
        let problem = FileBrowserProblem.partialFailure(operationName: "op", failures: failures)
        let lines = problem.message.split(separator: "\n")
        #expect(lines.count == FileBrowserProblem.listedFailureLimit + 1)
        #expect(lines.first == "item0: r")
    }

    @Test("名前の欄は拡張子を除いた部分を選ぶ。先頭の . だけ・拡張子なしは全体")
    func baseNameSelection() {
        #expect(FileBrowserNameField.baseNameRange(of: "comic.cbz") == NSRange(location: 0, length: 5))
        #expect(FileBrowserNameField.baseNameRange(of: "archive.tar.gz") == NSRange(location: 0, length: 11))
        #expect(FileBrowserNameField.baseNameRange(of: ".hidden") == NSRange(location: 0, length: 7))
        #expect(FileBrowserNameField.baseNameRange(of: "README") == NSRange(location: 0, length: 6))
    }
}

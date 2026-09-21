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
        var lockedAnswer = LockedItemsDecision.stop
        var conflictAnswer = ConflictDecision(.skip)
        var irreversibleMoveAnswer = IrreversibleMoveDecision.stop
        /// 衝突の確認で「中止」を押したことにする(`cancellation.request()` してから `conflictAnswer` を返す)。
        var cancelsOnConflict = false
        private(set) var irreversibleMovePrompts: [(urls: [URL], totalCount: Int)] = []
        private(set) var deletionPrompts: [[URL]] = []
        private(set) var lockedPrompts: [(urls: [URL], totalCount: Int, action: LockedItemAction)] = []
        private(set) var conflicts: [FileConflict] = []
        /// 尋ねたときの「置き換えるとすぐに消える」の値(衝突 1 件ごと)。
        private(set) var replacingDeletesImmediately: [Bool] = []
        private(set) var problems: [FileBrowserProblem] = []

        func confirmImmediateDeletion(of urls: [URL]) async -> Bool {
            deletionPrompts.append(urls)
            return confirmsDeletion
        }

        func confirmLockedItems(_ urls: [URL], totalCount: Int, action: LockedItemAction) async -> LockedItemsDecision {
            lockedPrompts.append((urls, totalCount, action))
            return lockedAnswer
        }

        func confirmIrreversibleMove(of urls: [URL], totalCount: Int) async -> IrreversibleMoveDecision {
            irreversibleMovePrompts.append((urls, totalCount))
            return irreversibleMoveAnswer
        }

        func resolveConflict(_ conflict: FileConflict, replacingDeletesImmediately: Bool, cancellation: Cancellation) async -> ConflictDecision {
            conflicts.append(conflict)
            self.replacingDeletesImmediately.append(replacingDeletesImmediately)
            if cancelsOnConflict { cancellation.request() }
            return conflictAnswer
        }

        /// 一括リネームのシートの答え(nil は「キャンセル」)。
        var bulkRenameAnswer: BulkRenameSettings?
        private(set) var bulkRenameRequests: [BulkRenameRequest] = []

        /// 一括リネームのシートが出ている間に起こすこと(設定の切り替えなど)。
        var whileBulkRenameSheetIsUp: (() -> Void)?

        func requestBulkRename(_ request: BulkRenameRequest) async -> BulkRenameSettings? {
            bulkRenameRequests.append(request)
            whileBulkRenameSheetIsUp?()
            return bulkRenameAnswer
        }

        /// 「保存先を選んで圧縮…」「展開先を選んで展開…」の答え(nil は「キャンセル」)。
        var chosenFolder: URL?
        private(set) var folderChoices: [ArchiveDestinationPurpose] = []

        func chooseDestinationFolder(for purpose: ArchiveDestinationPurpose, startingAt folder: URL) async -> URL? {
            folderChoices.append(purpose)
            return chosenFolder
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
            // 書く操作を確かめるので読み取り専用モードは切る(既定は ON。ON のときは readOnly* のテスト)。
            preferences.fileBrowserReadOnly = false
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

    /// 2026-09-21 の監査の L2。以前はペーストの入口でカットの記憶を下ろしていたので、確認で止めた(確認の最中に読み取り専用へ
    /// 切り替えて捨てられた場合も)あとにもう一度 ⌘V すると、移動のつもりがコピーになった。
    @Test("カットしてペーストした移動を確認で止めたら、カットの記憶は残り、もう一度ペーストすると移動になる")
    func cutSurvivesAPasteStoppedAtTheConfirmation() async throws {
        let fixture = try Fixture("fbops-cut-stopped")
        await fixture.showRoot()
        let file = fixture.root.appendingPathComponent("a.txt")
        FileOperationService.setLocked(file, true)
        defer {
            // 一時フォルダを片付けられるように(ロックされた項目は消せない)。
            FileOperationService.setLocked(file, false)
            FileOperationService.setLocked(fixture.other.appendingPathComponent("a.txt"), false)
        }
        fixture.state.operations.cut([fixture.entry(file)])

        fixture.presenter.lockedAnswer = .stop
        fixture.state.operations.paste(into: fixture.other)
        await fixture.finish()
        #expect(fixture.presenter.lockedPrompts.count == 1)
        #expect(fixture.exists(file))
        #expect(fixture.state.isCut(fixture.entry(file)))

        fixture.presenter.lockedAnswer = .proceed
        fixture.state.operations.paste(into: fixture.other)
        await fixture.finish()
        #expect(!fixture.exists(file))
        #expect(fixture.names(in: fixture.other) == ["a.txt"])
        #expect(fixture.state.cutPaths.isEmpty)
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

    // MARK: - 取り消せない移動

    @Test("書けるフォルダの項目の移動は、戻せるので尋ねない")
    func movableItemsDoNotAsk() async throws {
        let fixture = try Fixture("fbops-putback-writable")
        let file = fixture.root.appendingPathComponent("a.txt")
        #expect(FileBrowserOperations.canPutBack(file))
        fixture.state.operations.copy([fixture.entry(file)])
        fixture.state.operations.paste(into: fixture.other, forceMove: true)
        await fixture.finish()
        #expect(fixture.presenter.irreversibleMovePrompts.isEmpty)
        #expect(fixture.state.commandStack.canUndo)
    }

    @Test("元のフォルダへ書けない項目の ⌥⌘V は尋ね、「中止」なら何もしない")
    func irreversibleMoveAsksAndStops() async throws {
        let fixture = try Fixture("fbops-putback-stop")
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.canPutBack = { _ in false }
        fixture.presenter.irreversibleMoveAnswer = .stop
        fixture.state.operations.copy([fixture.entry(file)])
        fixture.state.operations.paste(into: fixture.other, forceMove: true)
        await fixture.finish()
        #expect(fixture.presenter.irreversibleMovePrompts.map(\.urls) == [[file]])
        #expect(fixture.presenter.irreversibleMovePrompts.map(\.totalCount) == [1])
        #expect(fixture.exists(file))
        #expect(fixture.names(in: fixture.other).isEmpty)
        #expect(!fixture.state.commandStack.canUndo)
    }

    @Test("「移動」なら移動し、取り消しには積まない(前の操作が ⌘Z の対象のまま)")
    func irreversibleMoveIsNotStacked() async throws {
        let fixture = try Fixture("fbops-putback-move")
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.newFolder(in: fixture.sub)
        await fixture.finish()
        let previousTitle = fixture.state.commandStack.undoTitle

        fixture.state.operations.canPutBack = { _ in false }
        fixture.presenter.irreversibleMoveAnswer = .move
        fixture.state.operations.drop(FileDropPlan(moves: [file], copies: []), into: fixture.other)
        await fixture.finish()
        #expect(fixture.presenter.irreversibleMovePrompts.count == 1)
        #expect(!fixture.exists(file))
        #expect(fixture.names(in: fixture.other) == ["a.txt"])
        #expect(fixture.state.commandStack.undoTitle == previousTitle)
        #expect(fixture.presenter.problems.isEmpty)
    }

    @Test("「コピー」なら戻せない項目だけコピーし、戻せる項目は移動のまま。1 回の取り消しで両方戻る")
    func irreversibleMoveFallsBackToCopy() async throws {
        let fixture = try Fixture("fbops-putback-copy")
        let stranded = fixture.root.appendingPathComponent("a.txt")
        let movable = fixture.sub.appendingPathComponent("b.txt")
        try Data("b".utf8).write(to: movable)
        fixture.state.operations.canPutBack = { $0 != stranded }
        fixture.presenter.irreversibleMoveAnswer = .copy
        fixture.state.operations.copy([fixture.entry(stranded), fixture.entry(movable)])
        fixture.state.operations.paste(into: fixture.other, forceMove: true)
        await fixture.finish()
        #expect(fixture.presenter.irreversibleMovePrompts.map(\.urls) == [[stranded]])
        #expect(fixture.presenter.irreversibleMovePrompts.map(\.totalCount) == [2])
        #expect(fixture.exists(stranded), "戻せない項目の元が消えた")
        #expect(!fixture.exists(movable))
        #expect(fixture.names(in: fixture.other) == ["a.txt", "b.txt"])

        fixture.state.operations.undo()
        await fixture.finish()
        #expect(fixture.exists(movable))
        #expect(fixture.names(in: fixture.other).isEmpty)
        #expect(fixture.presenter.problems.isEmpty)
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

    @Test("走っている操作の後ろで押した ⌘Z は、押した時点の一番上でなくなっていたら何もしない(走っていた操作を戻さない)")
    func undoPressedDuringAnOperationDoesNotUndoThatOperation() async throws {
        // 2 回目の監査 11: 以前は列の後ろに並んだ ⌘Z が、走っていた操作が終わった直後にその操作を戻していた。
        let fixture = try Fixture("fbops-undo-queued")
        await fixture.showRoot()
        let file = fixture.root.appendingPathComponent("a.txt")
        await fixture.state.operations.newFolder(in: fixture.other).value
        await fixture.finish()
        #expect(fixture.state.commandStack.canUndo)

        fixture.state.operations.copy([fixture.entry(file)])
        fixture.state.operations.paste(into: fixture.other)
        // ペーストはまだ列の中(始まっていない)。この時点の一番上は「新規フォルダ」。
        fixture.state.operations.undo()
        await fixture.finish()

        #expect(fixture.names(in: fixture.other).contains("a.txt"), "走っていたコピーは戻さない")
        #expect(fixture.names(in: fixture.other).count == 2, "押した時点の一番上(新規フォルダ)も、もう一番上ではないので戻さない")
        #expect(fixture.state.commandStack.canUndo)
    }

    @Test("ウインドウを閉じた後の操作は、確認を断る側で答え(衝突は残りを止める)、問題の報告は捨てない")
    func detachedOperationsDeclineConfirmationsButStillReport() async throws {
        // 2 回目の監査 12: 以前は presenter を nil にしていたので、報告が捨てられ、衝突は黙ってスキップされた。
        let fixture = try Fixture("fbops-detached", hasTrash: false)
        let file = fixture.root.appendingPathComponent("a.txt")
        let second = fixture.root.appendingPathComponent("b.txt")
        try Data("b".utf8).write(to: second)
        try Data("other".utf8).write(to: fixture.other.appendingPathComponent("a.txt"))
        fixture.state.releaseResources()

        fixture.state.operations.moveToTrash([fixture.entry(file)])
        fixture.state.operations.copy([fixture.entry(file), fixture.entry(second)])
        fixture.state.operations.paste(into: fixture.other)
        fixture.state.operations.rename(fixture.entry(file), to: "bad/name")
        await fixture.finish()

        #expect(fixture.exists(file), "すぐに削除する確認は断る")
        #expect(fixture.presenter.deletionPrompts.isEmpty && fixture.presenter.conflicts.isEmpty, "閉じたウインドウでは尋ねない")
        #expect(fixture.names(in: fixture.other) == ["a.txt"], "衝突で残りも止める(b.txt を黙って運ばない)")
        #expect(try String(contentsOf: fixture.other.appendingPathComponent("a.txt"), encoding: .utf8) == "other")
        #expect(fixture.presenter.problems.count == 1, "名前の変更の失敗は元の相手へ届く")
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

        fixture.presenter.lockedAnswer = .stop
        fixture.state.operations.moveToTrash([fixture.entry(file), fixture.entry(plain)])
        await fixture.finish()
        #expect(fixture.presenter.lockedPrompts.map(\.urls) == [[file]])
        #expect(fixture.presenter.lockedPrompts.map(\.totalCount) == [2])
        #expect(fixture.presenter.lockedPrompts.map(\.action) == [.trash])
        #expect(fixture.exists(file))
        #expect(fixture.exists(plain), "断ったのにロックされていない項目だけ送った")

        fixture.presenter.lockedAnswer = .proceed
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

        fixture.presenter.lockedAnswer = .stop
        fixture.state.operations.moveToTrash([fixture.entry(fixture.sub)])
        await fixture.finish()
        #expect(fixture.presenter.lockedPrompts.map(\.action) == [.deleteImmediately])
        #expect(fixture.exists(inner))

        fixture.presenter.lockedAnswer = .proceed
        fixture.state.operations.moveToTrash([fixture.entry(fixture.sub)])
        await fixture.finish()
        #expect(!fixture.exists(fixture.sub))
        #expect(fixture.presenter.problems.isEmpty)
    }

    @Test("ロックされた項目の確認で「ロックされた項目をスキップ」なら、ロックされていない項目だけを送る")
    func trashingSkipsLockedItems() async throws {
        let fixture = try Fixture("fbops-trash-skiplocked")
        let file = fixture.root.appendingPathComponent("a.txt")
        let plain = fixture.root.appendingPathComponent("b.txt")
        try Data("b".utf8).write(to: plain)
        FileOperationService.setLocked(file, true)
        fixture.presenter.lockedAnswer = .skipLocked
        fixture.state.operations.moveToTrash([fixture.entry(file), fixture.entry(plain)])
        await fixture.finish()
        #expect(fixture.exists(file))
        #expect(FileOperationService.isLocked(file))
        #expect(!fixture.exists(plain))
        #expect(fixture.names(in: fixture.trash) == ["b.txt"])
        #expect(fixture.presenter.problems.isEmpty)
        FileOperationService.setLocked(file, false)
    }

    // MARK: - ロックされた項目の移動・名前の変更・置き換え

    @Test("ロックされた項目の移動は尋ね、続ければ運んだ先でもロックされている。取り消すとロックごと戻る")
    func movingLockedItemsAsksAndKeepsTheLock() async throws {
        let fixture = try Fixture("fbops-move-locked")
        let file = fixture.root.appendingPathComponent("a.txt")
        FileOperationService.setLocked(file, true)

        fixture.presenter.lockedAnswer = .stop
        fixture.state.operations.transfer([file], to: fixture.other, isMove: true)
        await fixture.finish()
        #expect(fixture.presenter.lockedPrompts.map(\.action) == [.move])
        #expect(fixture.exists(file))

        fixture.presenter.lockedAnswer = .proceed
        fixture.state.operations.transfer([file], to: fixture.other, isMove: true)
        await fixture.finish()
        let moved = fixture.other.appendingPathComponent("a.txt")
        #expect(!fixture.exists(file))
        #expect(FileOperationService.isLocked(moved))
        #expect(fixture.presenter.problems.isEmpty)

        fixture.state.operations.undo()
        await fixture.finish()
        #expect(fixture.exists(file))
        #expect(FileOperationService.isLocked(file))
        #expect(fixture.presenter.problems.isEmpty)
        FileOperationService.setLocked(file, false)
    }

    @Test("ロックされた項目の移動で「スキップ」なら、ロックされていない項目だけを運ぶ")
    func movingSkipsLockedItems() async throws {
        let fixture = try Fixture("fbops-move-skiplocked")
        let file = fixture.root.appendingPathComponent("a.txt")
        let plain = fixture.root.appendingPathComponent("b.txt")
        try Data("b".utf8).write(to: plain)
        FileOperationService.setLocked(file, true)
        fixture.presenter.lockedAnswer = .skipLocked
        fixture.state.operations.transfer([file, plain], to: fixture.other, isMove: true)
        await fixture.finish()
        #expect(fixture.presenter.lockedPrompts.map(\.totalCount) == [2])
        #expect(fixture.exists(file))
        #expect(fixture.names(in: fixture.other) == ["b.txt"])
        FileOperationService.setLocked(file, false)
    }

    @Test("ロックされた項目の名前の変更は尋ね、続ければ新しい名前でもロックされている")
    func renamingLockedItemAsks() async throws {
        let fixture = try Fixture("fbops-rename-locked")
        let file = fixture.root.appendingPathComponent("a.txt")
        FileOperationService.setLocked(file, true)

        fixture.presenter.lockedAnswer = .stop
        fixture.state.operations.rename(fixture.entry(file), to: "b.txt")
        await fixture.finish()
        #expect(fixture.presenter.lockedPrompts.map(\.action) == [.rename])
        #expect(fixture.exists(file))
        #expect(fixture.presenter.problems.isEmpty)

        fixture.presenter.lockedAnswer = .proceed
        fixture.state.operations.rename(fixture.entry(file), to: "b.txt")
        await fixture.finish()
        let renamed = fixture.root.appendingPathComponent("b.txt")
        #expect(FileOperationService.isLocked(renamed))

        fixture.state.operations.undo()
        await fixture.finish()
        #expect(FileOperationService.isLocked(file))
        #expect(fixture.presenter.problems.isEmpty)
        FileOperationService.setLocked(file, false)
    }

    @Test("ゴミ箱の無い場所で、中にロックされた項目があるフォルダを置き換えるときは尋ね、断れば触らない。続ければ残さず消す")
    func replacingFolderWithLockedItemsAsks() async throws {
        let fixture = try Fixture("fbops-replace-locked", hasTrash: false)
        let source = try fixture.temporary.directory("root/box")
        try Data("new".utf8).write(to: source.appendingPathComponent("new.txt"))
        let existing = try fixture.temporary.directory("other/box")
        let inner = existing.appendingPathComponent("inner.txt")
        try Data("old".utf8).write(to: inner)
        FileOperationService.setLocked(inner, true)
        fixture.presenter.conflictAnswer = ConflictDecision(.replace)

        fixture.presenter.lockedAnswer = .stop
        fixture.state.operations.transfer([source], to: fixture.other, isMove: false)
        await fixture.finish()
        #expect(fixture.presenter.lockedPrompts.map(\.action) == [.replace(deletesImmediately: true)])
        #expect(fixture.exists(inner))
        #expect(fixture.names(in: fixture.other) == ["box"], "退避用の隠しフォルダが残っている")

        fixture.presenter.lockedAnswer = .proceed
        fixture.state.operations.transfer([source], to: fixture.other, isMove: false)
        await fixture.finish()
        #expect(fixture.names(in: existing) == ["new.txt"])
        #expect(fixture.names(in: fixture.other) == ["box"], "退避を消しきれずに残した")
        #expect(fixture.presenter.problems.isEmpty)
    }

    // MARK: - 取り消しの安全

    @Test("前の操作が作った場所へ、取り消せない移動で同じ名前の項目が来ても、⌘Z はそれに触らない")
    func undoLeavesAnItemThatTookTheSameName() async throws {
        let fixture = try Fixture("fbops-undo-identity")
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.transfer([file], to: fixture.other, isMove: false)
        await fixture.finish()
        let copy = fixture.other.appendingPathComponent("a.txt")
        try FileManager.default.removeItem(at: copy)

        let stranger = fixture.sub.appendingPathComponent("a.txt")
        try Data("stranger".utf8).write(to: stranger)
        fixture.state.operations.canPutBack = { _ in false }
        fixture.presenter.irreversibleMoveAnswer = .move
        fixture.state.operations.transfer([stranger], to: fixture.other, isMove: true)
        await fixture.finish()
        #expect(try String(contentsOf: copy, encoding: .utf8) == "stranger")

        fixture.state.operations.undo()
        await fixture.finish()
        #expect(try String(contentsOf: copy, encoding: .utf8) == "stranger", "移動してきた項目をゴミ箱へ送った")
        #expect(fixture.names(in: fixture.trash).isEmpty)
        #expect(fixture.presenter.problems.count == 1)
        #expect(!fixture.state.commandStack.canUndo, "試し直しても直らない取り消しを履歴に残した")
    }

    @Test("中止した混ざった操作で、取り消せない移動は戻そうとせず、宛先に残ったことを伝える")
    func cancelledMixedTransferReportsStrandedMoves() async throws {
        let fixture = try Fixture("fbops-cancel-stranded")
        let stranded = fixture.root.appendingPathComponent("a.txt")
        let away = fixture.sub.appendingPathComponent("b.txt")
        try Data("b".utf8).write(to: away)
        try Data("other".utf8).write(to: fixture.other.appendingPathComponent("b.txt"))
        fixture.state.operations.canPutBack = { $0 == away }
        fixture.presenter.irreversibleMoveAnswer = .move
        // 移動(a.txt)の後のコピー(b.txt)が衝突し、「中止」を選ぶ。
        fixture.presenter.conflictAnswer = ConflictDecision(.skip)
        fixture.presenter.cancelsOnConflict = true
        fixture.state.operations.drop(FileDropPlan(moves: [stranded], copies: [away]), into: fixture.other)
        await fixture.finish()
        #expect(fixture.names(in: fixture.other) == ["a.txt", "b.txt"])
        #expect(fixture.presenter.problems.count == 1)
        #expect(!fixture.state.commandStack.canUndo)
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
        fixture.state.selection = [FileBrowserState.id(for: file)]
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

    @Test("確定までに選択が外れていたら(アイコン表示で余白をクリックして確定)、名前を変えた項目を選び直さない")
    func renameDoesNotReselectAfterSelectionWasCleared() async throws {
        let fixture = try Fixture("fbops-rename-deselect")
        await fixture.showRoot()
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.selection = []
        fixture.state.operations.rename(fixture.entry(file), to: "renamed.txt")
        await fixture.finish()
        #expect(fixture.exists(fixture.root.appendingPathComponent("renamed.txt")))
        #expect(fixture.state.selection.isEmpty)
    }

    // MARK: - 一括リネーム(段階 5)

    /// フォーマット「名前とカウンタ」の答え。
    private static func counterAnswer(_ custom: String) -> BulkRenameSettings {
        var settings = BulkRenameSettings()
        settings.kind = .format
        settings.formatStyle = .nameAndCounter
        settings.customFormat = custom
        return settings
    }

    /// 2026-09-21 の実機: シートはウインドウの持ち物なので、ファイルブラウザを OFF にしてペインが消えても残り、押すと名前が変わった。
    @Test("シートを出している間にファイルブラウザ機能が OFF・読み取り専用になったら、押しても名前を変えない", arguments: [true, false])
    func bulkRenameIsDroppedWhenChangesBecomeRefusedWhileTheSheetIsUp(turnsFeatureOff: Bool) async throws {
        let fixture = try Fixture("fbops-bulk-gate")
        try Data("b".utf8).write(to: fixture.root.appendingPathComponent("b.txt"))
        await fixture.showRoot()
        let before = fixture.names(in: fixture.root)
        let targets = ["a.txt", "b.txt"].map { fixture.entry(fixture.root.appendingPathComponent($0)) }
        fixture.presenter.bulkRenameAnswer = Self.counterAnswer("F")
        fixture.presenter.whileBulkRenameSheetIsUp = { [preferences = fixture.preferences] in
            if turnsFeatureOff { preferences.fileBrowserFeatureEnabled = false } else { preferences.fileBrowserReadOnly = true }
        }
        fixture.state.operations.bulkRename(targets)
        await fixture.finish()

        #expect(fixture.presenter.bulkRenameRequests.count == 1)
        #expect(fixture.names(in: fixture.root) == before)
        #expect(fixture.state.commandStack.undoTitle == nil)
        #expect(fixture.presenter.problems.isEmpty)
    }

    @Test("一括リネームは表示順に番号を振り、変えた項目を選ぶ。1 回の取り消しで全部戻り、入力は次に出す")
    func bulkRenameNumbersInDisplayOrderAndUndoesAtOnce() async throws {
        let fixture = try Fixture("fbops-bulk")
        try Data("b".utf8).write(to: fixture.root.appendingPathComponent("b.txt"))
        await fixture.showRoot()
        // 表示はフォルダが上(sub, a.txt, b.txt)。渡す順は逆にしても、番号は表示順。
        let targets = ["b.txt", "a.txt", "sub"].map { fixture.entry(fixture.root.appendingPathComponent($0)) }
        fixture.presenter.bulkRenameAnswer = Self.counterAnswer("F")
        fixture.state.operations.bulkRename(targets)
        await fixture.finish()

        #expect(fixture.presenter.bulkRenameRequests.map(\.names) == [["sub", "a.txt", "b.txt"]])
        #expect(fixture.presenter.bulkRenameRequests.first?.existingNames == ["sub", "a.txt", "b.txt"])
        #expect(fixture.names(in: fixture.root) == ["F00001", "F00002.txt", "F00003.txt"])
        #expect(String(decoding: try Data(contentsOf: fixture.root.appendingPathComponent("F00002.txt")), as: UTF8.self) == "a")
        #expect(fixture.state.selection == Set(["F00001", "F00002.txt", "F00003.txt"].map {
            FileBrowserState.id(for: fixture.root.appendingPathComponent($0))
        }))
        #expect(fixture.state.commandStack.undoTitle == String(format: String(localized: "Rename of %lld Items", language: AppLanguage.currentLocale), 3))
        #expect(fixture.state.bulkRenameSettings == Self.counterAnswer("F"))

        fixture.state.operations.undo()
        await fixture.finish()
        #expect(fixture.names(in: fixture.root) == ["a.txt", "b.txt", "sub"])
        #expect(fixture.presenter.problems.isEmpty)

        // 次に開くシートには前回の入力が渡る(保存先はこのテストの使い捨ての defaults)。
        let reopened = FileBrowserState(defaults: fixture.suite.defaults)
        #expect(reopened.bulkRenameSettings == Self.counterAnswer("F"))
    }

    @Test("シートで「キャンセル」なら何も変えず、積まない")
    func bulkRenameCancelled() async throws {
        let fixture = try Fixture("fbops-bulk-cancel")
        try Data("b".utf8).write(to: fixture.root.appendingPathComponent("b.txt"))
        await fixture.showRoot()
        fixture.presenter.bulkRenameAnswer = nil
        fixture.state.operations.bulkRename(["a.txt", "b.txt"].map { fixture.entry(fixture.root.appendingPathComponent($0)) })
        await fixture.finish()
        #expect(fixture.presenter.bulkRenameRequests.count == 1)
        #expect(fixture.names(in: fixture.root) == ["a.txt", "b.txt", "sub"])
        #expect(!fixture.state.commandStack.canUndo)
    }

    @Test("シークレットウインドウでは一括リネームの入力を保存しない(そのウインドウの間は覚える)")
    func bulkRenameSettingsAreNotSavedInPrivateWindows() async throws {
        let fixture = try Fixture("fbops-bulk-private")
        fixture.state.isPrivate = true
        try Data("b".utf8).write(to: fixture.root.appendingPathComponent("b.txt"))
        await fixture.showRoot()
        fixture.presenter.bulkRenameAnswer = Self.counterAnswer("P")
        fixture.state.operations.bulkRename(["a.txt", "b.txt"].map { fixture.entry(fixture.root.appendingPathComponent($0)) })
        await fixture.finish()
        #expect(fixture.state.bulkRenameSettings == Self.counterAnswer("P"))
        #expect(FileBrowserState(defaults: fixture.suite.defaults).bulkRenameSettings == BulkRenameSettings())
    }

    @Test("使えない名前ができるなら報告して何も変えない。変わらない項目だけなら何もしない")
    func bulkRenameRefusesInvalidNames() async throws {
        let fixture = try Fixture("fbops-bulk-invalid")
        try Data("b".utf8).write(to: fixture.root.appendingPathComponent("ba.txt"))
        await fixture.showRoot()
        let targets = ["a.txt", "ba.txt"].map { fixture.entry(fixture.root.appendingPathComponent($0)) }
        var settings = BulkRenameSettings()
        settings.find = "a"
        settings.replaceWith = ""
        fixture.presenter.bulkRenameAnswer = settings
        fixture.state.operations.bulkRename(targets)
        await fixture.finish()
        // a.txt → 「.txt」(先頭がドット)。Finder と同じく、ba.txt も含めて何も変えない。
        #expect(fixture.names(in: fixture.root) == ["a.txt", "ba.txt", "sub"])
        #expect(fixture.presenter.problems.count == 1)

        settings.find = "zzz"
        fixture.presenter.bulkRenameAnswer = settings
        fixture.state.operations.bulkRename(targets)
        await fixture.finish()
        #expect(!fixture.state.commandStack.canUndo)
        #expect(fixture.presenter.problems.count == 1)
    }

    @Test("一括リネームでロックされた項目は尋ね、「ロックされた項目をスキップ」なら残りだけ変える")
    func bulkRenameAsksAboutLockedItems() async throws {
        let fixture = try Fixture("fbops-bulk-locked")
        let file = fixture.root.appendingPathComponent("a.txt")
        try Data("b".utf8).write(to: fixture.root.appendingPathComponent("b.txt"))
        await fixture.showRoot()
        FileOperationService.setLocked(file, true)
        defer { FileOperationService.setLocked(file, false) }
        fixture.presenter.bulkRenameAnswer = Self.counterAnswer("F")
        fixture.presenter.lockedAnswer = .skipLocked
        fixture.state.operations.bulkRename(["a.txt", "b.txt"].map { fixture.entry(fixture.root.appendingPathComponent($0)) })
        await fixture.finish()
        #expect(fixture.presenter.lockedPrompts.map(\.urls) == [[file]])
        #expect(fixture.presenter.lockedPrompts.map(\.totalCount) == [2])
        #expect(fixture.presenter.lockedPrompts.map(\.action) == [.rename])
        // 番号は全部で決めたまま(a.txt が 1 番、b.txt が 2 番)。
        #expect(fixture.names(in: fixture.root) == ["F00002.txt", "a.txt", "sub"])
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

    // MARK: - 読み取り専用モード(段階 8.5)

    @Test("読み取り専用モードの既定は ON。環境設定が届いていない窓口も断る側に倒す")
    func readOnlyIsOnByDefault() throws {
        let suite = PreferencesSuite(label: "fbops-readonly-default")
        #expect(suite.makePreferences().fileBrowserReadOnly)
        #expect(FileBrowserOperations().isReadOnly)
    }

    @Test("読み取り専用モードでは、ペースト・カット・ドロップ・ゴミ箱・新規フォルダ・名前の変更・一括リネーム・圧縮・展開が何もしない")
    func readOnlyRefusesEveryFileChange() async throws {
        let fixture = try Fixture("fbops-readonly")
        await fixture.showRoot()
        let file = fixture.root.appendingPathComponent("a.txt")
        try Data("b".utf8).write(to: fixture.root.appendingPathComponent("b.txt"))
        var builder = ZipFixtureBuilder()
        builder.add("001.png", text: "1")
        let archive = fixture.root.appendingPathComponent("book.cbz")
        try builder.write(to: archive)
        fixture.presenter.bulkRenameAnswer = BulkRenameSettings()
        fixture.presenter.confirmsDeletion = true
        let before = (root: fixture.names(in: fixture.root), sub: fixture.names(in: fixture.sub), other: fixture.names(in: fixture.other))
        fixture.preferences.fileBrowserReadOnly = true

        // ⌘C は断らない(ペーストボードへ載せるだけ)。載せたものを貼ろうとしても貼られない。
        fixture.state.operations.copy([fixture.entry(file)])
        #expect(fixture.state.operations.canPaste)
        fixture.state.operations.paste(into: fixture.other)
        fixture.state.operations.paste(into: fixture.other, forceMove: true)
        // カットは記憶しない。
        fixture.state.operations.cut([fixture.entry(file)])
        #expect(fixture.state.cutPaths.isEmpty)
        fixture.state.operations.transfer([file], to: fixture.other, isMove: true)
        fixture.state.operations.drop(FileDropPlan(moves: [file], copies: []), into: fixture.sub)
        fixture.state.operations.moveToTrash([fixture.entry(file)])
        fixture.state.operations.newFolder(in: fixture.root)
        fixture.state.operations.rename(fixture.entry(file), to: "renamed.txt")
        fixture.state.operations.bulkRename(["a.txt", "b.txt"].map { fixture.entry(fixture.root.appendingPathComponent($0)) })
        fixture.state.operations.compress([fixture.entry(fixture.sub)])
        fixture.state.operations.extract([fixture.entry(archive)], placement: .ownFolder)
        await fixture.finish()

        #expect(fixture.names(in: fixture.root) == before.root)
        #expect(fixture.names(in: fixture.sub) == before.sub)
        #expect(fixture.names(in: fixture.other) == before.other)
        #expect(fixture.names(in: fixture.trash).isEmpty)
        #expect(!fixture.state.commandStack.canUndo)
        // 尋ねもしない(シート・確認を出さない)。
        #expect(fixture.presenter.bulkRenameRequests.isEmpty)
        #expect(fixture.presenter.deletionPrompts.isEmpty)
        #expect(fixture.presenter.conflicts.isEmpty)
        #expect(fixture.presenter.problems.isEmpty)
    }

    @Test("読み取り専用モードの間は取り消し/やり直しを断るが、履歴は残り、OFF に戻すと使える")
    func readOnlyKeepsUndoHistory() async throws {
        let fixture = try Fixture("fbops-readonly-undo")
        await fixture.showRoot()
        let file = fixture.root.appendingPathComponent("a.txt")
        let renamed = fixture.root.appendingPathComponent("renamed.txt")
        fixture.state.operations.rename(fixture.entry(file), to: "renamed.txt")
        await fixture.finish()
        #expect(fixture.exists(renamed))

        fixture.preferences.fileBrowserReadOnly = true
        fixture.state.operations.undo()
        await fixture.finish()
        #expect(fixture.exists(renamed))
        #expect(fixture.state.commandStack.canUndo)

        fixture.preferences.fileBrowserReadOnly = false
        fixture.state.operations.undo()
        await fixture.finish()
        #expect(fixture.exists(file))
        #expect(fixture.state.commandStack.canRedo)

        fixture.preferences.fileBrowserReadOnly = true
        fixture.state.operations.redo()
        await fixture.finish()
        #expect(fixture.exists(file))
        #expect(!fixture.exists(renamed))
    }

    @Test("読み取り専用モードは走っている操作を止めず、次の操作から効く")
    func readOnlyAppliesFromTheNextOperation() async throws {
        let fixture = try Fixture("fbops-readonly-running")
        await fixture.showRoot()
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.copy([fixture.entry(file)])
        fixture.state.operations.paste(into: fixture.other)
        fixture.preferences.fileBrowserReadOnly = true
        fixture.state.operations.paste(into: fixture.sub)
        await fixture.finish()
        #expect(fixture.names(in: fixture.other) == ["a.txt"])
        #expect(fixture.names(in: fixture.sub).isEmpty)
    }

    // MARK: - 圧縮・展開(段階 6)

    @Test("ここに圧縮: 環境設定の拡張子で同じフォルダに作り、選ぶ。取り消すと zip だけがゴミ箱へ")
    func compressHereAndUndo() async throws {
        let fixture = try Fixture("fbops-compress")
        fixture.preferences.fileBrowserCompressionFormat = .cbz
        await fixture.showRoot()
        let sub = fixture.sub
        try Data("page".utf8).write(to: sub.appendingPathComponent("001.jpg"))

        fixture.state.operations.compress([fixture.entry(sub)])
        await fixture.finish()
        let zip = fixture.root.appendingPathComponent("sub.cbz")
        #expect(fixture.exists(zip))
        #expect(fixture.state.selection == [FileBrowserState.id(for: zip)])
        #expect(fixture.state.commandStack.undoTitle?.contains("sub") == true)
        #expect(fixture.presenter.problems.isEmpty)

        fixture.state.operations.undo()
        await fixture.finish()
        #expect(!fixture.exists(zip))
        #expect(fixture.names(in: fixture.trash) == ["sub.cbz"])
        #expect(fixture.exists(sub.appendingPathComponent("001.jpg")))
    }

    @Test("〈名前〉に展開: 書庫の名前のフォルダを作り、取り消すとそのフォルダがゴミ箱へ。書庫でない項目は外す")
    func extractToOwnFolderAndUndo() async throws {
        let fixture = try Fixture("fbops-extract")
        await fixture.showRoot()
        var builder = ZipFixtureBuilder()
        builder.add("001.png", text: "1")
        builder.add("002.png", text: "2")
        let archive = fixture.root.appendingPathComponent("book.cbz")
        try builder.write(to: archive)

        fixture.state.operations.extract(
            [fixture.entry(archive), fixture.entry(fixture.root.appendingPathComponent("a.txt"))], placement: .ownFolder
        )
        await fixture.finish()
        let folder = fixture.root.appendingPathComponent("book")
        #expect(fixture.names(in: folder) == ["001.png", "002.png"])
        #expect(fixture.state.selection == [FileBrowserState.id(for: folder)])
        #expect(fixture.presenter.problems.isEmpty)

        fixture.state.operations.undo()
        await fixture.finish()
        #expect(!fixture.exists(folder))
        #expect(fixture.names(in: fixture.trash) == ["book"])
        #expect(fixture.exists(archive))
    }

    @Test("展開先を選んで展開…: 選んだフォルダへ中身を並べる。キャンセルなら何もしない")
    func extractToChosenFolder() async throws {
        let fixture = try Fixture("fbops-extract-to")
        var builder = ZipFixtureBuilder()
        builder.add("x/1.txt", text: "1")
        let archive = fixture.root.appendingPathComponent("pack.zip")
        try builder.write(to: archive)

        fixture.presenter.chosenFolder = nil
        fixture.state.operations.extract([fixture.entry(archive)], placement: .contents, choosingDestination: true)
        await fixture.finish()
        #expect(fixture.presenter.folderChoices == [.extract(count: 1)])
        #expect(fixture.names(in: fixture.other).isEmpty)
        #expect(!fixture.state.commandStack.canUndo)

        fixture.presenter.chosenFolder = fixture.other
        fixture.state.operations.extract([fixture.entry(archive)], placement: .contents, choosingDestination: true)
        await fixture.finish()
        #expect(fixture.names(in: fixture.other) == ["x"])
        #expect(fixture.state.commandStack.canUndo)
    }

    @Test("危険なエントリを捨てた展開は、済んだうえで捨てたものを報告に並べる")
    func extractReportsRejectedEntries() async throws {
        let fixture = try Fixture("fbops-extract-slip")
        var builder = ZipFixtureBuilder()
        builder.add("ok.txt", text: "ok")
        builder.add("../evil.txt", text: "evil")
        let archive = fixture.root.appendingPathComponent("slip.zip")
        try builder.write(to: archive)

        fixture.state.operations.extract([fixture.entry(archive)], placement: .contents)
        await fixture.finish()
        #expect(fixture.exists(fixture.root.appendingPathComponent("ok.txt")))
        #expect(!fixture.exists(fixture.temporary.url.appendingPathComponent("evil.txt")))
        #expect(fixture.presenter.problems.count == 1)
        #expect(fixture.presenter.problems.first?.message.contains("../evil.txt") == true)
        #expect(fixture.state.commandStack.canUndo)
    }

    @Test("メニューの判定: 圧縮は同じフォルダの項目、展開は全部が書庫のときだけ")
    func archiveMenuAvailability() throws {
        let fixture = try Fixture("fbops-archive-menu")
        let actions = FileBrowserActions()
        actions.state = fixture.state
        let archive = fixture.entry(fixture.root.appendingPathComponent("book.cbz"))
        let text = fixture.entry(fixture.root.appendingPathComponent("a.txt"))
        let elsewhere = fixture.entry(fixture.other)
        #expect(actions.canCompress([archive, text]))
        #expect(!actions.canCompress([text, elsewhere]))
        #expect(actions.canExtract([archive]))
        #expect(!actions.canExtract([archive, text]))
        let context = FileBrowserMenuContext(kind: .file, entries: [archive], folder: fixture.root)
        #expect(FileBrowserMenuCommand.extract.submenu == [.extractHere, .extractToFolder, .extractTo])
        #expect(FileBrowserMenuCommand.extractToFolder.title(in: context, locale: Locale(identifier: "en")) == "Extract to “book”")
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

    @Test("操作の名前を入れる題はかぎ括弧で囲まない(名前の側が「…」の展開 のように括弧を持つので、重なって「「…」の展開」になった)")
    func operationNameTitlesDoNotNestQuotes() {
        let ja = Locale(identifier: "ja")
        let name = String(format: String(localized: "Extraction of “%@”", language: ja), "slip.zip")
        let titles: [String.LocalizationValue] = [
            "%@: Some items couldn’t be processed.", "%@ couldn’t be completed.", "%@ was stopped, but some items couldn’t be put back.",
            "%@ could only be partly undone.", "%@ could only be partly redone.", "%@ couldn’t be undone.", "%@ couldn’t be redone.",
        ]
        for title in titles {
            let text = String(format: String(localized: title, language: ja), name)
            #expect(text.hasPrefix("「slip.zip」の展開"), "\(text)")
            #expect(!text.contains("「「"), "\(text)")
        }
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

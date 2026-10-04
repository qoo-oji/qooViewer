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
        private(set) var deletionReasons: [ImmediateDeletionReason] = []
        private(set) var lockedPrompts: [(urls: [URL], totalCount: Int, action: LockedItemAction)] = []
        private(set) var conflicts: [FileConflict] = []
        /// 尋ねたときの「置き換えるとすぐに消える」の値(衝突 1 件ごと)。
        private(set) var replacingDeletesImmediately: [Bool] = []
        private(set) var problems: [FileBrowserProblem] = []

        /// 「すぐに削除されます」の確認が出ている間に起こすこと(別のウインドウで本を開くなど)。
        var whileDeletionPromptIsUp: (() -> Void)?

        func confirmImmediateDeletion(of urls: [URL], reason: ImmediateDeletionReason) async -> Bool {
            deletionPrompts.append(urls)
            deletionReasons.append(reason)
            whileDeletionPromptIsUp?()
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

    @Test("移動とコピーが混ざったドロップの題は「移動とコピー」(2026-10-04 の監査 FBA-12。以前は「コピー」だった)")
    func mixedTransfersHaveANeutralTitle() {
        typealias Kind = FileBrowserOperations.TransferKind
        #expect(Kind(moves: true, copies: false) == .move)
        #expect(Kind(moves: false, copies: true) == .copy)
        #expect(Kind(moves: true, copies: true) == .moveAndCopy)
        let english = Locale(identifier: "en")
        #expect(FileBrowserOperations.transferName(count: 3, kind: .moveAndCopy, locale: english) == "Move and Copy of 3 Items")
        #expect(FileBrowserOperations.activityTitle(count: 3, kind: .moveAndCopy, locale: english) == "Moving and copying 3 items…")
        #expect(FileBrowserOperations.transferName(count: 2, kind: .move, locale: english) == "Move of 2 Items")
        #expect(FileBrowserOperations.activityTitle(count: 2, kind: .copy, locale: english) == "Copying 2 items…")
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
        #expect(fixture.presenter.deletionReasons == [.noTrash])
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

    @Test("「すぐに削除…」はゴミ箱のある場所でも必ず確認し、断れば何も消えない")
    func deleteImmediatelyAsksEvenWithTrash() async throws {
        let fixture = try Fixture("fbops-delete-now-cancel")
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.presenter.confirmsDeletion = false
        fixture.state.operations.deleteImmediately([fixture.entry(file)])
        await fixture.finish()
        #expect(fixture.presenter.deletionPrompts == [[file]])
        #expect(fixture.presenter.deletionReasons == [.requested])
        #expect(fixture.exists(file))
    }

    @Test("「すぐに削除…」を承諾するとゴミ箱を経ずに完全に削除し、取り消しには積まない")
    func deleteImmediatelyBypassesTrash() async throws {
        let fixture = try Fixture("fbops-delete-now")
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.presenter.confirmsDeletion = true
        fixture.state.operations.deleteImmediately([fixture.entry(file)])
        await fixture.finish()
        #expect(!fixture.exists(file))
        #expect(fixture.names(in: fixture.trash).isEmpty)
        #expect(!fixture.state.commandStack.canUndo)
        #expect(fixture.presenter.problems.isEmpty)
    }

    @Test("確認を出している間に別のウインドウで開いた本は、承諾しても消さない(2026-09-23 の 3 回目の監査の中 7)")
    func deleteImmediatelyRechecksOpenBooksAfterTheConfirmation() async throws {
        let fixture = try Fixture("fbops-delete-now-opened")
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.presenter.confirmsDeletion = true
        fixture.presenter.whileDeletionPromptIsUp = { [weak state = fixture.state, path = file.path] in
            state?.operations.openBookPaths = { [path] }
        }
        fixture.state.operations.deleteImmediately([fixture.entry(file)])
        await fixture.finish()
        #expect(fixture.presenter.deletionPrompts == [[file]])
        #expect(fixture.exists(file), "確認の間に開いた本を消した")
        #expect(fixture.presenter.problems.count == 1)
    }

    @Test("「すぐに削除…」はボリュームそのもの(マウントポイント)を確認の前に断る(2026-09-23 の 3 回目の監査の高 1)")
    func deleteImmediatelyRefusesAVolume() async throws {
        guard let volume = DisposableVolume.make(.apfs, "fbops-delete-volume") else { return }
        let fixture = try Fixture("fbops-delete-volume")
        fixture.presenter.confirmsDeletion = true
        fixture.state.operations.deleteImmediately([fixture.entry(volume.mountPoint)])
        await fixture.finish()
        #expect(fixture.presenter.deletionPrompts.isEmpty, "確認を出した")
        #expect(fixture.presenter.problems.count == 1)
        #expect(FileManager.default.fileExists(atPath: volume.url.path))
    }

    /// 2026-10-04 の監査 FBA-11(実測: 書き込めない親の中のフォルダは、中身を全部消した後で「削除できませんでした」になった)。
    @Test("親に書けない項目は淡色で、「すぐに削除…」は確認を出す前に断って何も消さない。書けるようになれば淡色が解ける")
    func deleteImmediatelyRefusesItemsInAReadOnlyFolder() async throws {
        let fixture = try Fixture("fbops-delete-readonly")
        let child = try fixture.temporary.directory("root/sub/child")
        let inside = child.appendingPathComponent("1.txt")
        try Data("1".utf8).write(to: inside)
        fixture.presenter.confirmsDeletion = true
        chmod(fixture.sub.path, 0o555)
        defer { chmod(fixture.sub.path, 0o755) }
        fixture.state.navigate(to: fixture.sub)
        await fixture.state.settle()
        let actions = FileBrowserActions()
        actions.state = fixture.state
        #expect(!fixture.state.isCurrentFolderWritable)
        #expect(!actions.canChange([fixture.entry(child)]))

        fixture.state.operations.deleteImmediately([fixture.entry(child)])
        await fixture.finish()
        #expect(fixture.presenter.deletionPrompts.isEmpty, "確認を出した")
        #expect(fixture.presenter.problems.count == 1)
        #expect(fixture.exists(inside), "中身が消えた")

        chmod(fixture.sub.path, 0o755)
        fixture.state.reload()
        await fixture.state.settle()
        #expect(fixture.state.isCurrentFolderWritable)
        #expect(actions.canChange([fixture.entry(child)]))
    }

    @Test("macOS が要るフォルダ(ホームとその標準のフォルダ)は、ツリーの根でなくても淡色(2026-10-04 の監査 FBA-11)")
    func protectedLocationsAreDimmed() async throws {
        let fixture = try Fixture("fbops-protected")
        let actions = FileBrowserActions()
        actions.state = fixture.state
        // 判定はパスの文字列だけ(ホームの中には触らない)。
        let home = FileBrowserListing.realHomeDirectory()
        #expect(!actions.canChange([fixture.entry(home)]))
        #expect(!actions.canChange([fixture.entry(home.appendingPathComponent("Documents", isDirectory: true))]))
        #expect(actions.canChange([fixture.entry(fixture.root.appendingPathComponent("a.txt"))]))
    }

    // MARK: - 衝突の「置き換える」と開いている本(2026-10-04 の監査 FBA-1・決定 17)

    @MainActor
    private final class OpenBookPaths {
        var paths: [String] = []
    }

    @Test("「置き換える」の相手が開いている本なら、その項目だけ置き換えずに報告し、残りは置き換える ―― 「すべてに適用」の 2 件目も")
    func replacingAnOpenBookIsSkippedAndReported() async throws {
        let fixture = try Fixture("fbops-replace-open")
        let a = fixture.root.appendingPathComponent("a.txt")
        let b = fixture.root.appendingPathComponent("b.txt")
        try Data("b".utf8).write(to: b)
        let existingA = fixture.other.appendingPathComponent("a.txt")
        let existingB = fixture.other.appendingPathComponent("b.txt")
        try Data("old a".utf8).write(to: existingA)
        try Data("old b".utf8).write(to: existingB)
        let open = OpenBookPaths()
        open.paths = [existingB.path]
        fixture.state.operations.openBookPaths = { open.paths }
        // 1 件目の確認で「すべてに適用」+「置き換える」。2 件目(開いている本)は確認を通らずに置き換えへ進む道。
        fixture.presenter.conflictAnswer = ConflictDecision(.replace, applyToRemaining: true)

        fixture.state.operations.transfer([a, b], to: fixture.other, isMove: false)
        await fixture.finish()
        #expect(fixture.presenter.conflicts.count == 1)
        #expect(try String(contentsOf: existingA, encoding: .utf8) == "a")
        #expect(try String(contentsOf: existingB, encoding: .utf8) == "old b", "開いている本が置き換わった")
        #expect(fixture.names(in: fixture.trash) == ["a.txt"])
        #expect(fixture.names(in: fixture.other) == ["a.txt", "b.txt"], "退避用の隠しフォルダが残っている")
        #expect(fixture.presenter.problems.count == 1)
        #expect(fixture.presenter.problems.first?.message.contains(
            FileOperationError.replacingOpenBook(existingB).localizedDescription
        ) == true)
    }

    @Test("やり直しの「置き換える」も、その間に開いた本は置き換えない")
    func redoDoesNotReplaceAnOpenBook() async throws {
        let fixture = try Fixture("fbops-replace-open-redo")
        let file = fixture.root.appendingPathComponent("a.txt")
        let existing = fixture.other.appendingPathComponent("a.txt")
        try Data("other".utf8).write(to: existing)
        let open = OpenBookPaths()
        fixture.state.operations.openBookPaths = { open.paths }
        fixture.presenter.conflictAnswer = ConflictDecision(.replace)
        fixture.state.operations.transfer([file], to: fixture.other, isMove: false)
        await fixture.finish()
        #expect(try String(contentsOf: existing, encoding: .utf8) == "a")
        fixture.state.operations.undo()
        await fixture.finish()
        #expect(try String(contentsOf: existing, encoding: .utf8) == "other")

        open.paths = [existing.path]
        fixture.state.operations.redo()
        await fixture.finish()
        #expect(try String(contentsOf: existing, encoding: .utf8) == "other", "やり直しが開いている本を置き換えた")
        #expect(fixture.presenter.problems.count == 1)
    }

    // MARK: - 綴りだけ違う同じ項目(2026-10-04 のレビュー R3-1)
    //
    // 一時フォルダは起動ボリューム(APFS、大文字小文字を区別しない既定)の上。宛先は運ぶ元の綴りのまま届き、衝突は lstat で見るので、
    // 綴りの違う同じ項目が「置き換える」の相手になる。以前の守りは綴りどおりの文字列の比べで、開いている本を退避してゴミ箱へ送った。

    /// 一時フォルダが大文字小文字を区別しないボリュームの上にあること(このテストの前提)。
    private func requireCaseInsensitiveVolume(_ folder: URL) throws {
        let values = try folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        try #require(values.volumeSupportsCaseSensitiveNames == false, "一時フォルダが大文字小文字を区別するボリュームにある")
    }

    @Test("「置き換える」の相手が、大文字小文字だけ違う綴りで届いた開いている本なら、置き換えずに報告する")
    func replacingAnOpenBookSpelledInAnotherCaseIsRefused() async throws {
        let fixture = try Fixture("fbops-replace-open-case")
        try requireCaseInsensitiveVolume(fixture.other)
        let source = fixture.root.appendingPathComponent("BOOK.zip")
        try Data("new".utf8).write(to: source)
        let open = fixture.other.appendingPathComponent("Book.zip")
        try Data("open".utf8).write(to: open)
        fixture.state.operations.openBookPaths = { [open.path] }
        fixture.presenter.conflictAnswer = ConflictDecision(.replace)

        fixture.state.operations.transfer([source], to: fixture.other, isMove: true)
        await fixture.finish()
        #expect(fixture.presenter.conflicts.count == 1)
        #expect(fixture.names(in: fixture.other) == ["Book.zip"], "開いている本が置き換わった(または退避が残った)")
        #expect(try String(contentsOf: open, encoding: .utf8) == "open")
        #expect(fixture.names(in: fixture.trash).isEmpty, "開いている本をゴミ箱へ送った")
        #expect(fixture.exists(source), "置き換えなかった項目を動かした")
        #expect(fixture.presenter.problems.count == 1)
    }

    @Test("「置き換える」の相手が、NFC/NFD だけ違う綴りで届いた開いている本なら、置き換えずに報告する")
    func replacingAnOpenBookSpelledInAnotherNormalizationIsRefused() async throws {
        let fixture = try Fixture("fbops-replace-open-nfd")
        try requireCaseInsensitiveVolume(fixture.other)
        let nfd = "Cafe\u{301}.zip"
        let nfc = "Caf\u{E9}.zip"
        #expect(Array(nfd.utf8) != Array(nfc.utf8))
        let open = fixture.other.appendingPathComponent(nfd)
        try Data("open".utf8).write(to: open)
        let source = fixture.root.appendingPathComponent(nfc)
        try Data("new".utf8).write(to: source)
        fixture.state.operations.openBookPaths = { [open.path] }
        fixture.presenter.conflictAnswer = ConflictDecision(.replace)

        fixture.state.operations.transfer([source], to: fixture.other, isMove: false)
        await fixture.finish()
        #expect(fixture.presenter.conflicts.count == 1)
        #expect(fixture.names(in: fixture.other).count == 1)
        #expect(try String(contentsOf: open, encoding: .utf8) == "open", "開いている本が置き換わった")
        #expect(fixture.names(in: fixture.trash).isEmpty, "開いている本をゴミ箱へ送った")
        #expect(fixture.presenter.problems.count == 1)
    }

    @Test("「置き換える」の相手が、開いている本を含むフォルダの綴り違いでも、置き換えずに報告する")
    func replacingAFolderHoldingAnOpenBookSpelledInAnotherCaseIsRefused() async throws {
        let fixture = try Fixture("fbops-replace-open-case-folder")
        try requireCaseInsensitiveVolume(fixture.other)
        let shelf = try fixture.temporary.directory("other/Shelf")
        let open = shelf.appendingPathComponent("Book.zip")
        try Data("open".utf8).write(to: open)
        let source = try fixture.temporary.directory("root/shelf")
        try Data("x".utf8).write(to: source.appendingPathComponent("x.txt"))
        fixture.state.operations.openBookPaths = { [open.path] }
        fixture.presenter.conflictAnswer = ConflictDecision(.replace)

        fixture.state.operations.transfer([source], to: fixture.other, isMove: false)
        await fixture.finish()
        #expect(fixture.presenter.conflicts.count == 1)
        #expect(fixture.names(in: fixture.other) == ["Shelf"], "開いている本を含むフォルダが置き換わった")
        #expect(try String(contentsOf: open, encoding: .utf8) == "open")
        #expect(fixture.names(in: fixture.trash).isEmpty)
        #expect(fixture.presenter.problems.count == 1)
    }

    @Test("「置き換える」の相手が、開いているフォルダの本の中の項目なら、宛先のフォルダを綴り違いで指しても置き換えずに報告する")
    func replacingAnItemInsideAnOpenFolderBookSpelledInAnotherCaseIsRefused() async throws {
        let fixture = try Fixture("fbops-replace-open-case-inside")
        try requireCaseInsensitiveVolume(fixture.other)
        let book = try fixture.temporary.directory("other/Book")
        let page = book.appendingPathComponent("p1.jpg")
        try Data("page".utf8).write(to: page)
        let source = fixture.root.appendingPathComponent("P1.JPG")
        try Data("new".utf8).write(to: source)
        fixture.state.operations.openBookPaths = { [book.path] }
        fixture.presenter.conflictAnswer = ConflictDecision(.replace)
        // 「フォルダへ移動」で打ち込んだ綴りで開いたフォルダへのドロップ(宛先のフォルダの綴りもディスクと違う)。
        let typedBook = fixture.other.appendingPathComponent("BOOK", isDirectory: true)

        fixture.state.operations.transfer([source], to: typedBook, isMove: false)
        await fixture.finish()
        #expect(fixture.presenter.conflicts.count == 1)
        #expect(fixture.names(in: book) == ["p1.jpg"], "開いている本のページが置き換わった")
        #expect(try String(contentsOf: page, encoding: .utf8) == "page")
        #expect(fixture.names(in: fixture.trash).isEmpty)
        #expect(fixture.presenter.problems.count == 1)
    }

    @Test("綴りだけ違う自分自身への移動は、尋ねずに何もしない(運ぶ元を退避しない)")
    func movingAnItemOntoItselfSpelledInAnotherCaseDoesNothing() async throws {
        let fixture = try Fixture("fbops-move-self-case")
        try requireCaseInsensitiveVolume(fixture.root)
        let file = fixture.root.appendingPathComponent("a.txt")
        let typedRoot = fixture.temporary.url.appendingPathComponent("ROOT", isDirectory: true)
        fixture.presenter.conflictAnswer = ConflictDecision(.replace)

        fixture.state.operations.transfer([file], to: typedRoot, isMove: true)
        await fixture.finish()
        #expect(fixture.presenter.conflicts.isEmpty, "自分自身との衝突を尋ねた")
        #expect(fixture.names(in: fixture.root) == ["a.txt", "sub"], "運ぶ元を退避した(または隠しフォルダが残った)")
        #expect(try String(contentsOf: file, encoding: .utf8) == "a")
        #expect(fixture.names(in: fixture.trash).isEmpty)
        #expect(fixture.presenter.problems.isEmpty)
    }

    @Test("名前の変更・ゴミ箱も、打ち込んだ綴りのフォルダの一覧から開いている本を当てる(ファイルに触らずに)")
    func openBookConflictFoldsSpelling() async throws {
        let fixture = try Fixture("fbops-open-case")
        try requireCaseInsensitiveVolume(fixture.root)
        let open = fixture.root.appendingPathComponent("a.txt")
        let typed = fixture.temporary.url.appendingPathComponent("ROOT/A.TXT")
        #expect(FileBrowserOperations.openBookConflict(among: [typed], openBookPaths: [open.path]) == typed)
        // 開いている本を含むフォルダ・その中の項目も、綴りによらず当たる。
        let typedFolder = fixture.temporary.url.appendingPathComponent("Root", isDirectory: true)
        #expect(FileBrowserOperations.openBookConflict(among: [typedFolder], openBookPaths: [open.path]) == typedFolder)
        #expect(FileBrowserOperations.openBookConflict(among: [typed], openBookPaths: [fixture.root.path]) == typed)
        #expect(FileBrowserOperations.openBookConflict(
            among: [fixture.root.appendingPathComponent("b.txt")], openBookPaths: [open.path]
        ) == nil)

        fixture.state.operations.openBookPaths = { [open.path] }
        fixture.state.operations.moveToTrash([fixture.entry(typed)])
        await fixture.finish()
        #expect(fixture.exists(open), "開いている本をゴミ箱へ送った")
        #expect(fixture.names(in: fixture.trash).isEmpty)
        #expect(fixture.presenter.problems.count == 1)
    }

    @Test("確認を出している間に重ねて頼んだ「すぐに削除…」は、先の操作で消えた項目について尋ねない")
    func queuedDeleteSkipsItemsAlreadyGone() async throws {
        let fixture = try Fixture("fbops-delete-now-queued")
        let file = fixture.root.appendingPathComponent("a.txt")
        let other = fixture.root.appendingPathComponent("b.txt")
        try Data("b".utf8).write(to: other)
        fixture.presenter.confirmsDeletion = true
        // 2026-09-23 の実機: 1 回目の確認が出ている間にメニューバーから同じ項目を頼むと、2 回目は列に並ぶ。
        fixture.state.operations.deleteImmediately([fixture.entry(file)])
        fixture.state.operations.deleteImmediately([fixture.entry(file), fixture.entry(other)])
        fixture.state.operations.deleteImmediately([fixture.entry(file)])
        await fixture.finish()
        // 2 回目はまだ在る b.txt だけを尋ね、3 回目は何も尋ねない。
        #expect(fixture.presenter.deletionPrompts == [[file], [other]])
        #expect(!fixture.exists(file))
        #expect(!fixture.exists(other))
        #expect(fixture.presenter.problems.isEmpty)
    }

    @Test("「すぐに削除…」では、中にロックされた項目があるフォルダも確認してから消す")
    func deleteImmediatelyAsksAboutLockedDescendants() async throws {
        let fixture = try Fixture("fbops-delete-now-locked")
        let inner = fixture.sub.appendingPathComponent("inner.txt")
        try Data("x".utf8).write(to: inner)
        FileOperationService.setLocked(inner, true)
        fixture.presenter.confirmsDeletion = true

        fixture.presenter.lockedAnswer = .stop
        fixture.state.operations.deleteImmediately([fixture.entry(fixture.sub)])
        await fixture.finish()
        #expect(fixture.presenter.lockedPrompts.map(\.action) == [.deleteImmediately])
        #expect(fixture.exists(inner))

        fixture.presenter.lockedAnswer = .proceed
        fixture.state.operations.deleteImmediately([fixture.entry(fixture.sub)])
        await fixture.finish()
        #expect(!fixture.exists(fixture.sub))
        #expect(fixture.names(in: fixture.trash).isEmpty)
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

    @Test("走っている・並んでいる操作は終了の確認のために数えられ、終われば数から外れる")
    func operationsAreCountedForTheQuitConfirmation() async throws {
        let fixture = try Fixture("fbops-running-work")
        await fixture.showRoot()
        // 共有の RunningWorkRegistry には触れない(テストでは既定が nil)。自分の数え先を渡す。
        #expect(fixture.state.operations.runningWork == nil)
        let registry = RunningWorkRegistry()
        fixture.state.operations.runningWork = registry

        fixture.state.operations.newFolder(in: fixture.root)
        fixture.state.operations.newFolder(in: fixture.root)
        #expect(registry.hasRunningWork)
        await fixture.finish()
        #expect(!registry.hasRunningWork)
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

    // MARK: - エイリアスを作成(2026-10-01)

    @Test("エイリアスは元の隣に Finder と同じ名前で作り、元を指す。作ったものを選び、取り消すとゴミ箱へ。2 つ目は番号付き")
    func makeAliasPlacesFinderNamedAliasesAndUndoes() async throws {
        let fixture = try Fixture("fbops-alias")
        await fixture.showRoot()
        let file = fixture.root.appendingPathComponent("a.txt")
        // 言葉は OS の言語で変わる(CI の機械は英語)。窓口(下の 2 つ目)と同じく OS の言語で作り、名前は規則から求める
        // (言語ごとの名前の規則は FinderAliasNameTests)。
        let localization = FinderAliasName.finderLocalization()
        let command = MakeAliasesCommand(items: [file, fixture.sub], localization: localization, fileOps: fixture.state.operations.fileOps)
        _ = try await fixture.state.commandStack.run(command)
        let fileAliasName = FinderAliasName.baseName(displayName: "a.txt", localization: localization)
        let fileAlias = fixture.root.appendingPathComponent(fileAliasName)
        let folderAlias = fixture.root.appendingPathComponent(FinderAliasName.baseName(displayName: "sub", localization: localization))
        #expect(command.receipts.map(\.destination.lastPathComponent) == [fileAlias.lastPathComponent, folderAlias.lastPathComponent])
        for (alias, original) in [(fileAlias, file), (folderAlias, fixture.sub)] {
            let values = try alias.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
            #expect(values.isAliasFile == true && values.isSymbolicLink == false)
            let target = try URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting])
            #expect(target.standardizedFileURL.path == original.standardizedFileURL.path)
        }
        // 書く途中の一時ファイルは残さない。
        #expect(!fixture.names(in: fixture.root).contains { $0.hasPrefix(FileOperationService.aliasTemporaryFilePrefix) })

        // 窓口から: 作ったものが選ばれ、取り消すと作ったものだけがゴミ箱へ(元はそのまま)。
        fixture.state.operations.makeAliases([fixture.entry(file)])
        await fixture.finish()
        let second = FinderAliasName.candidate(base: fileAliasName, number: 2)
        #expect(fixture.exists(fixture.root.appendingPathComponent(second)))
        #expect(fixture.state.selection == [FileBrowserState.id(for: fixture.root.appendingPathComponent(second))])
        #expect(fixture.presenter.problems.isEmpty)
        fixture.state.operations.undo()
        await fixture.finish()
        #expect(!fixture.exists(fixture.root.appendingPathComponent(second)))
        #expect(fixture.exists(file) && fixture.exists(fileAlias))
        #expect(fixture.names(in: fixture.trash).count == 1)
    }

    @Test("エイリアスを作れなかった項目は報告し、作れたものは残す")
    func makeAliasReportsMissingItems() async throws {
        let fixture = try Fixture("fbops-alias-missing")
        await fixture.showRoot()
        let file = fixture.root.appendingPathComponent("a.txt")
        let gone = fixture.root.appendingPathComponent("gone.txt")
        let command = MakeAliasesCommand(items: [gone, file], localization: "en", fileOps: fixture.state.operations.fileOps)
        let result = try await fixture.state.commandStack.run(command)
        guard case let .partial(succeeded, failures, _) = result else {
            Issue.record("一部だけ済んだことにならなかった: \(String(describing: result))")
            return
        }
        #expect(succeeded == 1)
        #expect(failures.map(\.name) == ["gone.txt"])
        #expect(fixture.exists(fixture.root.appendingPathComponent("a.txt alias")))
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

    @Test("読み取り専用モードでは、ペースト・カット・ドロップ・ゴミ箱・新規フォルダ・名前の変更・一括リネーム・圧縮・展開・エイリアスの作成が何もしない")
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
        fixture.state.operations.deleteImmediately([fixture.entry(file)])
        fixture.state.operations.newFolder(in: fixture.root)
        fixture.state.operations.rename(fixture.entry(file), to: "renamed.txt")
        fixture.state.operations.bulkRename(["a.txt", "b.txt"].map { fixture.entry(fixture.root.appendingPathComponent($0)) })
        fixture.state.operations.compress([fixture.entry(fixture.sub)])
        fixture.state.operations.extract([fixture.entry(archive)], placement: .ownFolder)
        fixture.state.operations.makeAliases([fixture.entry(file)])
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

    /// 2026-09-23、利用者の決定: ON にするのは「ここから先はファイルを変えない」なので、並んでいた操作が後から確認を出したり
    /// 変えたりしない。以前は「受け付けた操作は最後までやる」で、並んでいた「すぐに削除…」が ON の後に確認を出し、承諾すれば消した。
    @Test("読み取り専用を ON にしたら、順番を待っている操作は始めない", arguments: [true, false])
    func readOnlyDropsQueuedOperations(turnsFeatureOff: Bool) async throws {
        let fixture = try Fixture("fbops-readonly-queued")
        // 確認が出てしまえば「削除」と答える(出ないことを確かめる)。
        fixture.presenter.confirmsDeletion = true
        await fixture.showRoot()
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.copy([fixture.entry(file)])
        fixture.state.operations.paste(into: fixture.other)
        // 前のペーストの後ろに並ぶ。
        fixture.state.operations.deleteImmediately([fixture.entry(file)])
        if turnsFeatureOff { fixture.preferences.fileBrowserFeatureEnabled = false } else { fixture.preferences.fileBrowserReadOnly = true }
        await fixture.finish()
        #expect(fixture.names(in: fixture.other) == ["a.txt"])
        #expect(fixture.exists(file))
        #expect(fixture.presenter.deletionPrompts.isEmpty)
    }

    /// 確認はどれもファイルに触る前なので、出す前に ON になっていたら出さずに断る(以前は「出す前から断る状態」なら通していた)。
    @Test("確認を出す前に読み取り専用になっていたら、確認を出さずに断る")
    func readOnlyRefusesBeforeAskingConfirmation() async throws {
        let fixture = try Fixture("fbops-readonly-before-ask")
        fixture.presenter.confirmsDeletion = true
        await fixture.showRoot()
        let file = fixture.root.appendingPathComponent("a.txt")
        fixture.state.operations.deleteImmediately([fixture.entry(file)])
        fixture.preferences.fileBrowserReadOnly = true
        await fixture.finish()
        #expect(fixture.exists(file))
        #expect(fixture.presenter.deletionPrompts.isEmpty)
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

    /// 2026-10-04 の監査 FBA-3(「最近の項目」で別々のフォルダの項目を選ぶと「N 項目の名前を変更…」が押せるのに何も起きなかった)。
    @Test("メニューの判定: 名前の変更は、複数なら同じフォルダの項目だけ(一括リネームが断る条件と同じ)")
    func renameMenuAvailability() throws {
        let fixture = try Fixture("fbops-rename-menu")
        let actions = FileBrowserActions()
        actions.state = fixture.state
        let text = fixture.entry(fixture.root.appendingPathComponent("a.txt"))
        let sub = fixture.entry(fixture.sub)
        let elsewhere = fixture.entry(fixture.other)
        #expect(actions.canRename([text]))
        #expect(actions.canRename([elsewhere]))
        #expect(actions.canRename([text, sub]))
        #expect(!actions.canRename([text, elsewhere]))
        let mixed = FileBrowserMenuContext(kind: .file, entries: [text, elsewhere], folder: fixture.root)
        #expect(!FileBrowserMenuCommand.rename.isEnabled(in: mixed, actions: actions))
        let together = FileBrowserMenuContext(kind: .file, entries: [text, sub], folder: fixture.root)
        #expect(FileBrowserMenuCommand.rename.isEnabled(in: together, actions: actions))
    }

    // MARK: - 進捗・報告

    /// 2026-10-04 の監査 FBA-6。以前は中止なら失敗を全部捨て、止める前の本当の失敗も報告しなかった(やり直しの中止は見せていた)。
    @Test("中止で止めた操作も、止める前の本当の失敗は報告する。手を付けなかった項目だけは並べない")
    func cancelledRunStillReportsRealFailures() {
        let failed = FailedItem(url: URL(fileURLWithPath: "/tmp/failed.txt"), reason: "Permission denied.")
        let untouched = FailedItem(url: URL(fileURLWithPath: "/tmp/untouched.txt"), reason: FileCommandStack.notProcessedReason)
        let cancelled = FileCommandResult.partial(succeeded: 1, failures: [failed, untouched], wasCancelled: true)
        let problem = FileBrowserProblem.afterRun(cancelled, operationName: "Copy")
        #expect(problem != nil)
        #expect(problem?.message.contains("failed.txt") == true)
        #expect(problem?.message.contains("untouched.txt") == false)
        let onlyUntouched = FileCommandResult.partial(succeeded: 1, failures: [untouched], wasCancelled: true)
        #expect(FileBrowserProblem.afterRun(onlyUntouched, operationName: "Copy") == nil)
        let notCancelled = FileCommandResult.partial(succeeded: 1, failures: [failed, untouched], wasCancelled: false)
        #expect(FileBrowserProblem.afterRun(notCancelled, operationName: "Copy")?.message.contains("untouched.txt") == true)
        #expect(FileBrowserProblem.afterRun(.success, operationName: "Copy") == nil)
    }

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

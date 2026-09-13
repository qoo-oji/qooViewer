import AppKit
import Foundation
import Testing

@testable import qooViewer

/// ドラッグ&ドロップの判定(Models/FileDropPlan.swift と FileBrowserDragAndDrop.swift の FileBrowserDropDecision)。
/// ファイルシステムに触らない純粋な判定なので、実在しないパスで確かめる。「同じボリュームか」は
/// `/Volumes/Other` の下かどうかで答える偽物を渡す。
@MainActor
struct FileDropPlanTests {
    private static let home = URL(fileURLWithPath: "/tmp/qooDropPlan/home", isDirectory: true)
    private static let other = URL(fileURLWithPath: "/Volumes/XOther/inbox", isDirectory: true)

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        a.path.hasPrefix("/Volumes/XOther") == b.path.hasPrefix("/Volumes/XOther")
    }

    private static func plan(
        _ items: [URL], to destination: URL, _ modifiers: FileDropPlan.Modifiers = [], allowsMove: Bool = true
    ) -> FileDropPlan? {
        FileDropPlan.make(
            items: items, destination: destination, modifiers: modifiers, allowsMove: allowsMove,
            isOnSameVolume: sameVolume
        )
    }

    private let file = home.appendingPathComponent("a.txt")
    private let folder = home.appendingPathComponent("sub", isDirectory: true)

    @Test("修飾キーなし: 同じボリュームなら移動、別のボリュームへはコピー")
    func defaultFollowsVolume() {
        #expect(Self.plan([file], to: folder) == FileDropPlan(moves: [file], copies: []))
        #expect(Self.plan([file], to: Self.other) == FileDropPlan(moves: [], copies: [file]))
    }

    @Test("⌥ は常にコピー、⌘ は常に移動、⌥⌘ は修飾なしと同じ")
    func modifiersForceOperation() {
        #expect(Self.plan([file], to: folder, .option) == FileDropPlan(moves: [], copies: [file]))
        #expect(Self.plan([file], to: Self.other, .command) == FileDropPlan(moves: [file], copies: []))
        #expect(Self.plan([file], to: Self.other, [.option, .command]) == FileDropPlan(moves: [], copies: [file]))
    }

    @Test("ドラッグ元が移動を許さなければ、⌘ でもコピー")
    func sourceWithoutMoveCopies() {
        #expect(Self.plan([file], to: folder, .command, allowsMove: false) == FileDropPlan(moves: [], copies: [file]))
    }

    @Test("フォルダを自分自身・自分の中へは落とさせない(1件でも混ざれば全体を断る)")
    func refusesDropIntoItself() {
        #expect(Self.plan([folder], to: folder) == nil)
        #expect(Self.plan([file, folder], to: folder.appendingPathComponent("deeper", isDirectory: true)) == nil)
        // 名前の前方一致だけで「中」と見なさない(sub と sub2)。
        let sibling = Self.home.appendingPathComponent("sub2", isDirectory: true)
        #expect(Self.plan([folder], to: sibling) == FileDropPlan(moves: [folder], copies: []))
    }

    @Test("自分のフォルダへの移動は外し、全部そうなら断る。⌥ のコピーは複製として残す")
    func sameFolderMoveIsNoOp() {
        let second = folder.appendingPathComponent("b.txt")
        #expect(Self.plan([file], to: Self.home) == nil)
        #expect(Self.plan([file, second], to: Self.home) == FileDropPlan(moves: [second], copies: []))
        #expect(Self.plan([file], to: Self.home, .option) == FileDropPlan(moves: [], copies: [file]))
        // 末尾の / の有無で別のフォルダに化けない。
        #expect(Self.plan([file], to: URL(fileURLWithPath: Self.home.path + "/")) == nil)
    }

    @Test("移動とコピーが混ざると、カーソルはコピー")
    func mixedShowsCopy() throws {
        let away = URL(fileURLWithPath: "/Volumes/XOther/x.txt")
        let plan = try #require(Self.plan([file, away], to: folder))
        #expect(plan.moves == [file])
        #expect(plan.copies == [away])
        #expect(!plan.isMove)
    }

    // MARK: - FileBrowserDropDecision

    private func decision(
        _ urls: [URL], to destination: URL?, isInternal: Bool, action: FileBrowserExternalDropAction
    ) -> FileBrowserDropDecision {
        FileBrowserDropDecision.make(
            urls: urls, destination: destination, isInternal: isInternal, allowsMove: true, modifiers: [],
            externalAction: action, isOnSameVolume: Self.sameVolume
        )
    }

    @Test("他のアプリからのドロップは、環境設定が「ビューアで開く」なら行き先によらず開く")
    func externalDropOpensByDefault() {
        #expect(decision([file], to: folder, isInternal: false, action: .openInViewer) == .openInViewer)
        #expect(decision([], to: nil, isInternal: false, action: .openInViewer) == .openInViewer)
    }

    @Test("「コピー・移動」なら他のアプリからもアプリの中と同じ規則。アプリの中のドラッグは設定に関係なく運ぶ")
    func externalDropTransfersWhenChosen() {
        let expected = FileBrowserDropDecision.transfer(FileDropPlan(moves: [file], copies: []), into: folder)
        #expect(decision([file], to: folder, isInternal: false, action: .copyOrMove) == expected)
        #expect(decision([file], to: folder, isInternal: true, action: .openInViewer) == expected)
    }

    @Test("コンピュータ(行き先なし)へは運ばない")
    func refusesComputer() {
        #expect(decision([file], to: nil, isInternal: true, action: .copyOrMove) == .refuse)
    }

    @Test("カーソルの操作: 移動は元が許せば move、⌘ で generic だけに絞られていれば generic。断るなら無し")
    func dragOperations() {
        let move = FileBrowserDropDecision.transfer(FileDropPlan(moves: [file], copies: []), into: folder)
        let copy = FileBrowserDropDecision.transfer(FileDropPlan(moves: [], copies: [file]), into: folder)
        #expect(move.dragOperation(sourceMask: [.copy, .move, .generic]) == .move)
        #expect(move.dragOperation(sourceMask: .generic) == .generic)
        #expect(copy.dragOperation(sourceMask: [.copy, .move]) == .copy)
        #expect(FileBrowserDropDecision.refuse.dragOperation(sourceMask: .every) == [])
        #expect(FileBrowserDropDecision.openInViewer.dragOperation(sourceMask: .every) == .generic)
        #expect(NSDragOperation.generic.allowsFileMove)
        #expect(!NSDragOperation.copy.allowsFileMove)
    }
}

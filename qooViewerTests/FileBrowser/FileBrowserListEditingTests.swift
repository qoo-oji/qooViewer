import AppKit
import Foundation
import Testing

@testable import qooViewer

/// リスト表示の名前の編集と一覧の読み直しの行き違い(Views/FileBrowser/FileBrowserListView.swift の Coordinator)。
///
/// `NSHostingView` には載せない ―― `makeNSView` が表に `autosaveName` を付け、列の幅を `UserDefaults.standard` へ書くので、
/// 表は自分で組み、Coordinator だけを本物で動かす。フィールドエディタが要るので画面に出さないウインドウに入れる。
@MainActor
struct FileBrowserListEditingTests {
    @Test("名前の編集中に一覧が読み直されても、編集していた項目の名前を変える(同じ行に来た別の項目を変えない)")
    func renameTargetsTheEditedItemEvenIfTheListChangesMeanwhile() async throws {
        // 2026-09-14 の監査の 5: 以前は編集中に `entries` だけを差し替え、確定で古い行番号から新しい一覧を引いて別のファイルの名前を変えた。
        let temporary = try TemporaryDirectory("fb-list-edit")
        let suite = PreferencesSuite(label: "fb-list-edit")
        let preferences = suite.makePreferences()
        preferences.fileBrowserReadOnly = false
        let state = FileBrowserState(defaults: suite.defaults)
        state.preferences = preferences
        let presenter = FileBrowserOperationsTests.ScriptedPresenter()
        state.operations.presenter = presenter
        state.operations.fileOps = FileOperationService(environment: .pseudoTrash(at: try temporary.directory("PseudoTrash")))
        let root = try temporary.directory("root")
        try Data("b".utf8).write(to: root.appendingPathComponent("b.txt"))
        try Data("c".utf8).write(to: root.appendingPathComponent("c.txt"))
        state.navigate(to: root)
        await state.settle()

        let actions = FileBrowserActions()
        actions.state = state
        let view = FileBrowserListView(
            state: state, actions: actions, outlineWidth: 0, locale: Locale(identifier: "en"),
            wheelScrollRows: 3, onWholeListDropTargetChange: { _ in }
        )
        let coordinator = FileBrowserListView.Coordinator()
        let table = FileBrowserTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let column = NSTableColumn(identifier: FileBrowserListView.Column.name.identifier)
        column.width = 380
        table.addTableColumn(column)
        table.rowHeight = 22
        table.dataSource = coordinator
        table.delegate = coordinator
        table.editResponder = actions
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = table
        defer {
            table.dataSource = nil
            table.delegate = nil
            window.close()
        }
        coordinator.table = table
        coordinator.update(from: view)
        #expect(table.numberOfRows == 2)

        // c.txt(2 行目)の名前の編集を始める。
        state.requestRename(FileBrowserState.id(for: root.appendingPathComponent("c.txt")))
        coordinator.update(from: view)
        let editor = try #require(window.firstResponder as? NSTextView, "編集が始まっていない")
        #expect(editor.string == "c.txt")

        // 編集中に a.txt が現れて一覧が読み直される(2 行目は b.txt になる)。
        try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
        state.reload()
        await state.settle()
        #expect(state.entries.map(\.url.lastPathComponent) == ["a.txt", "b.txt", "c.txt"])
        coordinator.update(from: view)
        #expect(window.firstResponder === editor, "読み直しで編集が消えない")

        editor.string = "renamed.txt"
        window.makeFirstResponder(table)
        await state.operations.settle()

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(names == ["a.txt", "b.txt", "renamed.txt"])
        #expect(presenter.problems.isEmpty)
        // 待たせていた一覧は編集の後で取り込まれている。
        #expect(table.numberOfRows >= 3)
    }
}

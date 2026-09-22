import AppKit
import Foundation
import Testing

@testable import qooViewer

/// 名前の編集を始めてよいか・続けてよいか(Views/FileBrowser/FileBrowserNameEditing.swift、2026-09-19)。
///
/// 報告: リストで選ばれているファイルをフォルダへドラッグして移動したら、移動したファイルの名前の編集が始まり、編集を終えるまで
/// 一覧に残った。ドラッグと AppKit の遅延実行の行き違いそのものはテストでは作れないので、「名前の欄はふだん編集できない」
/// 「無い項目では始めない」「編集中に消えたら取りやめる」の 3 つをリストとアイコン表示の両方で確かめる。
/// 一覧は `FileBrowserListEditingTests` と同じく自分で組み、Coordinator だけを本物で動かす。
@MainActor
struct FileBrowserNameEditingTests {
    // MARK: 決まり

    @Test("始めてよいのは、書ける状態で、画面が状態に追いついていて、ディスクにある項目だけ")
    func canBeginRequiresWritableCurrentExistingItem() async throws {
        let fixture = try await Fixture(label: "fb-name-gate", files: ["a.txt"])
        let entry = try #require(fixture.state.entries.first)
        let folder = fixture.state.currentFolder

        #expect(FileBrowserNameEditing.canBegin(entry, displayedFolder: folder, state: fixture.state, allowsFileChanges: true))
        #expect(!FileBrowserNameEditing.canBegin(entry, displayedFolder: folder, state: fixture.state, allowsFileChanges: false),
                "読み取り専用モードで始まる")
        #expect(!FileBrowserNameEditing.canBegin(
            entry, displayedFolder: folder?.deletingLastPathComponent(), state: fixture.state, allowsFileChanges: true
        ), "画面が別のフォルダの一覧のまま始まる")
        #expect(!FileBrowserNameEditing.canBegin(
            entry, displayedFolder: folder, state: fixture.state, allowsFileChanges: true, itemExists: { _ in false }
        ), "ディスクから消えた項目で始まる")
    }

    @Test("名前のクリックの予約は、待ち終わると始まり、取りやめれば始まらない")
    func nameClickReservationFiresOrCancels() async throws {
        let reservation = FileBrowserNameClickRename()
        // 待ち時間は使わない(テスト全体を流すとメインアクタが混んで、固定の待ちでは足りなかった)。すぐ戻る待ちにして、
        // 取りやめは待ちが戻る前に行う(Task はメインアクタで走るので、この関数が await するまで待ちに入らない)。
        reservation.wait = {}
        var fired = 0
        let first = reservation.schedule { fired += 1 }
        #expect(reservation.isPending)
        await first.value
        #expect(fired == 1)
        #expect(!reservation.isPending)

        let cancelled = reservation.schedule { fired += 1 }
        reservation.cancel()
        await cancelled.value
        #expect(fired == 1, "取りやめた予約で編集が始まった")
        #expect(!reservation.isPending)

        // 予約し直すと前の予約は消える(ダブルクリックの間隔の中で 2 回予約しても 1 回だけ)。
        let replaced = reservation.schedule { fired += 1 }
        let latest = reservation.schedule { fired += 1 }
        await replaced.value
        await latest.value
        #expect(fired == 2)
    }

    // MARK: リスト

    @Test("リストの名前の欄は、編集中のほかは編集できない欄(AppKit が自分で編集を始めない)")
    func listNameFieldsAreNotEditableAtRest() async throws {
        let fixture = try await Fixture(label: "fb-name-list-rest", files: ["a.txt", "b.txt"])
        let list = try ListHarness(fixture: fixture)
        defer { list.close() }

        for row in 0..<list.table.numberOfRows {
            let field = try #require(list.nameField(row: row))
            #expect(!field.isEditable, "\(row) 行目の名前の欄が編集できる")
        }

        fixture.state.requestRename(fixture.id("b.txt"))
        list.update()
        let editor = try #require(list.window.firstResponder as? NSTextView, "依頼から編集が始まらない")
        #expect(editor.string == "b.txt")

        list.window.makeFirstResponder(list.table)
        await fixture.state.operations.settle()
        for row in 0..<list.table.numberOfRows {
            #expect(list.nameField(row: row)?.isEditable == false, "編集を終えた欄が編集できるまま残った")
        }
    }

    @Test("リストは、ディスクから消えた項目(一覧はまだ古い)の名前の編集を始めない")
    func listRefusesToEditVanishedItem() async throws {
        let fixture = try await Fixture(label: "fb-name-list-stale", files: ["a.txt", "b.txt"])
        let list = try ListHarness(fixture: fixture)
        defer { list.close() }

        // ドラッグで別のフォルダへ移した直後(一覧の読み直しはまだ)。
        try FileManager.default.moveItem(at: fixture.url("b.txt"), to: fixture.url("dest/b.txt"))
        fixture.state.requestRename(fixture.id("b.txt"))
        list.update()
        #expect(!(list.window.firstResponder is NSTextView), "もう無いファイルの名前の編集が始まった")
    }

    @Test("リストは、編集中の項目が一覧から消えたら編集を取りやめ、名前を変えずに一覧を取り込む")
    func listCancelsEditingWhenTheItemVanishes() async throws {
        let fixture = try await Fixture(label: "fb-name-list-vanish", files: ["a.txt", "b.txt"])
        let list = try ListHarness(fixture: fixture)
        defer { list.close() }

        fixture.state.requestRename(fixture.id("b.txt"))
        list.update()
        let editor = try #require(list.window.firstResponder as? NSTextView)
        editor.string = "typed.txt"

        try FileManager.default.moveItem(at: fixture.url("b.txt"), to: fixture.url("dest/b.txt"))
        fixture.state.reload()
        await fixture.state.settle()
        list.update()
        // 取りやめは次のランループで(SwiftUI の更新の最中に状態を変えない)。
        try await Task.sleep(for: .milliseconds(50))
        await fixture.state.operations.settle()

        #expect(!(list.window.firstResponder is NSTextView), "消えた項目の編集が残った")
        #expect(list.table.numberOfRows == 2, "消えた項目が一覧に残った(a.txt と dest の 2 行のはず)")
        #expect(fixture.names() == ["a.txt", "dest"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url("dest").path) == ["b.txt"], "移した先で名前が変わった")
        #expect(fixture.presenter.problems.isEmpty)
    }

    @Test("絞り込み中に新規フォルダを作ると、絞り込みを解いてすぐ名前の編集を始める(依頼を残して後で始めない)")
    func newFolderUnderAFilterClearsTheFilterAndEditsNow() async throws {
        // 2026-09-19 の監査の M3: 以前は作ったフォルダが絞り込みで見えず、依頼が残り、後で絞り込みを解いた時点で編集が始まった(実測)。
        let fixture = try await Fixture(label: "fb-name-filter", files: ["abc.txt"])
        let list = try ListHarness(fixture: fixture)
        defer { list.close() }
        fixture.state.filterText = "abc"
        list.update()

        await fixture.state.operations.newFolder(in: fixture.root).value
        await fixture.state.settle()
        list.update()
        #expect(fixture.state.filterText.isEmpty)
        let editor = try #require(list.window.firstResponder as? NSTextView, "作ったフォルダの名前の編集が始まらない")
        #expect(fixture.names().contains(editor.string))
    }

    @Test("名前の編集の依頼は、読み終えた一覧に相手が無ければ捨てる(後で同じパスに項目ができても始めない)")
    func aRenameRequestForAMissingItemIsDropped() async throws {
        let fixture = try await Fixture(label: "fb-name-dropped", files: ["a.txt"])
        fixture.state.requestRename(fixture.id("ghost.txt"))
        await fixture.state.settle()
        #expect(fixture.state.renameRequest == nil)
    }

    // MARK: アイコン表示

    @Test("アイコン表示は、ディスクから消えた項目(一覧はまだ古い)の名前の編集を始めない")
    func iconRefusesToEditVanishedItem() async throws {
        let fixture = try await Fixture(label: "fb-name-icon-stale", files: ["a.txt", "b.txt"])
        let icons = try IconHarness(fixture: fixture)
        defer { icons.close() }

        try FileManager.default.moveItem(at: fixture.url("b.txt"), to: fixture.url("dest/b.txt"))
        fixture.state.requestRename(fixture.id("b.txt"))
        icons.update()
        #expect(!(icons.window.firstResponder is NSTextView), "もう無いファイルの名前の編集が始まった")
    }

    @Test("アイコン表示は、編集中の項目が一覧から消えたら編集を取りやめ、名前を変えずに一覧を取り込む")
    func iconCancelsEditingWhenTheItemVanishes() async throws {
        let fixture = try await Fixture(label: "fb-name-icon-vanish", files: ["a.txt", "b.txt"])
        let icons = try IconHarness(fixture: fixture)
        defer { icons.close() }

        fixture.state.requestRename(fixture.id("b.txt"))
        icons.update()
        let editor = try #require(icons.window.firstResponder as? NSTextView, "依頼から編集が始まらない")
        editor.string = "typed.txt"

        try FileManager.default.moveItem(at: fixture.url("b.txt"), to: fixture.url("dest/b.txt"))
        fixture.state.reload()
        await fixture.state.settle()
        icons.update()
        try await Task.sleep(for: .milliseconds(50))
        await fixture.state.operations.settle()

        #expect(!(icons.window.firstResponder is NSTextView), "消えた項目の編集が残った")
        #expect(icons.collection.numberOfItems(inSection: 0) == 2, "消えた項目が一覧に残った")
        #expect(fixture.names() == ["a.txt", "dest"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url("dest").path) == ["b.txt"], "移した先で名前が変わった")
        #expect(fixture.presenter.problems.isEmpty)
    }

    // MARK: - 部品

    /// 書ける状態のファイルブラウザと、`root`(ファイル + 移し先の `dest` フォルダ)。
    @MainActor
    final class Fixture {
        let temporary: TemporaryDirectory
        let suite: PreferencesSuite
        /// `FileBrowserState.preferences` は弱い参照なので、ここで持っておく(手放すと読み取り専用モードに戻る)。
        let preferences: AppPreferences
        let state: FileBrowserState
        let actions = FileBrowserActions()
        let presenter = FileBrowserOperationsTests.ScriptedPresenter()
        let root: URL

        init(label: String, files: [String]) async throws {
            temporary = try TemporaryDirectory(label)
            suite = PreferencesSuite(label: label)
            preferences = suite.makePreferences()
            preferences.fileBrowserReadOnly = false
            state = FileBrowserState(defaults: suite.defaults)
            state.preferences = preferences
            state.operations.presenter = presenter
            state.operations.fileOps = FileOperationService(environment: .pseudoTrash(at: try temporary.directory("PseudoTrash")))
            root = try temporary.directory("root")
            for name in files { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("dest"), withIntermediateDirectories: false)
            actions.state = state
            state.navigate(to: root)
            await state.settle()
        }

        func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
        func id(_ relative: String) -> String { FileBrowserState.id(for: url(relative)) }
        func names() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted() }
    }

    /// 画面に出さないウインドウに入れたリスト(フィールドエディタが要る)。
    @MainActor
    struct ListHarness {
        let view: FileBrowserListView
        let coordinator = FileBrowserListView.Coordinator()
        let table = FileBrowserTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)

        init(fixture: Fixture) throws {
            view = FileBrowserListView(
                state: fixture.state, actions: fixture.actions, outlineWidth: 0, locale: Locale(identifier: "en"),
                wheelScrollRows: 3, onWholeListDropTargetChange: { _ in }
            )
            let column = NSTableColumn(identifier: FileBrowserListView.Column.name.identifier)
            column.width = 380
            table.addTableColumn(column)
            table.rowHeight = 22
            table.dataSource = coordinator
            table.delegate = coordinator
            table.editResponder = fixture.actions
            window.isReleasedWhenClosed = false
            window.contentView = table
            coordinator.table = table
            coordinator.update(from: view)
        }

        func update() { coordinator.update(from: view) }

        func nameField(row: Int) -> FileBrowserNameField? {
            (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileBrowserCellView)?.nameField
        }

        func close() {
            coordinator.nameClickRename.cancel()
            table.dataSource = nil
            table.delegate = nil
            window.close()
        }
    }

    /// 画面に出さないウインドウに入れたアイコン表示(`makeNSView` と同じ組み立て。`NSHostingView` には載せない)。
    @MainActor
    struct IconHarness {
        let view: FileBrowserIconView
        let coordinator = FileBrowserIconView.Coordinator()
        let collection = FileBrowserCollectionView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)

        init(fixture: Fixture) throws {
            let provider = FileBrowserThumbnailProvider(
                diskCache: FileBrowserThumbnailDiskCache(directory: fixture.temporary.file("thumbnails"))
            )
            view = FileBrowserIconView(
                state: fixture.state, actions: fixture.actions, thumbnails: provider, thumbnailRevision: 0, includesVideo: false,
                outlineWidth: 0, locale: Locale(identifier: "en"), wheelScrollRows: 1,
                onWholeViewDropTargetChange: { _ in }
            )
            let layout = FileBrowserIconLayout()
            layout.spacing = FileBrowserIconView.spacing
            layout.inset = FileBrowserIconView.padding
            collection.collectionViewLayout = layout
            collection.isSelectable = true
            collection.allowsMultipleSelection = true
            collection.register(FileBrowserIconItem.self, forItemWithIdentifier: FileBrowserIconItem.identifier)
            collection.dataSource = coordinator
            collection.delegate = coordinator
            collection.handler = coordinator
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            scroll.documentView = collection
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            collection.frame = scroll.contentView.bounds
            coordinator.collection = collection
            coordinator.layout = layout
            coordinator.update(from: view)
            collection.layoutSubtreeIfNeeded()
        }

        func update() {
            coordinator.update(from: view)
            collection.layoutSubtreeIfNeeded()
        }

        func close() {
            coordinator.finishEditing(commit: false, syncsAfterward: false)
            coordinator.nameClickRename.cancel()
            for case let item as FileBrowserIconItem in collection.visibleItems() { item.cancelThumbnailRequest() }
            collection.dataSource = nil
            collection.delegate = nil
            collection.handler = nil
            window.close()
        }
    }
}

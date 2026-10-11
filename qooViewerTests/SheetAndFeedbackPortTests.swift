import AppKit
import Foundation
import Testing

@testable import qooViewer

/// 確認のアラート・パネルに答える口(`SheetScripting` / `ScriptedSheetResponder`、Views/WindowSheet.swift)と、ビープを数える口
/// (`UserFeedback.recorder`、Services/UserFeedback.swift)。2026-10-11 に足した。
///
/// どちらも TaskLocal なので、`withValue` の中で叩いた入口(と、その中で作った Task)にだけ効く ―― 並行して走るほかのテストの
/// シートやビープは混ざらない。
@MainActor
struct SheetAndFeedbackPortTests {
    private func makeFolderBook(in temporary: TemporaryDirectory, named name: String = "book") throws -> URL {
        let directory = temporary.file(name)
        try FixtureFolder.make(at: directory, pages: [.init("p01.png", number: 1), .init("p02.png", number: 2)])
        return directory
    }

    private func makeAppState(_ library: InMemoryLibrary) -> AppState {
        let state = AppState(isPrivateWindow: false, usesPageListCache: false)
        state.preferences = library.preferences
        state.favoritesStore = library.favorites
        state.bookmarkStore = library.bookmarks
        state.layoutStore = library.layouts
        state.metadataStore = library.metadata
        return state
    }

    // MARK: - パネル

    @Test("「開く…」のパネルで選んだ本が開く(パネルの文言とボタンも記録に残る)")
    func openPanelChoiceOpensTheBook() async throws {
        let library = try InMemoryLibrary(label: "sheet-open-panel")
        defer { library.close() }
        let temporary = try TemporaryDirectory("sheet-open-panel")
        let book = try makeFolderBook(in: temporary)
        let state = makeAppState(library)
        let responder = ScriptedSheetResponder(replies: [.choose([book])])

        SheetScripting.$responder.withValue(responder) {
            state.openWithPanel()
        }

        #expect(await eventually { @MainActor in state.currentBook?.id == book.path })
        await state.openTask?.value
        #expect(responder.presentations.map(\.kind) == [.openPanel])
        #expect(responder.presentations.first?.prompt?.isEmpty == false)
        state.closeBook()
    }

    @Test("「開く…」のパネルを取り消すと、何も開かない")
    func cancelledOpenPanelOpensNothing() async throws {
        let library = try InMemoryLibrary(label: "sheet-open-cancel")
        defer { library.close() }
        let state = makeAppState(library)
        let responder = ScriptedSheetResponder(replies: [.cancel])

        SheetScripting.$responder.withValue(responder) {
            state.openWithPanel()
        }

        #expect(responder.presentations.count == 1)
        #expect(state.currentBook == nil)
        #expect(state.openTask == nil)
    }

    @Test("テストホストの中では、答える役も出す先も無いシートは出さずにキャンセルで終わる(誰も閉じないシートを残さない)")
    func unscriptedSheetWithoutWindowIsRefusedInTheTestHost() async {
        let alert = NSAlert()
        alert.messageText = "unscripted"
        #expect(await WindowSheet.run(alert) == .cancel)
        #expect(await WindowSheet.chooseURLs(NSOpenPanel()) == nil)
    }

    // MARK: - アラート

    @Test("画像として読めないファイルを表紙にしようとすると、そのファイル名を挙げたアラートで知らせる")
    func coverFileFailureIsReportedWithAnAlert() async throws {
        let library = try InMemoryLibrary(label: "sheet-cover-failure")
        defer { library.close() }
        let temporary = try TemporaryDirectory("sheet-cover-failure")
        let bookURL = try makeFolderBook(in: temporary)
        let notAnImage = temporary.file("notes.jpg")
        try Data("not really a jpeg".utf8).write(to: notAnImage)
        let controller = CoverOverrideController(
            target: .collectionCover, layoutStore: library.layouts, preferences: library.preferences,
            resolveURL: { _ in bookURL }
        )
        let responder = ScriptedSheetResponder()

        let succeeded = await SheetScripting.$responder.withValue(responder) {
            await controller.setCoverFile(forBookID: bookURL.path, fileURL: notAnImage)
        }

        #expect(succeeded == false)
        let alert = try #require(responder.presentations.first)
        #expect(alert.kind == .alert)
        #expect(alert.messageText.contains("notes.jpg"))
    }

    // MARK: - ビープ

    /// 戻せない操作(相手が消えていた)。
    private final class FailingStep: DataUndoStep {
        var title: String { "step" }
        func undo() -> Bool { false }
        func redo() -> Bool { false }
        func discard() {}
    }

    @Test("戻せなかった取り消しはビープで知らせる(黙って何もしない、にならない)")
    func failedUndoBeeps() {
        let stack = DataUndoStack()
        stack.push(FailingStep())
        let recorder = FeedbackRecorder()

        UserFeedback.$recorder.withValue(recorder) {
            stack.undo()
        }

        #expect(recorder.beeps.count == 1)
        #expect(recorder.beeps.first?.fileID.hasSuffix("DataUndoStack.swift") == true)
        #expect(stack.undoTop == nil)
    }

    @Test("同じウインドウにシートが出ている間のパネルは、ビープしてキャンセルになる")
    func panelOverABusyWindowBeepsAndCancels() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false
        )
        sheet.isReleasedWhenClosed = false
        let presented = Task { await WindowSheet.run(sheetWindow: sheet, for: window) }
        #expect(await eventually { @MainActor in WindowSheet.placement(for: window) == .busy })

        let recorder = FeedbackRecorder()
        let response = await UserFeedback.$recorder.withValue(recorder) {
            await WindowSheet.run(NSSavePanel(), for: window)
        }
        #expect(response == .cancel)
        #expect(recorder.beeps.count == 1)

        window.endSheet(sheet, returnCode: .cancel)
        #expect(await presented.value == .cancel)
    }
}

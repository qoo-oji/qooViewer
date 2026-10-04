import AppKit
import Testing

@testable import qooViewer

/// `WindowSheet`(保存パネル・確認のアラートをウインドウのシートとして出す)。
@MainActor
struct WindowSheetTests {
    /// 答えを受け取る箱(待っている側が止まったままでもテストは終わるように、終わりは見回りで確かめる)。
    private final class ResponseBox {
        var response: NSApplication.ModalResponse?
    }

    @Test("シートを出したままウインドウが閉じられたら、Cancel で終わる(待っている側が止まったままにならない)")
    func closingTheHostEndsTheSheet() async throws {
        // 2026-09-27 の監査: シートの付いたウインドウに close() を呼ぶと AppKit は完了ハンドラを呼ばず、`run` の continuation が
        // 再開しなかった(ファイル操作の列が止まり、終了のたびに「作業中」の確認が出続けた)。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        // シートにならない(見えていない)と runModal でテストが止まるので、先に確かめる。
        try #require(WindowSheet.placement(for: window) == .sheet(window))

        let alert = NSAlert()
        alert.messageText = "probe"
        let box = ResponseBox()
        Task { box.response = await WindowSheet.run(alert, for: window) }
        for _ in 0..<200 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(window.attachedSheet != nil)

        window.close()
        for _ in 0..<200 where box.response == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(box.response == .cancel)
        #expect(window.attachedSheet == nil)
    }

    @Test("自前のシートのウインドウ(一括リネーム)も、出したままウインドウが閉じられたら Cancel で終わり、その間は上にパネルを重ねない(FBA-2)")
    func closingTheHostEndsAHandBuiltSheet() async throws {
        // 2026-10-04 の監査 FBA-2: 一括リネームのシートは `beginSheet` を直に呼んでいて、「すべてを閉じる」でウインドウが閉じると
        // 完了ハンドラが呼ばれず、ファイル操作の列が止まった。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try #require(WindowSheet.placement(for: window) == .sheet(window))

        let sheet = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true
        )
        sheet.isReleasedWhenClosed = false
        let box = ResponseBox()
        Task { box.response = await WindowSheet.run(sheetWindow: sheet, for: window) }
        for _ in 0..<200 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(window.attachedSheet === sheet)
        // 出している間は「ここで出したもの」に数え、同じウインドウへ 2 つ目のパネルを重ねさせない。
        #expect(WindowSheet.placement(for: window) == .busy)

        window.close()
        for _ in 0..<200 where box.response == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(box.response == .cancel)
        #expect(window.attachedSheet == nil)
    }
}

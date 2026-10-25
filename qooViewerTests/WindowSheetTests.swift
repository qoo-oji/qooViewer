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
        let window = TestWindows.window(size: NSSize(width: 480, height: 320), styleMask: [.titled, .closable], isShown: true)
        defer { window.orderOut(nil) }
        // シートにならない(見えていない)と runModal でテストが止まるので、先に確かめる。
        try #require(WindowSheet.placement(for: window) == .sheet(window))

        let alert = TestWindows.alert(messageText: "probe")
        let box = ResponseBox()
        Task { box.response = await WindowSheet.run(alert, for: window) }
        _ = await eventuallyHere { window.attachedSheet != nil }
        try #require(window.attachedSheet != nil)

        window.close()
        _ = await eventuallyHere { box.response != nil }
        #expect(box.response == .cancel)
        #expect(window.attachedSheet == nil)
    }

    @Test("自前のシートのウインドウ(一括リネーム)も、出したままウインドウが閉じられたら Cancel で終わり、その間は上にパネルを重ねない(FBA-2)")
    func closingTheHostEndsAHandBuiltSheet() async throws {
        // 2026-10-04 の監査 FBA-2: 一括リネームのシートは `beginSheet` を直に呼んでいて、「すべてを閉じる」でウインドウが閉じると
        // 完了ハンドラが呼ばれず、ファイル操作の列が止まった。
        let window = TestWindows.window(size: NSSize(width: 480, height: 320), styleMask: [.titled, .closable], isShown: true)
        defer { window.orderOut(nil) }
        try #require(WindowSheet.placement(for: window) == .sheet(window))

        let sheet = TestWindows.panel(size: NSSize(width: 300, height: 120))
        let box = ResponseBox()
        Task { box.response = await WindowSheet.run(sheetWindow: sheet, for: window) }
        _ = await eventuallyHere { window.attachedSheet != nil }
        try #require(window.attachedSheet === sheet)
        // 出している間は「ここで出したもの」に数え、同じウインドウへ 2 つ目のパネルを重ねさせない。
        #expect(WindowSheet.placement(for: window) == .busy)

        window.close()
        _ = await eventuallyHere { box.response != nil }
        #expect(box.response == .cancel)
        #expect(window.attachedSheet == nil)
    }
}

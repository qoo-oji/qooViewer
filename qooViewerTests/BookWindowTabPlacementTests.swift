import AppKit
import Testing

@testable import qooViewer

/// タブで開くウインドウを透明にする処理(`BookWindowOpener.applyPlacement`)。
///
/// ウインドウは画面に出さない(`addTabbedWindow`は見えていないウインドウ同士でもタブのまとまりを作る)。
@MainActor
struct BookWindowTabPlacementTests {
    private func makeWindow() -> NSWindow {
        let window = TestWindows.window(
            size: NSSize(width: 480, height: 320), styleMask: [.titled, .closable, .resizable], defer: true
        )
        window.tabbingIdentifier = "BookWindowTabPlacementTests-\(UUID().uuidString)"
        return window
    }

    @Test("タブへ入れた後に届いた「透明にする」は、ウインドウを消さない(元のタブはもう画面から外れている)")
    func hidingAfterTabbingIsIgnored() {
        // 2026-10-25 の報告: SMB のボリュームを「新規タブで開く」とウインドウ全体が消え、1〜2 秒後に出直した。タブへ入れる側が先に
        // 走ると、後から来た画面に出た知らせ・WindowAccessor が、もうタブになったウインドウを透明にしていた。
        let source = makeWindow()
        let newWindow = makeWindow()
        newWindow.tabbingIdentifier = source.tabbingIdentifier
        let sourceFrame = source.frame
        BookWindowOpener.revealIfHiddenUntilTabbed(newWindow)
        source.addTabbedWindow(newWindow, ordered: .above)
        #expect(BookWindowOpener.isTabbedWithOtherWindows(newWindow))

        BookWindowOpener.applyPlacement(
            frame: sourceFrame.offsetBy(dx: 40, dy: -40), hides: true, to: newWindow
        )
        #expect(newWindow.alphaValue == 1)
        #expect(newWindow.frame.origin == sourceFrame.origin)
    }

    @Test("タブへ入れる前なら、行き先を当てて透明にする(タブへ入れる直前に戻す)")
    func hidingBeforeTabbingStillApplies() {
        let newWindow = makeWindow()
        #expect(!BookWindowOpener.isTabbedWithOtherWindows(newWindow))
        let frame = NSRect(x: 100, y: 100, width: 600, height: 400)

        BookWindowOpener.applyPlacement(frame: frame, hides: true, to: newWindow)
        #expect(newWindow.alphaValue == 0)
        #expect(newWindow.frame == frame)

        BookWindowOpener.revealIfHiddenUntilTabbed(newWindow)
        #expect(newWindow.alphaValue == 1)
    }
}

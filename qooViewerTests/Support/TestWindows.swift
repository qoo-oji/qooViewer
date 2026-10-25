import AppKit

/// テストが作るウインドウ・シート・アラート。**利用者には見えないように作る**(2026-10-25)。テストのウインドウは必ずこれで作る
/// (`scripts/ci/check-test-windows.sh` が、ここ以外での `NSWindow(` / `NSPanel(` / `NSAlert(` / `orderFront` を断る)。
///
/// ■ なぜ
/// テストはアプリの中(TEST_HOST)で走るので、テストが `orderFront` したウインドウ・シートは、そのまま利用者の画面に出る。出ている
/// 長さは並行に走るほかのテストの混み具合で決まり(単独で 1.4 秒、全部を並べると 2 秒超)、手元の見張り(本物の確認ダイアログが
/// 出たらテストを止める)が試験用のウインドウを確認ダイアログと取り違えて、全テストを続けて止めた。見張りの閾値を延ばすのは
/// 場当たりで(混めばまた超える)、そもそも利用者の画面に試験のウインドウを見せる必要が無い。
///
/// ■ どう見えなくするか(2026-10-25 に単独の試し書きで実測)
/// - **透明にする**(`alphaValue = 0`)。シートは親が透明でも自分は不透明で出るので、**シートにするウインドウ・アラートの窓にも**
///   それぞれ 0 を入れる(入れておけば、シートを出す動きの後も 0 のまま。パネルのシート・NSAlert のシートとも確かめた)。
///   透明でも `isVisible` は true で、シートは付く(`WindowSheet.placement` が見るのは `isVisible` だけ)。
/// - クリックを受けない(`ignoresMouseEvents`)。透明な窓が利用者のクリックを横取りしないように。テストは実物のクリックを使わない。
/// - 画面の外に置くだけでは足りなかった: タイトルバーのあるウインドウは作った時点で AppKit が画面の中へ移し(`constrainFrameRect`
///   を止めても)、シートは親が画面の外にあっても画面の左下に出た。
enum TestWindows {
    /// ウインドウ。`isReleasedWhenClosed` は false(テストが持ち主)。
    /// - Parameter isShown: 出しておく(`orderFront`。シートを付けるテスト ―― 見えていないウインドウにはシートが付かない)。
    @MainActor
    static func window(
        size: NSSize, styleMask: NSWindow.StyleMask = [.titled], defer flag: Bool = false, isShown: Bool = false
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: styleMask, backing: .buffered, defer: flag
        )
        makeInvisible(window)
        if isShown { window.orderFront(nil) }
        return window
    }

    /// シートとして出すパネル(自前のシートのウインドウ ―― 一括リネームの形)。
    @MainActor
    static func panel(
        size: NSSize, styleMask: NSWindow.StyleMask = [.titled, .docModalWindow], defer flag: Bool = true
    ) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: styleMask, backing: .buffered, defer: flag
        )
        makeInvisible(panel)
        return panel
    }

    /// シートとして出すアラート(窓を透明にしてある)。
    @MainActor
    static func alert(messageText: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = messageText
        makeInvisible(alert.window)
        return alert
    }

    @MainActor
    private static func makeInvisible(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
    }
}

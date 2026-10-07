import AppKit
import SwiftUI

/// 本のウインドウ(ビューアとホーム)で、**ウインドウを前に出すクリックは前に出すだけ**にする(2026-10-07、ユーザー要望)。
/// ページは送らず、焦点も選択も動かさず、ボタンも押さない ―― macOS の標準(後ろのウインドウへの最初のクリックはウインドウを
/// アクティブにするだけ)に揃える。
///
/// ■ それまで
/// - SwiftUI の `NSHostingView` は `acceptsFirstMouse(for:)` が true なので、後ろのウインドウをクリックしただけで SwiftUI の
///   ボタン・タップ・選択がその場で働いた(ホームのグリッドの選択、帯のボタンなど)。ビューアのページ送りだけは、素の NSView
///   (`ClickZoneView`)を差し込んで個別に止めていた。
/// - AppKit は、クリックをビューへ渡さないとき(`acceptsFirstMouse` が false)でも**焦点だけはクリックされたビューへ移す**。
///   ファイルブラウザで右ペインを選んだまま後ろへ回り、ツリーの場所をクリックして戻すと焦点がツリーへ移り、右ペインの選択が
///   灰色になった。Finder は同じ操作で焦点を右ペインに残す(ユーザーが実機で確認)。
/// 部品ごとに止めると、新しい部品を足すたびに漏れる。そこでウインドウへ配られる前に、アプリで 1 か所で止める。
///
/// ■ 仕組み: そのクリックの間だけ、内容全体を何もしない覆いで受ける
/// 本のウインドウの内容のいちばん上に、ふだんは当たり判定に出てこない覆い(`WindowActivationClickShieldView`。
/// `acceptsFirstMouse` も `acceptsFirstResponder` も false)を重ねておく。アプリ全体のローカルモニタ(起動の最初に付ける)が
/// 内容領域への「前に出すクリック」(`WindowActivationClick.isActivationClick`)を見たら、ボタンを離すまで覆いを当たり判定に
/// 出す。押し下げそのものは**手を付けずに**流すので、AppKit は前に出すクリックとしてふつうに処理する(アプリを前面にし、
/// ウインドウをキーにする)が、当たるのは覆いなので、焦点は動かず、クリックもどの部品にも届かない。覆いは
/// `mouseDownCanMoveWindow` を false にしておく ―― 透明な NSView の既定(true)のままだと、覆いに当たった押し下げで
/// アプリが前面にならないことがあった(実測 2026-10-07、10 回に 3 回。false にした後は 35 回すべて前面になった)。
/// 押し下げはほかのローカルモニタにもそのまま届くので、クリックで何かをするモニタ(ページ一覧を閉じる・欄の焦点を外す)は
/// `isActivationClick(_:)` で見送る ―― 新しくそういうモニタを足すときも同じ。
///
/// **押し下げを捨てたり作り直したりしてはいけない**(実測 2026-10-07):
/// - モニタで捨てて自分で `NSApp.activate()` + `makeKeyAndOrderFront` すると、アプリは前面になるのにウインドウがキーに
///   ならないことがあった(12 回に 3 回。`keyWindow` は nil のまま)。キーにならないと次のクリックもまた「前に出すクリック」に
///   なり、選択も変えられなかった。
/// - 位置を付け替えた押し下げを `NSEvent.mouseEvent(with:location:…)` で作ると、アプリが前面にならないことがあった。元の
///   CGEvent を写して位置だけ書き換えると、`locationInWindow` がウインドウの外(-1, 1410)になった。
///
/// ■ 対象にしないもの
/// - タイトルバー・タブバー・ツールバー(内容領域の外。ウインドウを掴んで動かす、信号機のボタン、タブの切り替え)と、
///   ウインドウの縁(大きさを変える掴み所)
/// - 同じウインドウのポップオーバー・パネル(クイックルックなど)がキーのときのクリック(本のウインドウはメインのまま)
/// - 右クリック・⌃クリック・中ボタン(後ろのウインドウでもウインドウを前に出さずにメニューを開く。左クリックだけがウインドウを前に出す)
/// - 本のウインドウ以外(環境設定・道具のウインドウ・シート・パネル・ポップオーバー)。対象は覆いを置いたウインドウだけ
///
/// ■ 決めたこと
/// - 後ろのウインドウの内容からのドラッグ(ファイルブラウザの項目・ホームの本を Finder へ)は、ウインドウを前に出してからになる
///   (覆いが押し下げからドラッグまで受けるため。macOS の多くのアプリと同じ。Finder は後ろのウインドウからもドラッグできる)。
/// - ダブルクリックの 1 回目が「前に出すクリック」なら、2 回目はダブルクリックとして届く(ファイルブラウザ・ホームで開く)。
///   ホームの「クリック 1 回で開く」は 2 回目を捨てる決まりなので、1 回目が覆いで受けたものなら 2 回目を 1 回目として読む
///   (`firstClickWasActivation(of:)`)。
@MainActor
final class WindowActivationClickFilter {
    static let shared = WindowActivationClickFilter()

    /// 本のウインドウに置いた覆い(弱参照。閉じたウインドウのものは勝手に抜ける)。
    private let shields = NSHashTable<WindowActivationClickShieldView>.weakObjects()
    /// いま当たり判定に出している覆い(ボタンを離したら下ろす)。
    private weak var raisedShield: WindowActivationClickShieldView?
    /// 最後に覆いで受けた押し下げ(ダブルクリックの 1 回目だったかを後から問われる。`firstClickWasActivation(of:)`)。
    private var lastShieldedClick: (window: ObjectIdentifier, timestamp: TimeInterval)?
    /// アプリが最後に前面になった時刻 / 前面でなくなった時刻(`ProcessInfo.systemUptime`。`NSEvent.timestamp` と同じ起点)。
    /// ウインドウごとの時刻は覆いが持つ(`WindowActivationClickShieldView`)。
    private var appActivatedAt: TimeInterval = 0
    private var appDeactivatedAt: TimeInterval = 0
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    /// 起動の最初に呼ぶ(`AppDelegate.applicationWillFinishLaunching`)。二重には付けない。
    func install() {
        guard monitor == nil else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.appActivatedAt = ProcessInfo.processInfo.systemUptime }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.appDeactivatedAt = ProcessInfo.processInfo.systemUptime }
        })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseUp {
                self.lowerShieldAfterDispatch()
            } else {
                self.raiseShieldIfActivationClick(event)
            }
            return event
        }
    }

    /// 本のウインドウの内容領域への「前に出すクリック」か。覆いは押し下げそのものを止めないので、クリックの位置を見て何かを
    /// するほかのモニタ(ページ一覧を閉じる・欄の焦点を外す)は、これで見送る(モニタが呼ばれる順番には頼らない)。
    func isActivationClick(_ event: NSEvent) -> Bool {
        // 安い判定から(欄ごとのモニタが、ふつうのクリックのたびに呼ぶ)。
        guard event.type == .leftMouseDown, let window = event.window, window.attachedSheet == nil,
              let shield = shield(of: window),
              WindowActivationClick.isActivationClick(
                  eventType: event.type,
                  isControlClick: event.modifierFlags.contains(.control),
                  eventTimestamp: event.timestamp,
                  windowAppearsActive: window.isMainWindow && NSApp.isActive,
                  activatedAt: max(shield.becameMainAt, appActivatedAt),
                  deactivatedAt: max(shield.resignedMainAt, appDeactivatedAt)
              )
        else { return false }
        return Self.isInsideContent(event.locationInWindow, of: window)
    }

    /// ダブルクリックの 2 回目について、1 回目が覆いで受けた「前に出すクリック」だったか(ホームのグリッドの「クリック 1 回で
    /// 開く」は 2 回目を捨てるので、1 回目が届いていないときは 2 回目を 1 回目として読む ―― `HomeGridInteraction`)。
    func firstClickWasActivation(of event: NSEvent) -> Bool {
        guard event.clickCount >= 2, let window = event.window, let last = lastShieldedClick,
              last.window == ObjectIdentifier(window)
        else { return false }
        let interval = event.timestamp - last.timestamp
        return interval >= 0 && interval <= NSEvent.doubleClickInterval
    }

    fileprivate func register(_ shield: WindowActivationClickShieldView) {
        shields.add(shield)
    }

    private func shield(of window: NSWindow) -> WindowActivationClickShieldView? {
        shields.allObjects.first { $0.window === window }
    }

    private func raiseShieldIfActivationClick(_ event: NSEvent) {
        // 前の覆いが下ろし損ねて残っていても、新しい押し下げの前には必ず下ろす。
        lowerShield()
        guard isActivationClick(event), let window = event.window, let shield = shield(of: window) else { return }
        shield.isRaised = true
        // ほかのビューが覆いより上にあって覆いに当たらないなら、出しても意味が無い(下ろして、いつもどおり流す)。
        guard let frameView = window.contentView?.superview,
              frameView.hitTest(frameView.convert(event.locationInWindow, from: nil)) === shield
        else {
            shield.isRaised = false
            return
        }
        raisedShield = shield
        lastShieldedClick = (ObjectIdentifier(window), event.timestamp)
        scheduleStrandedShieldCheck(shield)
    }

    /// 離すイベントを見損ねても(入れ子の追跡ループが食べた・ほかのウインドウへ配られたなど)、出したまま残らないように、
    /// ボタンが離れるまで見続けて下ろす。出したままだと、ウインドウ全体のホイール・右クリックも覆いが受けてしまう。
    private func scheduleStrandedShieldCheck(_ shield: WindowActivationClickShieldView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak shield] in
            guard let self, let shield, self.raisedShield === shield else { return }
            if NSEvent.pressedMouseButtons & 1 == 0 {
                self.lowerShield()
            } else {
                self.scheduleStrandedShieldCheck(shield)
            }
        }
    }

    /// 離すイベントも覆いが受ける(押し下げを受けていない部品に、離すだけが届かないように)。下ろすのはその後。
    private func lowerShieldAfterDispatch() {
        guard raisedShield != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.lowerShield() }
    }

    private func lowerShield() {
        raisedShield?.isRaised = false
        raisedShield = nil
    }

    /// 当たる先が内容のビューか。タイトルバー・タブバー・ツールバーと、ウインドウの縁の大きさを変える掴み所は、ウインドウの枠
    /// (テーマフレーム)か内容の外の別のビューが受けるので外れる(実測: 内容の左上の隅ぎりぎりの点はテーマフレームが受けた)。
    private static func isInsideContent(_ locationInWindow: NSPoint, of window: NSWindow) -> Bool {
        guard let content = window.contentView, let frameView = content.superview,
              let hit = frameView.hitTest(frameView.convert(locationInWindow, from: nil))
        else { return false }
        return hit.isDescendant(of: content)
    }
}

/// 本のウインドウの内容全体に重ねる覆い(`WindowActivationClickFilter`)。ContentView のいちばん外側に重ねる(ほかのビューに
/// 覆われないように)。ふだんは当たり判定に出てこないので、クリック・ドラッグ・ドロップ・カーソルには関わらない。
struct WindowActivationClickShield: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowActivationClickShieldView {
        WindowActivationClickShieldView()
    }

    func updateNSView(_ nsView: WindowActivationClickShieldView, context: Context) {}
}

final class WindowActivationClickShieldView: NSView {
    /// 当たり判定に出ているか(前に出すクリックの、押してから離すまで)。
    var isRaised = false
    /// このウインドウが最後にメインになった時刻 / メインでなくなった時刻(`WindowActivationClick`)。**キーではなくメインで見る**:
    /// ポップオーバー・パネル(クイックルックなど)がキーになっても本のウインドウはメインのまま(見た目も前のウインドウのまま)で、
    /// そこへのクリックはふつうに効かせる。ほかのウインドウの知らせは混ぜない(遅れて届いたほかのウインドウの「外れた」で、
    /// 前のウインドウのクリックが捨てられ続けないように)。
    private(set) var becameMainAt: TimeInterval = 0
    private(set) var resignedMainAt: TimeInterval = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        isRaised ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override var acceptsFirstResponder: Bool { false }
    /// 透明な NSView は既定で true(ウインドウの地として、押し下げでウインドウを動かせる)。
    override var mouseDownCanMoveWindow: Bool { false }

    // 覆いに届いたマウスのイベントは、ここで止める。NSView の既定は次のレスポンダ(SwiftUI のホスティングビュー)へ送るので、
    // ウインドウが既にキーとして押し下げが配られたとき(モニタが見る時点で既にキーのことがある。実測)、SwiftUI のボタンや選択が働いてしまう。
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}

    override func isAccessibilityElement() -> Bool { false }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignMainNotification, object: nil)
        if let newWindow {
            // セレクタ形式の購読(解放時に自動で外れる)。
            center.addObserver(self, selector: #selector(noteBecameMain), name: NSWindow.didBecomeMainNotification, object: newWindow)
            center.addObserver(self, selector: #selector(noteResignedMain), name: NSWindow.didResignMainNotification, object: newWindow)
            becameMainAt = newWindow.isMainWindow ? ProcessInfo.processInfo.systemUptime : 0
            resignedMainAt = 0
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { WindowActivationClickFilter.shared.register(self) }
    }

    @objc private func noteBecameMain() { becameMainAt = ProcessInfo.processInfo.systemUptime }
    @objc private func noteResignedMain() { resignedMainAt = ProcessInfo.processInfo.systemUptime }
}

/// そのマウスのイベントが、ウインドウを前に出したクリック(後ろのウインドウ・前面でないアプリのウインドウへのクリック)か
/// (`WindowActivationClickFilter`)。`activatedAt` / `deactivatedAt` は、そのウインドウがメインになった・アプリが前面になった
/// 時刻の遅いほう / メインでなくなった・前面でなくなった時刻の遅いほう。次のどれかなら、そのクリック:
/// - ウインドウがまだメインでない・アプリがまだ前面でない
/// - 後ろへ回った後、前に出た知らせがまだ来ていない(実測 2026-10-07: 前面でないアプリのウインドウをクリックすると、モニタが
///   押し下げを見る時点で `isActive` もキーも既に true のことがあり、`didBecomeActive` はその後で届いた)
/// - 前に出た知らせが押し下げより後(押し下げで前に出た)
/// ⌘Tab などで前に出た後のクリックは、知らせが押し下げより前に来ているので、ふつうのクリック。
nonisolated enum WindowActivationClick {
    static func isActivationClick(
        eventType: NSEvent.EventType,
        isControlClick: Bool,
        eventTimestamp: TimeInterval,
        windowAppearsActive: Bool,
        activatedAt: TimeInterval,
        deactivatedAt: TimeInterval
    ) -> Bool {
        // 右クリック(⌃クリックも)・中ボタンは対象にしない: ウインドウを前に出さずにメニューを開く(型コメント「対象にしないもの」)。
        guard eventType == .leftMouseDown, !isControlClick else { return false }
        return !windowAppearsActive || activatedAt < deactivatedAt || eventTimestamp <= activatedAt
    }
}

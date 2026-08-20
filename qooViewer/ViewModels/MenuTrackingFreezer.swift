import AppKit
import Combine

/// メニューバーのメニューが開いている(追跡中の)あいだ、メニューの**項目数を左右する入力**を
/// 凍結しておくための小さな道具。`QooViewerApp`の`.commands`から使う。
///
/// ■ 何を防ぐのか(実機で確認したクラッシュ)
/// SwiftUIの`Commands`は、FocusedValueやObservableObjectの変化のたびにメニュー項目を
/// 作り直す(`AppKitMainMenuItem.menuNeedsUpdate` → `NSMenu setItemArray:`)。これが
/// **メニューを開いている最中**に起き、しかも項目数が変わると、macOS 26のメニュー実装
/// (`NSContextMenuImpl` / `NSTableViewBackedMenuRepresentation`)が行高キャッシュの範囲外
/// アクセスで`NSRangeException`(`index 2 beyond bounds [0 .. 1]`)を投げ、アプリが落ちる
/// (Xcodeから起動していると`_crashOnException:`で止まり、ハングしたように見える)。
/// 実際に起きたのは、大きな書庫を開いた直後にメニューを開いたまま待っていたところ、
/// 最初の見開きの読み込みが終わって`MenuCheckmarkState.hasPartnerPageDisplayed`が変わり、
/// 「画像のエクスポート」(1項目→3項目)等が作り直された、という経路。
/// 同じ性質の入力は他にもある: 同じフォルダの兄弟ファイル(非同期で後から埋まる)、
/// 最近開いたファイル(本を開き終えた瞬間に増える)、ブックマーク一覧、レイアウトの
/// 左/右ページ構成。AppKit/SwiftUI側の不具合なので、アプリ側では「開いている間は項目数を
/// 変えない」ことで避ける。
///
/// ■ 使い方
/// `menuFreezer.frozen("key", liveValue)` と書くと、メニュー追跡中は最初に見た値を返し続け、
/// 追跡が終わった時点でキャッシュを捨てて`objectWillChange`を送る(その再評価で最新値に
/// 置き換わる)。追跡中でなければ常に生の値をそのまま返す。キーは呼び出し箇所ごとに固有に。
///
/// 凍結するのは項目数に関わる値だけでよい。`.disabled`やチェックマークのような「項目の
/// 属性」の変化は項目の差し替えを伴わず、クラッシュの条件に当たらない。
@MainActor
final class MenuTrackingFreezer: ObservableObject {
    private final class Slot<Value> {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private var trackingDepth = 0
    private var cache: [String: AnyObject] = [:]
    private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginTracking() }
        })
        tokens.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endTracking() }
        })
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private var isTracking: Bool { trackingDepth > 0 }

    private func beginTracking() {
        trackingDepth += 1
    }

    private func endTracking() {
        trackingDepth = max(trackingDepth - 1, 0)
        guard trackingDepth == 0, !cache.isEmpty else { return }
        cache.removeAll()
        // 凍結中に変わっていた値を反映させるため、メニューが閉じた後に`.commands`を再評価させる。
        objectWillChange.send()
    }

    /// 追跡中は`key`で最初に見た値を返し続ける。追跡中でなければ`live`をそのまま返す。
    func frozen<Value>(_ key: String, _ live: @autoclosure () -> Value) -> Value {
        guard isTracking else { return live() }
        if let slot = cache[key] as? Slot<Value> { return slot.value }
        let value = live()
        cache[key] = Slot(value)
        return value
    }
}

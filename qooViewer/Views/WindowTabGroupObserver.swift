import AppKit
import Combine

/// ウインドウが複数のタブを持っているか(=同じタブグループにほかのウインドウがあるか)を見張る。
///
/// 画像の右クリックの「タブを閉じる」を、タブが1枚だけのときは淡色にするため(2026-09-26、
/// ユーザーの指示。タブが1枚なら「ウインドウを閉じる」と同じことになり、別の項目にする意味が無い)。
/// SwiftUIの右クリックメニューはbodyを評価した時点の値で作られるので、開く瞬間にAppKitへ
/// 問い合わせるのではなく、変化をここで受けて`@Published`で本体を描き直させる。
///
/// - タブの増減は`NSWindowTabGroup.windows`のKVOで受ける(ヘッダーに「KVO compliant」と明記)。
/// - タブを別のウインドウへ引き離すと、そのウインドウの`tabGroup`自体が別物になる。`tabGroup`の
///   KVOは保証されていないので、キーウインドウになったとき(引き離したタブは前面に来る)と、
///   元のグループのKVOが届いたときに、見張るグループを取り直す。
///
/// 閉包はどれも`[weak self]`でこのオブジェクトだけを捕まえる(ViewerViewを捕まえると、閉じた
/// ウインドウごと残る ―― ViewerActionRelayの型コメント参照)。
@MainActor
final class WindowTabGroupObserver: ObservableObject {
    @Published private(set) var hasMultipleTabs = false

    private weak var window: NSWindow?
    private weak var observedGroup: NSWindowTabGroup?
    private var groupObservation: NSKeyValueObservation?
    private var becomeKeyObserver: NSObjectProtocol?

    /// 見張るウインドウを決める(nilなら見張りをやめる)。ViewerViewのsetUpWindowObserversから呼ぶ。
    func attach(to window: NSWindow?) {
        detach()
        self.window = window
        guard let window else { return }
        becomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    /// 見張りをやめる。ViewerViewが消えるとき(handleOnDisappear)に呼ぶ。
    func detach() {
        if let becomeKeyObserver {
            NotificationCenter.default.removeObserver(becomeKeyObserver)
        }
        becomeKeyObserver = nil
        groupObservation?.invalidate()
        groupObservation = nil
        observedGroup = nil
        window = nil
    }

    private func refresh() {
        guard let window else {
            if hasMultipleTabs { hasMultipleTabs = false }
            return
        }
        let group = window.tabGroup
        if group !== observedGroup {
            groupObservation?.invalidate()
            observedGroup = group
            // KVOはどのスレッドから届くか決まっていないうえ、通知の最中にグループを読み直さないよう、
            // メインアクタで1拍おいてから取り直す。
            groupObservation = group?.observe(\.windows, options: []) { @Sendable [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        let multiple = (group?.windows.count ?? window.tabbedWindows?.count ?? 1) > 1
        if multiple != hasMultipleTabs { hasMultipleTabs = multiple }
    }
}

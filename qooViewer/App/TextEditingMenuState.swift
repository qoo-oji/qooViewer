import AppKit
import Combine

/// テキストの欄を編集しているか(編集メニューの「取り消す」「やり直す」を押せるようにするため。2026-09-19 の総点検)。
///
/// ■ なぜ要るか
/// 「取り消す」「やり直す」は `CommandGroup(replacing: .undoRedo)` でファイルブラウザのファイル操作に差し替えてあり、中身は
/// 「テキストの欄を編集中なら欄へ `undo:` を送る」なのに、淡色の条件がファイル操作の履歴だけだった。読み取り専用モード(既定)・
/// 本を開いたウインドウ・補助ウインドウでは項目が淡色のままで、**欄で打った文字を ⌘Z で戻せなかった**(欄の `NSTextView` は
/// ⌘Z をメニューからしか受けない)。
///
/// ■ いつ確かめ直すか
/// 欄が最初の 1 文字を受けたとき(`NSText.didBeginEditingNotification` ―― 焦点が入っただけでは戻すものが無いので、それで足りる)・
/// 編集を終えたとき・キーウインドウが入れ替わったとき。値は「キーウインドウのファーストレスポンダが編集できるテキストか」
/// (`QooViewerApp.isEditingText`。項目の中身の振り分けと同じ判定)。
///
/// メニューへは `AppStores.allObjectWillChangePublishers` を通して届ける(開いている最中のメニューを作り直さない。MenuBarMenuGate)。
@MainActor
final class TextEditingMenuState: ObservableObject {
    @Published private(set) var isEditingText = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSText.didBeginEditingNotification, NSText.didEndEditingNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // 編集の終わり・キーの入れ替わりの通知の時点では、ファーストレスポンダがまだ移っていない。
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            })
        }
    }

    private func refresh() {
        let editing = QooViewerApp.isEditingText
        if editing != isEditingText { isEditingText = editing }
    }
}

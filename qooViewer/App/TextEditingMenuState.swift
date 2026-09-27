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
///
/// ■ 欄の取り消しの名前と可否(2026-09-27、監査 22)
/// 「取り消す」は差し替えてあって responder chain の検証(`validateMenuItem`)を通らないので、欄を編集していても
/// 「タイプ入力を取り消す」の名前が出ず、戻すものが無くても押せた。欄の `undoManager`(フィールドエディタならウインドウのもの)から
/// 名前(`undoMenuItemTitle`。AppKit が訳したもの)と可否を写し、取り消しの積み場所が変わるたびに確かめ直す。値が変わったときだけ
/// 知らせるので、打鍵ごとにメニューを作り直すことはない(名前が変わるのは打ち始めと、戻し切ったときくらい)。
@MainActor
final class TextEditingMenuState: ObservableObject {
    @Published private(set) var isEditingText = false
    /// 欄の取り消し・やり直しの題と可否。編集していない間は既定の値。
    @Published private(set) var textUndo = TextUndoState()
    private var observers: [NSObjectProtocol] = []

    struct TextUndoState: Equatable {
        var undoTitle: String?
        var redoTitle: String?
        var canUndo = false
        var canRedo = false
    }

    init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSText.didBeginEditingNotification, NSText.didEndEditingNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            // 欄の取り消しの積み場所が変わったとき(打った・戻した・やり直した)。どの UndoManager からでも来るが、見るのは
            // キーウインドウの欄のものだけで、値が変わらなければ何も知らせない。
            .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
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
        var undo = TextUndoState()
        if editing, let manager = (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager {
            undo = TextUndoState(
                undoTitle: manager.undoMenuItemTitle, redoTitle: manager.redoMenuItemTitle,
                canUndo: manager.canUndo, canRedo: manager.canRedo
            )
        }
        if undo != textUndo { textUndo = undo }
    }
}

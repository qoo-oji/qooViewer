import SwiftUI
import AppKit

/// 検索欄・絞り込み欄のキーボードフォーカスを、**欄の外のクリック・Return・Esc**で外す。
///
/// ■ 経緯(ユーザー要望)
/// サイドパネルの絞り込み欄を一度クリックするとフォーカスが残り続け、ショートカットの
/// つもりで押したキーが絞り込みの文字として吸われてしまう。外すには別のモードへ切り替えて
/// 戻る・Tabを何度か押す、といった手間が要った。「欄の周りの余白をクリックしたら外れて
/// ほしい」という要望を、同じウインドウのどこをクリックしても外れる形で叶える
/// (ブックマーク・レイアウトの編集ウインドウの検索欄も、矢印キーでの移動を吸ってしまう
/// 同じ問題を持つため、アプリ内の検索欄すべてに同じものを付けてある)。
///
/// ■ なぜ自前でクリックを監視するのか
/// AppKitは、クリックされたビューがファーストレスポンダを受け取れるときだけフォーカスを
/// 移す。画像表示エリア・パネルの余白・一覧の行のように受け取らないビューをクリックしても
/// 入力欄のフォーカスは残る。そのため、ローカルモニタでクリックを見張り、自分の欄が編集中で
/// クリックがその外なら、ウインドウのファーストレスポンダを外す。イベントは消費しない
/// (行のクリックで本が開く等はそのまま動く)。別のウインドウへのクリックは関係ないので無視する。
///
/// ■ 文字は消さない
/// 消したければ各欄の×ボタン。フォーカスを外すだけなら絞り込み結果はそのまま残り、
/// 「絞り込んでおいて矢印キーで選ぶ」という使い方ができる。
extension View {
    func releasesFocusOnOutsideClick() -> some View {
        modifier(FocusReleasingField())
    }
}

private struct FocusReleasingField: ViewModifier {
    @FocusState private var isFocused: Bool
    @State private var clickMonitor: Any?
    /// 欄の位置を、クリックのたびにAppKitの座標変換で取り直すためのアンカー
    /// (フレームをキャッシュすると、パネルの幅を変えた後などにずれる)。
    @State private var anchor = FieldAnchor()

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onSubmit { isFocused = false }
            .onExitCommand { isFocused = false }
            .background(FieldAnchorView(anchor: anchor))
            .onAppear { installClickMonitor() }
            .onDisappear { removeClickMonitor() }
    }

    /// 欄が見えている間ずっと張っておく(フォーカスの有無で張り替える方式は、
    /// `@FocusState`の変化がAppKit側のフォーカス移動に追随しないことがあり、実機で
    /// クリックが拾えなかった)。クリックのたびに「このウインドウで編集中のテキスト欄が
    /// 自分で、クリックがその外」のときだけフォーカスを外す。判定はAppKitの
    /// ファーストレスポンダ(編集中はフィールドエディタのNSTextView。その`delegate`が
    /// 実体のNSTextField)を直接見るので、SwiftUI側の状態に依存しない。
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard let view = anchor.view, let window = view.window, event.window === window,
                  let editor = window.firstResponder as? NSTextView,
                  let field = editor.delegate as? NSTextField
            else { return event }
            // 自分の欄(アンカーの背景ビューと同じ領域)で編集中か。
            let fieldFrame = field.convert(field.bounds, to: nil)
            let anchorFrame = view.convert(view.bounds, to: nil)
            guard anchorFrame.intersects(fieldFrame) else { return event }
            if !anchorFrame.contains(event.locationInWindow) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }
}

/// 欄の背後に置く、何も描画しないNSViewへの参照。欄そのもののNSTextFieldはSwiftUIの内部に
/// 隠れていて取れないため、同じ大きさの背景ビューを位置の基準にする。
@MainActor
private final class FieldAnchor {
    weak var view: NSView?
}

private struct FieldAnchorView: NSViewRepresentable {
    let anchor: FieldAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

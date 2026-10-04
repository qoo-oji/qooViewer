import AppKit
import SwiftUI

extension View {
    /// 補助ウインドウ(`Window` シーン)が**出た・閉じた**を知らせる(2026-10-04 の監査 docs/plans/ui-state-consistency-audit-2026-10-04.md §1-3)。
    ///
    /// `Window` シーンは単一インスタンスで、**閉じてもビューの `@State` と、そこに入れた ViewModel をアプリを終えるまで保つ**
    /// (AutoRenameSettingsWindow の `panelStartDirectory` の実機の記録。Settings シーンでも同じ: FB21393010)。init も `@State` の
    /// 初期値も二度と走らないので、開き直した窓は前回閉じたときの一覧・判定・読み込んだファイル・結果をそのまま見せる。2026-10-04 の
    /// 監査では、それで古い「見つかりません」を信じて実在する本の保存データを消させる(TW-7)、新しく設定した表紙の欠けたバックアップを
    /// 黙って作る(TW-10)、前回の上書きの方針と中身で読み込める(TW-8)、閉じた後も ⌘Z で以前の削除が戻る(BE-11)などが出た。
    ///
    /// **補助ウインドウはこれで開き直しを知り、`true` で一覧と控え(実在の判定のキャッシュなど)を作り直し、`false` で一時的な状態
    /// (読み込んだファイル・結果・初回のパネルの番人・取り消しの積み場所)を捨てる**(docs/03「補助ウインドウ」)。書き出しの 3 窓が
    /// 2026-09-25 から `BookExportViewModel.setPresented` でしていた形を、どの補助ウインドウでも使える 1 つの部品にしたもの。
    ///
    /// - 最初に出たときも `true` が来る。ViewModel を作った直後なら、作ったときに読んでいるので何もしなくてよい(各 `setPresented` は
    ///   「出ている」から始めて、変化したときだけ動く)。
    /// - 閉じたことは `onDisappear` と、載っている `NSWindow` の `willCloseNotification` の**両方**で受け、先に来たほうで 1 回だけ知らせる。
    ///   ウインドウごと閉じられたときに `onDisappear` が呼ばれないことがある(BookmarkListView.observeWindowClose・ViewerView の
    ///   setUpWindowObservers のコメント)ので、onDisappear だけでは「閉じた」を落としうる。
    /// - 出たことは `onAppear` と、覚えている `NSWindow` の `didBecomeKeyNotification` の**両方**で受ける(2026-10-04 のレビューの R1-5)。
    ///   閉じても `onDisappear` が来ない窓(上)では、開き直しても `onAppear` が来ない恐れがあるため。書き出しの 3 窓は onAppear だけで
    ///   動いているので実際に落ちるかは確かめていない(実機で確かめていない予防の受け口)。閉じた窓はキーにならないので、キーになった
    ///   = 出ている。中身が外されたとき(窓は出たまま)はこの購読ごと外れるので、ほかの窓から戻っただけで「出た」にはならない。
    /// - 置き場所は、ViewModel を持つ中身のビュー(ViewModel を遅れて作る窓では、作った後に現れる子)。
    func auxiliaryWindowPresence(_ action: @escaping (_ isPresented: Bool) -> Void) -> some View {
        modifier(AuxiliaryWindowPresence(action: action))
    }
}

private struct AuxiliaryWindowPresence: ViewModifier {
    let action: (Bool) -> Void

    /// 出ているか・どのウインドウに載っているか。body からは読まない(描き直しの契機にしない)ので参照型に入れる。
    @State private var tracker = Tracker()

    private final class Tracker {
        var isPresented = false
        weak var window: NSWindow?
    }

    func body(content: Content) -> some View {
        content
            .onAppear { markPresented() }
            .onDisappear { markClosed() }
            .background(WindowAccessor { window in
                // 外されたとき(nil)は覚えている窓のままにする。閉じた窓の willClose を受けるのに要る。
                if let window, tracker.window !== window { tracker.window = window }
            })
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                guard let window = tracker.window, (note.object as? NSWindow) === window else { return }
                markClosed()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard let window = tracker.window, (note.object as? NSWindow) === window, window.isVisible else { return }
                markPresented()
            }
    }

    private func markPresented() {
        guard !tracker.isPresented else { return }
        tracker.isPresented = true
        action(true)
    }

    private func markClosed() {
        guard tracker.isPresented else { return }
        tracker.isPresented = false
        action(false)
    }
}

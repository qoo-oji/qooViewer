import AppKit
import SwiftUI

/// 環境設定ウインドウを載せている `NSWindow` に、リサイズ可能の指定(`.resizable`)と、
/// ツールバーの様式(`toolbarStyle`)を足すためだけの透明なビュー。`SettingsView` の `.background` に敷いて使う。
///
/// ■ なぜAppKitに降りる必要があるのか
/// SwiftUIの `Settings` シーンが作るウインドウは、**リサイズできない状態で作られる**。
/// 実機で `styleMask` を読むと `titled | closable | fullSizeContentView`(= 32771)で、
/// `.resizable` が入っていない。`minSize`/`maxSize` のほうは中身のframeどおり
/// (760×528 〜 無限大)に設定されているにもかかわらず、である。
///
/// SwiftUIの範囲でこれを変える手段は無い。
/// - `.windowResizability(.contentMinSize)` … `Settings` シーンだけは常に `.contentSize` 扱いで、
///   指定しても無視される(他のSceneでは効く)
/// - 中身のframeに `maxWidth: .infinity` / `maxHeight: .infinity` を与える … `maxSize` は
///   無限大になるが、`styleMask` は変わらないままなので依然として動かせない
/// いずれも実機で確認済み。したがって、足りていない1ビットだけをAppKit側で補う。
///
/// ■ なぜ `NSApp.windows` から探さないのか
/// このビューは環境設定ウインドウの中に置かれているので、`self.window` がそのウインドウそのもの。
/// `com_apple_SwiftUI_Settings_window` のような**SwiftUI内部の識別子を当てにした検索**は、
/// OSの更新で識別子が変わった瞬間に黙って効かなくなる。自分の載っているウインドウを辿るだけなら
/// その心配が無い。
///
/// ■ 最小サイズについて
/// ここでは触らない。`minSize` は中身のframe(`SettingsView` の `.frame(minWidth:minHeight:)`)から
/// SwiftUIが正しく設定しており、`.resizable` を足した時点でAppKitがその下限を守ってくれる。
struct SettingsWindowResizabilityAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ResizableWindowInserter()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 上記の実体。ウインドウに載った時点で1度だけ `.resizable` を足す。
private final class ResizableWindowInserter: NSView {
    /// ウインドウが差し替わった場合(環境設定を閉じて開き直すとSwiftUIがウインドウを作り直す)にも
    /// 確実に効くよう、`viewDidMoveToWindow` で毎回入れ直す。
    /// `styleMask` はOptionSetなので、既に入っていれば `insert` は何もしない。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.styleMask.insert(.resizable)
        // ツールバーの項目をタイトルバーの行に埋め込む(他の補助ウインドウと同じ見た目)。
        // `Settings` シーンは `.windowToolbarStyle(.unified)` を書いても無視される
        // (`.windowResizability` と同じ。実機で確認済み)。既定は「タイトルの下にアイコンが
        // 並ぶ」段組(NSWindow.ToolbarStyle.preference)で、ツールバー項目を1つでも置くと
        // タイトルが中央寄せになり、その下に大きなボタンの段が現れる。
        // 環境設定「外観」の面ごとの子ページが出す「戻る」(AppearanceSettingsView参照)を
        // システム設定と同じくタイトルの左へ出すため、ここで直接指定する。
        window?.toolbarStyle = .unifiedCompact
    }

    /// 背景として敷くだけのビューなので、クリックなどの操作は一切受け取らない
    /// (前面のSwiftUIコンテンツに覆われていない隙間でクリックを横取りしないようにするため。
    ///  WindowMouseExitAccessor の hitTest と同じ理由)。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

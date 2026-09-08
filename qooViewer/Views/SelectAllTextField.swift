import AppKit
import SwiftUI

/// NSTextFieldをラップし、表示開始時に必ず内容を全選択した状態でフォーカスを当て、
/// **Returnで確定できる**テキストフィールド。
///
/// ■ 全選択
/// SwiftUIの`TextField`には「表示時に内容を全選択状態にする」ための標準APIが無く、
/// `.alert`内の`TextField`(NSAlertが内部で使うテキストフィールド)は特に選択状態の
/// 制御が効かないことがある(ユーザー報告: 開いたときに全選択されていたりされて
/// いなかったりする)。AppKitの`NSTextField`を直接ラップし、
/// `currentEditor()?.selectAll(nil)`を呼ぶことで確実に全選択状態にする。
///
/// ■ Returnで確定
/// NSTextFieldの`doCommandBy`で`insertNewline(_:)`を受け、`onSubmit`を呼ぶ
/// (SwiftUIの`TextField`の`.onSubmit`に相当)。日本語入力の変換中はReturnがまず変換の確定に
/// 使われるため、この経路に届くのは**確定後のReturn**である ―― OSの通常の動作で、
/// アプリ側で分ける必要は無い(自動操作で試すときは、変換が残っていて1回目のReturnが
/// 効かないように見えることがある)。
///
/// 使う場所: ブックマークのリネームシート(BookmarkListView)、ライブラリ/コレクションの
/// 名前入力シート(CollectionNameSheet)。
struct SelectAllTextField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.lineBreakMode = .byTruncatingTail
        // WindowAccessor(ViewerView.swift)と同じ理由: このNSViewがまだウインドウに
        // 追加される前のタイミングではfield.windowがnilなので、次のランループまで待ってから
        // ファーストレスポンダにする。selectAll(nil)は「テキスト編集中の選択範囲」を操作する
        // APIのため、先にcurrentEditor()が存在する状態(=ファーストレスポンダになった状態)を
        // 作ってから呼ぶ必要がある。
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // **毎回コーディネータの持つ構造体を差し替える。** コーディネータはmakeCoordinator()で
        // 一度しか作られないので、そこで捕まえた`self`は最初の状態のまま古くなる。
        // `text`はBindingなので古い写しでも生きているが、`onSubmit`は**呼び出し側のView(構造体)を
        // 丸ごと捕まえたクロージャ**になりうる。CollectionNameSheetの「確定できるか」の判定が
        // まさにそれで、差し替えないと常に「まだ何も入力していない状態」で検証されてしまう
        // (Returnがいつまでも効かない、という形で出る)。
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SelectAllTextField
        init(_ parent: SelectAllTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// Return(改行)キーで確定(Save)できるようにする。TextField(SwiftUI)の
        /// .onSubmitに相当する挙動をNSTextFieldDelegate経由で実現する。
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

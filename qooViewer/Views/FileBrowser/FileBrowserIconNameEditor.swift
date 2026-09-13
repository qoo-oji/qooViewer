import AppKit
import SwiftUI

/// アイコン表示の名前の変更(段階4b、2026-09-14)。セルの名前の位置に差し替えて出す、折り返す編集欄。
///
/// ■ 部品
/// リストと同じ`FileBrowserNameField`を使う ―― 編集が始まった瞬間に**表示名ではなく実際の名前**へ差し替え、
/// 拡張子の前までを選ぶ(フォルダは全体)。SwiftUIの`TextField`は選択範囲を確実に置けない
/// (SelectAllTextField のコメント)。
///
/// ■ 終わり方(Finder と同じ)
/// Return で確定、Esc で取りやめ、ほかをクリックして焦点が外れても確定。**編集中にセルが消えた**
/// (フォルダを移った・表示形式を切り替えた)ときも、打った名前で確定する(`dismantleNSView`)。
/// 確定と取りやめは1回だけ呼ぶ(Return の後にも焦点が外れた通知が来る)。
///
/// ■ 輪郭(すりガラス面の決まりごと)
/// 欄は不透明な地(`textBackgroundColor`)を持つので輪郭は掛けない。
struct FileBrowserIconNameEditor: NSViewRepresentable {
    /// 実際の名前(`url.lastPathComponent`)。
    let name: String
    let selectsWholeName: Bool
    let width: CGFloat
    /// 編集中の文字(高さを測る)。打つたびに`onTextChange`で呼び出し側へ返してもらい、測り直させる。
    let text: String
    let onTextChange: (String) -> Void
    /// 確定した名前(変わっていないこともある。比べるのは呼び出し側)。
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    static let font = NSFont.systemFont(ofSize: 12)

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FileBrowserNameField {
        let field = FileBrowserNameField(string: name)
        field.font = Self.font
        field.alignment = .center
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .default
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byCharWrapping
        field.editingName = name
        field.selectsWholeName = selectsWholeName
        field.delegate = context.coordinator
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        context.coordinator.onTextChange = onTextChange
        // まだウインドウに入っていないので、入った時点で焦点を置く(FileBrowserNameField.focusesWhenAttached)。
        // 焦点が入った時点で FileBrowserNameField が名前の選択範囲を置く。
        field.focusesWhenAttached = true
        return field
    }

    func updateNSView(_ field: FileBrowserNameField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        context.coordinator.onTextChange = onTextChange
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: FileBrowserNameField, context: Context) -> CGSize? {
        let width = proposal.width ?? width
        // 打った文字に合わせて高さを伸ばす(Finder と同じく折り返して下へ広がる)。
        let measuring = NSTextFieldCell(textCell: text.isEmpty ? " " : text)
        measuring.font = Self.font
        measuring.wraps = true
        measuring.isBezeled = true
        measuring.bezelStyle = .squareBezel
        let height = measuring.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height))
    }

    static func dismantleNSView(_ field: FileBrowserNameField, coordinator: Coordinator) {
        // 編集中に消えたら確定する(型コメント)。ここは SwiftUI の更新の最中なので、状態を変える確定は
        // 次のランループへ回す。閉包はその場で手放す(CLAUDE.md: dismantleNSView で切る)。
        let name = field.stringValue
        let commit = coordinator.onCommit
        field.delegate = nil
        coordinator.onCommit = nil
        coordinator.onCancel = nil
        coordinator.onTextChange = nil
        if coordinator.markFinished(), let commit {
            DispatchQueue.main.async { commit(name) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: ((String) -> Void)?
        var onCancel: (() -> Void)?
        var onTextChange: ((String) -> Void)?
        private var isFinished = false

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onTextChange?(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                finish(commit: textView.string)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(commit: nil)
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            finish(commit: field.stringValue)
        }

        /// 確定(名前を渡す)か取りやめ(nil)。2回目以降は何もしない。
        func finish(commit name: String?) {
            guard markFinished() else { return }
            if let name {
                onCommit?(name)
            } else {
                onCancel?()
            }
        }

        /// まだ終わっていなければ終わった印を付けて true。
        func markFinished() -> Bool {
            guard !isFinished else { return false }
            isFinished = true
            return true
        }
    }
}

import SwiftUI

/// キー設定画面で選択できる、割り当て可能な物理キー(必要に応じて修飾キー付き)。
/// (すべてのキー・修飾キーの組み合わせではなく、割り当てて実用的なものだけに絞っている)
///
/// 修飾キーはshift/option/controlに対応する。commandは対象外
/// (メニューバーの既存ショートカットと衝突しやすいため)。
/// また、OS標準の操作と衝突しやすい組み合わせ
/// (control+矢印キー=Mission Controlのスペース切替、control+space=入力ソース切替、
///  control+tab=ウインドウ/タブ切替など)も選択肢に含めていない。
/// なお、option+一部の文字キー(e/i/u/n/`等、いわゆるデッドキー)はmacOS側でアクセント記号の
/// 入力に使われるため、実際に割り当てて期待通り動くかは要確認。
struct RemappableKey: Codable, Hashable, Identifiable {
    /// 保存用の安定した識別子
    let id: String
    /// 設定画面に表示する名前
    let displayName: String

    static let leftArrow = RemappableKey(id: "leftArrow", displayName: "←")
    static let rightArrow = RemappableKey(id: "rightArrow", displayName: "→")
    static let shiftLeftArrow = RemappableKey(id: "shiftLeftArrow", displayName: "shift + ←")
    static let shiftRightArrow = RemappableKey(id: "shiftRightArrow", displayName: "shift + →")
    static let optionLeftArrow = RemappableKey(id: "optionLeftArrow", displayName: "option + ←")
    static let optionRightArrow = RemappableKey(id: "optionRightArrow", displayName: "option + →")
    static let upArrow = RemappableKey(id: "upArrow", displayName: "↑")
    static let downArrow = RemappableKey(id: "downArrow", displayName: "↓")
    static let space = RemappableKey(id: "space", displayName: "space")
    static let shiftSpace = RemappableKey(id: "shiftSpace", displayName: "shift + space")
    static let optionSpace = RemappableKey(id: "optionSpace", displayName: "option + space")
    static let tab = RemappableKey(id: "tab", displayName: "tab")
    static let shiftTab = RemappableKey(id: "shiftTab", displayName: "shift + tab")
    static let home = RemappableKey(id: "home", displayName: "home")
    static let end = RemappableKey(id: "end", displayName: "end")
    static let pageUp = RemappableKey(id: "pageUp", displayName: "page up")
    static let pageDown = RemappableKey(id: "pageDown", displayName: "page down")

    static func character(_ c: Character) -> RemappableKey {
        RemappableKey(id: "char:\(c)", displayName: String(c))
    }

    static func optionCharacter(_ c: Character) -> RemappableKey {
        RemappableKey(id: "optionChar:\(c)", displayName: "option + \(c)")
    }

    static func controlCharacter(_ c: Character) -> RemappableKey {
        RemappableKey(id: "controlChar:\(c)", displayName: "control + \(c)")
    }

    /// キー設定画面のPickerに並べる選択肢一覧
    /// (矢印・space・tab等の特殊キー[+shift/option] + a-z + 0-9[+無し/option/control])
    static let selectable: [RemappableKey] = {
        let special: [RemappableKey] = [
            .leftArrow, .rightArrow, .shiftLeftArrow, .shiftRightArrow,
            .optionLeftArrow, .optionRightArrow, .upArrow, .downArrow,
            .space, .shiftSpace, .optionSpace, .tab, .shiftTab,
            .home, .end, .pageUp, .pageDown,
        ]
        let alnum = "abcdefghijklmnopqrstuvwxyz0123456789"
        let plain = alnum.map { RemappableKey.character($0) }
        let withOption = alnum.map { RemappableKey.optionCharacter($0) }
        let withControl = alnum.map { RemappableKey.controlCharacter($0) }
        return special + plain + withOption + withControl
    }()

    /// SwiftUIの `.onKeyPress` が渡してくる KeyPress から対応する RemappableKey を求める。
    /// 修飾キーはshift/option/controlに対応(command付きや、OS標準の操作と衝突しやすい
    /// 組み合わせは認識せずnilを返す。詳細は型のドキュメントコメント参照)。
    static func from(_ press: KeyPress) -> RemappableKey? {
        let modifiers = press.modifiers
        guard !modifiers.contains(.command) else { return nil }

        switch press.key {
        case .leftArrow:
            if modifiers.isEmpty { return .leftArrow }
            if modifiers == .shift { return .shiftLeftArrow }
            if modifiers == .option { return .optionLeftArrow }
            return nil
        case .rightArrow:
            if modifiers.isEmpty { return .rightArrow }
            if modifiers == .shift { return .shiftRightArrow }
            if modifiers == .option { return .optionRightArrow }
            return nil
        case .upArrow: return modifiers.isEmpty ? .upArrow : nil
        case .downArrow: return modifiers.isEmpty ? .downArrow : nil
        case .home: return modifiers.isEmpty ? .home : nil
        case .end: return modifiers.isEmpty ? .end : nil
        case .pageUp: return modifiers.isEmpty ? .pageUp : nil
        case .pageDown: return modifiers.isEmpty ? .pageDown : nil
        case .space:
            if modifiers.isEmpty { return .space }
            if modifiers == .shift { return .shiftSpace }
            if modifiers == .option { return .optionSpace }
            return nil
        case .tab:
            if modifiers.isEmpty { return .tab }
            if modifiers == .shift { return .shiftTab }
            return nil
        default:
            let character = press.key.character
            guard character.isLetter || character.isNumber else { return nil }
            let lowered = Character(character.lowercased())
            // 文字キーは、素押し/shift押しのどちらも同じ(大文字小文字を区別しない)扱いにする
            // (以前からの挙動を踏襲。single-letterのメニューアクセラレータ的な使い方を想定しているため)。
            if modifiers.isEmpty || modifiers == .shift { return .character(lowered) }
            if modifiers == .option { return .optionCharacter(lowered) }
            if modifiers == .control { return .controlCharacter(lowered) }
            return nil
        }
    }
}

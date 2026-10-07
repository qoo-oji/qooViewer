import AppKit
import SwiftUI

/// ホームのグリッドのクリックとキーの読み方(2026-09-27、ホームの操作の統一。docs/plans/home-interaction-design.md)。
///
/// 本棚のコレクションの一覧・コレクションの中・スマートライブラリで、**同じ出来事を同じ意味に読む**ための共通部分。
/// 規則はスマートライブラリのグリッド(2026-09-22)が先に決めたもの ―― クリックで選ぶ、⌘ で足す/外す、⇧ で範囲、
/// ダブルクリック・Return・Enter・⌘↓ で開く、⌘↑・Esc で入れ物(コレクション・束)から出る、矢印・Home/End・PageUp/PageDown・
/// 頭文字(type-select)。環境設定「クリック 1 回で開く」(`AppPreferences.homeOpensWithSingleClick`)を入れると、ふつうの
/// クリックが「開く」になる。
nonisolated enum HomeGridInteraction {
    enum ClickAction: Equatable, Sendable {
        case open
        case select(GridSelectionClick)
        /// 何もしない(「クリック 1 回で開く」のときのダブルクリックの 2 回目)。
        case ignore
    }

    /// セルのクリックの意味。修飾キーと回数は**クリックの出来事から読む**(SwiftUI の `TapGesture` は修飾キーもクリックの回数も
    /// 渡さない。回数ごとに別の `TapGesture` を重ねると、1 回のクリックがダブルクリックの間隔ぶん待たされる)。
    ///
    /// 「クリック 1 回で開く」のとき、ダブルクリックの 2 回目は捨てる ―― 1 回目でコレクションに入ったあと、2 回目が中の同じ位置の
    /// 本に届いて開いてしまうため。
    static func clickAction(clickCount: Int, modifiers: NSEvent.ModifierFlags, opensWithSingleClick: Bool) -> ClickAction {
        if clickCount >= 2 { return opensWithSingleClick ? .ignore : .open }
        if modifiers.contains(.command) { return .select(.toggle) }
        if modifiers.contains(.shift) { return .select(.extend) }
        return opensWithSingleClick ? .open : .select(.plain)
    }

    /// いま処理しているクリックの意味(`NSApp.currentEvent` から)。
    ///
    /// 「クリック 1 回で開く」のとき、ダブルクリックの 1 回目がウインドウを前に出すだけのクリック(`WindowActivationClickFilter`
    /// が受けて、グリッドへ届いていない)なら、2 回目を 1 回目として読む ―― 2 回目を捨てる決まりのせいで、後ろのウインドウの
    /// タイルをダブルクリックしても何も起きなかった(2026-10-07 のレビュー)。ふだんの設定では 2 回目はそのまま「開く」。
    @MainActor
    static func currentClickAction(opensWithSingleClick: Bool) -> ClickAction {
        let event = NSApp.currentEvent
        var clickCount = event?.clickCount ?? 1
        if opensWithSingleClick, clickCount == 2, let event,
           WindowActivationClickFilter.shared.firstClickWasActivation(of: event) {
            clickCount = 1
        }
        return clickAction(
            clickCount: clickCount,
            modifiers: event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? [],
            opensWithSingleClick: opensWithSingleClick
        )
    }

    enum KeyCommand: Equatable, Sendable {
        /// Return・Enter・⌘↓。
        case open
        /// ⌘↑・Esc(入れ物から出る)。
        case leave
        case move(GridKeyboardNavigation.Direction, extending: Bool)
        case jump(JumpKind, extending: Bool)
        case typeSelect(String)
    }

    enum JumpKind: Equatable, Sendable {
        case first, last, pageUp, pageDown

        /// `GridSelection.jump` に渡す形。`step` は 1 画面ぶんの件数(PageUp / PageDown)。
        func gridJump(step: Int) -> GridSelectionJump {
            switch self {
            case .first: .first
            case .last: .last
            case .pageUp: .pageUp(step)
            case .pageDown: .pageDown(step)
            }
        }
    }

    /// キーの意味。⌥・⌃ の付いたキー、⌘ の付いたほかのキーは受けない(メニューへ渡す)。
    static func keyCommand(key: KeyEquivalent, characters: String, modifiers: EventModifiers) -> KeyCommand? {
        guard modifiers.isDisjoint(with: [.option, .control]) else { return nil }
        let command = modifiers.contains(.command)
        let extending = modifiers.contains(.shift)
        switch key {
        case .return, KeyEquivalent("\u{03}"):
            // Return とテンキーの Enter。
            return command ? nil : .open
        case .upArrow where command:
            return .leave
        case .downArrow where command:
            return .open
        case .escape:
            return command ? nil : .leave
        case _ where command:
            return nil
        case .upArrow: return .move(.up, extending: extending)
        case .downArrow: return .move(.down, extending: extending)
        case .leftArrow: return .move(.left, extending: extending)
        case .rightArrow: return .move(.right, extending: extending)
        case .home: return .jump(.first, extending: extending)
        case .end: return .jump(.last, extending: extending)
        case .pageUp: return .jump(.pageUp, extending: extending)
        case .pageDown: return .jump(.pageDown, extending: extending)
        default:
            // 文字のキーは type-select。制御文字・矢印などの機能キー(U+F700〜)は受けない。
            guard !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ scalar in
                      !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
                          && scalar.value != 0x7F
                  })
            else { return nil }
            return .typeSelect(characters)
        }
    }
}

/// 頭文字で選ぶ(type-select)の入力の控え。規則はファイルブラウザ・スマートライブラリと同じ(`FileBrowserState.typeSelect`):
/// 前の入力から `FileBrowserState.typeSelectResetInterval` 過ぎたら打ち直し、1 文字(同じ文字の連打を含む)は今の位置の次から
/// 一巡、2 文字以上は先頭から。大小文字・濁点の有無・全角半角は区別しない。
struct HomeTypeSelect {
    private var buffer = ""
    private var lastInput: Date?

    /// 打った文字に合う項目の位置。見つからなければ nil。
    mutating func match(_ characters: String, names: [String], current: Int?, now: Date = Date()) -> Int? {
        guard !characters.isEmpty else { return nil }
        if let lastInput, now.timeIntervalSince(lastInput) < FileBrowserState.typeSelectResetInterval {
            buffer += characters
        } else {
            buffer = characters
        }
        lastInput = now
        guard !names.isEmpty else { return nil }
        let isSingleCharacter = Set(buffer.lowercased()).count == 1
        let needle = isSingleCharacter ? String(buffer.prefix(1)) : buffer
        let start = isSingleCharacter ? ((current ?? -1) + 1) : 0
        let options: String.CompareOptions = [.anchored, .caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        for offset in 0..<names.count {
            let index = (start + offset) % names.count
            if names[index].range(of: needle, options: options) != nil { return index }
        }
        return nil
    }
}

/// グリッドの選んだ枠を見える位置へ送る(本棚の 2 画面。帯の `MarqueeSelection` が控えているセルの矩形と裏の `NSScrollView` を使う)。
///
/// **どのセルも同じ高さ**(タイルは札 + 名前 1 行、コレクションの中はカバー + 文字 0〜1 行で、1 つの画面の中では揃う)なので、
/// 行の位置は「外周の余白 + 行 × (セルの高さ + 行間)」で決まる。セルの高さは作られているセルの矩形から取る(Lazy なので、
/// 行き先のセルはまだ作られていないことがある)。見えていれば動かさず、はみ出したぶんだけ動かす(スマートライブラリと同じ)。
@MainActor
enum HomeGridReveal {
    static func reveal(row: Int, marquee: MarqueeSelection, padding: CGFloat, spacing: CGFloat) {
        guard let cellHeight = marquee.anyFrame?.height, cellHeight > 0,
              let bounds = ScrollViewBounds(marquee.scrollBox.scrollView)
        else { return }
        let top = padding + CGFloat(row) * (cellHeight + spacing)
        let bottom = top + cellHeight
        let visibleTop = bounds.position.y
        let visibleBottom = visibleTop + bounds.visibleSize.height
        let target: CGFloat
        if top - padding < visibleTop {
            target = max(0, top - padding)
        } else if bottom + padding > visibleBottom {
            target = bottom + padding - bounds.visibleSize.height
        } else {
            return
        }
        bounds.scroll(to: CGPoint(x: bounds.position.x, y: target))
    }

    /// 1 画面に収まる行の数(PageUp / PageDown)。
    static func rowsPerPage(marquee: MarqueeSelection, spacing: CGFloat) -> Int {
        guard let cellHeight = marquee.anyFrame?.height, cellHeight > 0,
              let bounds = ScrollViewBounds(marquee.scrollBox.scrollView)
        else { return 1 }
        return max(1, Int(bounds.visibleSize.height / (cellHeight + spacing)))
    }
}

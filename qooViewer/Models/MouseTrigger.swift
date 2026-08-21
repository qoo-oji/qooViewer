import SwiftUI
import AppKit

/// マウス操作の割り当て先として選べるトリガー(cooViewerの「マウス設定」に相当する部分)。
///
/// ■ 「操作 → トリガー」の形になっている理由
/// 以前は InputTrigger という4択(画面の左半分をクリック/右半分をクリック/ホイール上/下)の
/// 列挙型で、設定画面も「トリガーごとにPickerで操作を選ぶ」形だった。キーボード側は
/// 逆に「操作ごとに、割り当てるキーを複数足す」形(RemappableKey + KeyBindingRow)であり、
/// 同じ設定ウインドウの中に2つの向きの UI が同居していた。マウスもキーボードに合わせて
/// 「操作 → トリガー(複数可)」へ揃えたのがこの型である。
///
/// ■ 語彙
/// - クリック = ボタン × 位置 × 修飾キー
/// - ホイール = 方向 × 修飾キー
///
/// cooViewerは `{button, modifier, action}` の辞書で同じことをしており、modifierに
/// 種別のベース値(0=クリック / 100=ドラッグ / 200〜500=4方向のドラッグジェスチャー)と
/// 修飾キーのビット(shift=1 / option=2 / control=4)を足し込んで1つの整数にしていた。
/// qooViewerは整数への詰め込みをやめ、下の `id` のような読める文字列を永続化用の
/// 識別子として使う。
///
/// ■ macOSと衝突する組み合わせは、そもそも語彙に入れていない
/// - 右ボタン / control+クリック … コンテキストメニュー。このアプリも既にそう扱っている
///   (ViewerView.swiftのcontextClickMonitor参照)
/// - command … メニューバーのショートカットと衝突する(RemappableKeyがcommandを
///   対象外にしているのと同じ理由)
/// - shift+ホイール … macOSはマウスホイール由来のスクロールイベントについて、shiftが
///   押されているとdeltaXとdeltaYを入れ替える。向きの判定が信用できないため、
///   ホイールに限りshiftを含む修飾キーを選べないようにしている(Button.availableModifiers参照)
///
/// ■ ドラッグジェスチャー(将来)
/// `id` の先頭は種別を表す接頭辞になっており、`click:` / `wheel:` に加えて **`drag:` を
/// 予約している**(`drag:b0:left:none` のような形を想定)。第2段でドラッグ4方向を足すときは
/// Input にケースを1つ増やすだけでよく、保存済みの割り当てには一切影響しない。
struct MouseTrigger: Hashable, Identifiable {

    // MARK: - 構成要素

    /// 対象にするマウスボタン。
    /// 右ボタン(button1)はコンテキストメニュー固定のため含めない。button3以降(サイドの
    /// 戻る/進むボタン)も今回は対象外だが、idFragmentを "b3" のように伸ばすだけで足せる。
    enum Button: String, CaseIterable, Hashable {
        case left
        case middle

        /// NSEventのbuttonNumber。
        var eventButtonNumber: Int {
            switch self {
            case .left: return 0
            case .middle: return 2
            }
        }

        /// idに埋め込む短い断片(NSEventのbuttonNumberに対応させている)。
        var idFragment: String { "b\(eventButtonNumber)" }

        var titleKey: LocalizedStringKey {
            switch self {
            case .left: return "Left Button"
            case .middle: return "Middle Button"
            }
        }
    }

    /// クリックした位置。ページ表示領域を左右に二分した、どちら側か。
    ///
    /// `anywhere` は「左右を問わない」を1件で表すためのもの。これがあると
    /// 「中クリックはどこでもルーペ」のような割り当てを左右2件に分けずに書ける。
    /// 解決の優先順位は **位置指定(leftHalf/rightHalf) > anywhere**
    /// (KeyBindingStore.resolvedClickAction参照)。
    enum Zone: String, CaseIterable, Hashable {
        case leftHalf
        case rightHalf
        case anywhere

        var idFragment: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .leftHalf: return "Left Half of Screen"
            case .rightHalf: return "Right Half of Screen"
            case .anywhere: return "Anywhere"
            }
        }
    }

    /// ホイールを回した向き。
    enum WheelDirection: String, CaseIterable, Hashable {
        case up
        case down

        var idFragment: String { rawValue }

        /// 割り当てのチップに出すため、短い名前にしている
        /// (設定画面の説明文では「ホイールを上へ回す」のような長い言い方を使ってよい)。
        var titleKey: LocalizedStringKey {
            switch self {
            case .up: return "Wheel Up"
            case .down: return "Wheel Down"
            }
        }
    }

    /// 組み合わせられる修飾キー。controlとcommandは上記の理由で含めない。
    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int

        static let shift = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)

        /// idに埋め込む断片。順序を固定しておかないと同じ組み合わせが別のidになってしまう。
        var idFragment: String {
            var parts: [String] = []
            if contains(.shift) { parts.append("shift") }
            if contains(.option) { parts.append("option") }
            return parts.isEmpty ? "none" : parts.joined(separator: "+")
        }

        /// 表示用。キー名そのものなので翻訳しない(RemappableKeyの "shift + ←" と同じ扱い)。
        var displayName: String? {
            var parts: [String] = []
            if contains(.shift) { parts.append("shift") }
            if contains(.option) { parts.append("option") }
            return parts.isEmpty ? nil : parts.joined(separator: " + ")
        }

        /// NSEventの修飾キーの状態から、割り当ての照合に使うModifiersを求める。
        ///
        /// control/commandが押されている場合はnilを返す。呼び出し側は、この場合
        /// 「修飾キー無し」として扱ってはならず、**そのイベントには何もしない**こと
        /// (control+クリックはコンテキストメニュー、commandはメニューバーのショートカット)。
        ///
        /// - Parameter allowsShift: shiftを受け付けるか。ホイールではfalseを渡す
        ///   (macOSがshift押下時にスクロールの軸を入れ替えるため。型のコメント参照)。
        static func from(_ flags: NSEvent.ModifierFlags, allowsShift: Bool) -> Modifiers? {
            let relevant = flags.intersection(.deviceIndependentFlagsMask)
            guard !relevant.contains(.control), !relevant.contains(.command) else { return nil }
            var result: Modifiers = []
            if relevant.contains(.shift) {
                guard allowsShift else { return nil }
                result.insert(.shift)
            }
            if relevant.contains(.option) { result.insert(.option) }
            return result
        }
    }

    /// 修飾キーを除いた「何をしたか」の部分。
    enum Input: Hashable {
        case click(Button, Zone)
        case wheel(WheelDirection)

        /// idの、修飾キーより前の部分。
        var idPrefix: String {
            switch self {
            case .click(let button, let zone): return "click:\(button.idFragment):\(zone.idFragment)"
            case .wheel(let direction): return "wheel:\(direction.idFragment)"
            }
        }

        /// この入力で選べる修飾キーの組み合わせ。
        /// ホイールだけshiftを含むものを外している(型のコメント参照)。
        var availableModifiers: [Modifiers] {
            switch self {
            case .click: return [[], .shift, .option, [.shift, .option]]
            case .wheel: return [[], .option]
            }
        }

        /// 設定画面の＋メニュー第1階層に出す名前。
        var label: Text {
            switch self {
            case .click(let button, let zone):
                return Text(button.titleKey) + Text(verbatim: " · ") + Text(zone.titleKey)
            case .wheel(let direction):
                return Text(direction.titleKey)
            }
        }
    }

    // MARK: - 本体

    let input: Input
    let modifiers: Modifiers

    /// UserDefaultsに保存する安定した識別子。例: "click:b0:leftHalf:shift" / "wheel:up:none"
    var id: String { "\(input.idPrefix):\(modifiers.idFragment)" }

    /// 割り当て済みのトリガーをチップとして表示するときの名前。
    ///
    /// 28通りすべてを文字列カタログに登録すると翻訳の手間と表記の揺れが増えるため、
    /// ローカライズ済みの断片(ボタン名・位置・ホイールの向き)を組み立てて作る。
    /// String(localized:)ではなくTextの連結にしているのは、このアプリの表示言語が
    /// OSのロケールとは独立して `.environment(\.locale, ...)` で与えられるため
    /// (CLAUDE.mdのLocalization節参照)。
    var label: Text {
        guard let prefix = modifiers.displayName else { return input.label }
        return Text(verbatim: "\(prefix) + ") + input.label
    }

    // MARK: - 選択肢

    /// 設定画面の＋メニュー第1階層。ここで「何を」だけ選び、第2階層で修飾キーを選ぶ。
    /// クリックだけで24通りあるため、1階層のフラットなメニューだと走査できない。
    struct Group: Identifiable {
        let input: Input
        var id: String { input.idPrefix }
        var label: Text { input.label }
        /// この入力で選べるトリガー(修飾キー違い)。
        var triggers: [MouseTrigger] {
            input.availableModifiers.map { MouseTrigger(input: input, modifiers: $0) }
        }
    }

    /// ＋メニューの並び順。ボタン→位置→(第2階層で)修飾キー、最後にホイール。
    static let groups: [Group] = {
        let clicks: [Group] = Button.allCases.flatMap { button in
            Zone.allCases.map { Group(input: .click(button, $0)) }
        }
        let wheels: [Group] = WheelDirection.allCases.map { Group(input: .wheel($0)) }
        return clicks + wheels
    }()

    /// 選択可能なトリガーすべて(28件)。groupsと同じ並び順。
    /// 「この操作に割り当てられているトリガー」を求めるときの走査順にも使う
    /// (KeyBindingStore.triggers(for:in:))。
    static let selectable: [MouseTrigger] = groups.flatMap(\.triggers)
}

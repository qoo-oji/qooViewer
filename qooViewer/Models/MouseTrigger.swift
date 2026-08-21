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
/// - ドラッグ = ボタン × 方向(4) × 修飾キー
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
/// ■ ドラッグジェスチャーに位置(Zone)が無い理由
/// cooViewerのジェスチャーは、クリックと同じく画面の左半分/右半分のどちらで始めたかによって
/// 動作が変わる(Controller_input.mのgestureAction:moved:がleftBoolを渡している)。これは
/// あちらの「次/前のページへ」が**1つの割り当てで左右により進む/戻るが決まる**作りだったため
/// 必要だったもので、qooViewerには画面位置基準のspatialLeft/spatialRightが操作として別にある。
/// ストロークは「どこで」より「どちらへ」が本体なので、ドラッグには位置を持たせていない。
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

    /// ドラッグジェスチャーの向き(cooViewerの「drag left/right/up/down」と同じ4方向)。
    /// 斜めや複数ストロークのジェスチャーは扱わない(あちらも1ストローク4方向のみ)。
    enum DragDirection: String, CaseIterable, Hashable {
        case left
        case right
        case up
        case down

        var idFragment: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .left: return "Drag Left"
            case .right: return "Drag Right"
            case .up: return "Drag Up"
            case .down: return "Drag Down"
            }
        }

        /// ドラッグジェスチャーとみなす最小の移動量(ポイント)。cooViewerと同じ30。
        /// これ以下の動きはクリックとして扱う(手ぶれでページ送りが効かなくなると困るため)。
        static let minimumDistance: CGFloat = 30
        /// 押してから離すまでにこれを超えたら、ジェスチャーとはみなさない(秒)。cooViewerと同じ1秒。
        /// 押したまま考えていた/掴んだまま止まっていた、という操作を弾くためのもの。
        static let maximumDuration: TimeInterval = 1

        /// 押した点から離した点までの移動量と、その間の経過時間から、ドラッグジェスチャーとして
        /// 成立するかを判定する。成立するなら、優勢な軸の向き(上下左右のいずれか1つ)を返す。
        ///
        /// cooViewerのCustomImageView.mouseUp:と同じ判定にしてある ― どちらかの軸で
        /// 30ポイントを超えて動いていること、押してから離すまでが1秒以内であること、
        /// 向きは移動量の大きい方の軸で決めること。斜めや複数ストロークは扱わない。
        ///
        /// - Parameters:
        ///   - dx: 横方向の移動量。右へ動かすと正。
        ///   - dy: 縦方向の移動量。**上へ動かすと正**(ウインドウ座標系・スクリーン座標系とも
        ///     macOSでは上が正のため、どちらの座標系で測った値でもそのまま渡せる)。
        static func from(dx: CGFloat, dy: CGFloat, duration: TimeInterval) -> Self? {
            guard duration <= maximumDuration else { return nil }
            guard abs(dx) > minimumDistance || abs(dy) > minimumDistance else { return nil }
            if abs(dx) >= abs(dy) {
                guard abs(dx) > minimumDistance else { return nil }
                return dx < 0 ? .left : .right
            }
            guard abs(dy) > minimumDistance else { return nil }
            return dy > 0 ? .up : .down
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
        case drag(Button, DragDirection)
        case wheel(WheelDirection)

        /// idの、修飾キーより前の部分。
        var idPrefix: String {
            switch self {
            case .click(let button, let zone): return "click:\(button.idFragment):\(zone.idFragment)"
            case .drag(let button, let direction):
                return "drag:\(button.idFragment):\(direction.idFragment)"
            case .wheel(let direction): return "wheel:\(direction.idFragment)"
            }
        }

        /// この入力で選べる修飾キーの組み合わせ。
        /// ホイールだけshiftを含むものを外している(型のコメント参照)。
        var availableModifiers: [Modifiers] {
            switch self {
            case .click, .drag: return [[], .shift, .option, [.shift, .option]]
            case .wheel: return [[], .option]
            }
        }

        /// 設定画面の＋メニュー第1階層に出す名前。
        var label: Text {
            switch self {
            case .click(let button, let zone):
                return Text(button.titleKey) + Text(verbatim: " · ") + Text(zone.titleKey)
            case .drag(let button, let direction):
                return Text(button.titleKey) + Text(verbatim: " · ") + Text(direction.titleKey)
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

    /// ＋メニューの並び順。クリック(ボタン→位置)→ドラッグ(ボタン→方向)→ホイール。
    /// 修飾キーは第2階層で選ぶ。
    static let groups: [Group] = {
        let clicks: [Group] = Button.allCases.flatMap { button in
            Zone.allCases.map { Group(input: .click(button, $0)) }
        }
        let drags: [Group] = Button.allCases.flatMap { button in
            DragDirection.allCases.map { Group(input: .drag(button, $0)) }
        }
        let wheels: [Group] = WheelDirection.allCases.map { Group(input: .wheel($0)) }
        return clicks + drags + wheels
    }()

    /// 選択可能なトリガーすべて(60件)。groupsと同じ並び順。
    /// 「この操作に割り当てられているトリガー」を求めるときの走査順にも使う
    /// (KeyBindingStore.triggers(for:in:))。
    static let selectable: [MouseTrigger] = groups.flatMap(\.triggers)
}

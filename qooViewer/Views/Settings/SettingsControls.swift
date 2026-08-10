import SwiftUI
import AppKit

/// 環境設定ウインドウの全タブで共有する行コンポーネント。
///
/// ■ これまでの問題
/// 各タブが `Form` + `.formStyle(.grouped)` に `Picker("長い説明文", selection:)` や
/// `Toggle("長い説明文", isOn:)` を直接置いていたため、以下の2点が同時に起きていた。
///
/// 1. ラベルが折り返す
///    grouped Formの1行は「左=ラベル / 右=コントロール」の2カラムで、幅が足りないと
///    **左のラベルが優先的に折り返す**。ラベルが文章(「以前開いたことのある本を再度開いたとき」)
///    なので、480ptの幅ではほぼ必ず2行になっていた。
///
/// 2. ドロップダウンだと分からない
///    左が折り返して縦に伸びるぶん、右のポップアップは最小幅まで潰れ、
///    「値のテキスト」と「シェブロン」が横に大きく離れる。人はこの2つが近接して初めて
///    1つのコントロールとして認識するので、離れた瞬間に「ただの説明文と飾り」に見える。
///    つまり折り返しと境界の不明瞭さは別々の問題ではなく、**同じ原因の表と裏**。
///
/// ■ ここでの解決方針
/// - ラベルは必ず**短い名詞句**にする(文章はSectionヘッダとcaptionに逃がす)
/// - ポップアップには**背景と境界線を自分で描いて**境界をはっきりさせる
///   (`SettingsPopUp` 参照。AppKitのセマンティックカラーを使うので、
///    ダークモードでは行の中でいちばん明るい要素になる)
/// - ポップアップの幅は内容幅に固定し、値とシェブロンを密着させる
/// - それでも幅が足りない言語・ウインドウ幅では `ViewThatFits` が
///   「ラベル上 / コントロール下(全幅)」の縦積みへ自動で切り替える(折り返しは起こさない)
/// - 長い説明は行の下の caption に置き、Pickerでは**選択中の項目の説明**を動的に出す

// MARK: - 汎用の1行

/// 設定1行の共通レイアウト。ラベル(短い名詞句)+ コントロール + 任意の補足説明。
///
/// 幅が足りる間は「左ラベル / 右コントロール」、足りなくなると自動的に
/// 「上ラベル / 下コントロール」へ切り替わる。どちらの場合もラベルは1行を保つ。
struct SettingRow<Control: View>: View {
    private let title: LocalizedStringKey
    private let caption: LocalizedStringKey?
    private let control: Control

    init(
        _ title: LocalizedStringKey,
        caption: LocalizedStringKey? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                // 通常: 左ラベル / 右コントロール(macOS標準の見た目)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    label
                    Spacer(minLength: 12)
                    control
                }
                // 幅が足りないとき: 上ラベル / 下コントロール(折り返しではなく段替え)
                VStack(alignment: .leading, spacing: 6) {
                    label
                    control
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let caption {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }

    private var label: some View {
        Text(title)
            .lineLimit(1)
            .layoutPriority(1)
    }
}

// MARK: - ポップアップ本体

/// 設定用ポップアップの見た目そのもの。
///
/// ■ なぜ `Picker(.menu)` をそのまま使わないのか
/// `.formStyle(.grouped)` の中では、`Picker` は macOS のシステム設定に合わせて
/// **ベゼルのない平坦な見た目**で描かれる。値のテキストとシェブロンが置いてあるだけなので、
/// 周囲の説明文と地続きに見えてしまい、押せる要素だと気づきにくい。
///
/// ■ システムのボタンスタイルには任せられない
/// 最初は `Menu` + `.menuStyle(.button)` + `.buttonStyle(.bordered)` で
/// macOS標準のプッシュボタンのベゼルを借りようとしたが、**grouped Formは行の中の
/// ボタンスタイルを自前のもので上書きしてしまい**、結局インジケータだけが描かれて
/// 見た目はほとんど変わらなかった(実機で確認済み)。
///
/// ■ したがって chrome は自分で描く
/// `.menuStyle(.borderlessButton)` でシステムの装飾を完全に外し、背景と境界線を明示的に重ねる。
///
/// ■ 面の色は「白を薄く重ねる」(重要)
/// 最初は `NSColor.controlColor` を使ったが、「リセット」タブのボタンより明らかに明るくなった
/// (実機で確認済み)。あちらも同じセクションカードの上に載っているので、下地の違いではなく
/// 単に `controlColor` のほうが濃い、というだけだった。
///
/// macOSのボタンのベゼルは「下地の上にごく薄い白を重ねたもの」に近い。そこで同じ考え方で塗る。
/// - ダークモード … カードの上に**ごく薄い白**。カードよりわずかに明るくなり、ボタンと揃う
/// - ライトモード … 白。カード自体がほぼ白なので、実際に見えるのは境界線だけになる
///   (「枠線のみ」の見た目。これも標準ボタンと同じ振る舞い)
///
/// 濃さの数値は下の `faceOpacity` 1箇所だけ。ボタンとの見え方がずれたらここを触れば
/// 全タブのポップアップに一度に反映される。
/// 境界線は `NSColor.separatorColor` に任せてあり、こちらは両モードとも自動で適切な濃さになる。
///
/// ■ クリック領域と枠が一致するようにしてある
/// 余白は `Menu` の外側ではなく**ラベルの内側**に入れてある。`.borderlessButton` では
/// ラベル全体がボタンの当たり判定になるため、こうすることで
/// 「枠線の内側はどこを押しても開く」状態になる(枠だけ描いて外側に余白を付けると、
/// 枠の縁が反応しない不感帯になってしまう)。
///
/// ■ 中身は `Picker(.inline)`
/// メニューの中身を素の `Button` で並べるとチェックマークが出ず、いまどれが選ばれているのか
/// メニューを開いても分からない。`Picker` を `.inline` スタイルでメニューに入れると、
/// 選択中の項目にシステム標準のチェックマークが付く。
private struct SettingsPopUp<Options: View, Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    let width: CGFloat?
    @ViewBuilder let options: () -> Options
    @ViewBuilder let label: () -> Label

    private let cornerRadius: CGFloat = 6

    /// 下地に重ねる白の濃さ。「リセット」タブのボタンと同じ明るさになるよう合わせてある。
    /// ポップアップの明るさを調整したいときは、この2つの値だけを触ればよい。
    private var faceOpacity: Double {
        colorScheme == .dark ? 0.07 : 0.85
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        Menu {
            options()
        } label: {
            HStack(spacing: 6) {
                label()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .padding(.vertical, 4)
            // 文字のない余白部分を押しても開くようにする。
            .contentShape(shape)
        }
        .menuStyle(.borderlessButton)
        // 自前のシェブロンを置いているので、システム側のインジケータは消す。
        .menuIndicator(.hidden)
        .modifier(PopUpWidth(width: width))
        .background(shape.fill(Color.white.opacity(faceOpacity)))
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        // 無効時はベゼルごと沈ませる(ラベルだけが薄くなって枠が濃いまま残るのを避ける)。
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// 固定幅が指定されていればその幅、なければ内容幅(`fixedSize`)にする。
private struct PopUpWidth: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width)
        } else {
            content.fixedSize()
        }
    }
}

// MARK: - ポップアップ行

/// `SettingsOption` に適合したenumを選ばせるポップアップ行。
///
/// - ポップアップに出るのは `shortTitleKey`(短い名前)だけ。閉じた状態で省略されない。
/// - `detailKey` を持つ選択肢では、いま選ばれている項目の説明が行の下に自動で出る。
///   選択を変えると説明も変わるので、「この選択肢が何をするのか」は常に画面上にある。
struct SettingsPicker<Value: SettingsOption>: View {
    private let title: LocalizedStringKey
    private let fixedCaption: LocalizedStringKey?
    @Binding private var selection: Value

    /// - Parameters:
    ///   - title: 短い名詞句のラベル(例: 「開始ページ」)。
    ///   - caption: 選択肢によらず常に出したい補足。nilなら選択中の項目の `detailKey` を使う。
    init(
        _ title: LocalizedStringKey,
        selection: Binding<Value>,
        caption: LocalizedStringKey? = nil
    ) {
        self.title = title
        self._selection = selection
        self.fixedCaption = caption
    }

    var body: some View {
        SettingRow(title, caption: fixedCaption ?? selection.detailKey) {
            SettingsPopUp(width: nil) {
                Picker(selection: $selection) {
                    ForEach(Array(Value.allCases)) { option in
                        Text(option.shortTitleKey).tag(option)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                // 選択中の項目だけを表示すると、選ぶたびにボタンの幅が変わってしまう。
                // すべての選択肢を重ねて置き(非表示)、いちばん長い項目の幅を確保しておくことで、
                // どれを選んでもボタンの大きさが動かない(NSPopUpButtonと同じ振る舞い)。
                ZStack(alignment: .leading) {
                    ForEach(Array(Value.allCases)) { option in
                        Text(option.shortTitleKey)
                            .lineLimit(1)
                            .hidden()
                    }
                    Text(selection.shortTitleKey)
                        .lineLimit(1)
                }
            }
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(selection.shortTitleKey))
        }
    }
}

/// `SettingsOption` に適合していない値を選ばせるためのポップアップ行。
///
/// 選択肢が実行時に決まる場合(キー・マウス設定の操作一覧)や、`Optional` を扱う場合など、
/// `SettingsPicker` の型制約に収まらないケース用。見た目と余白は `SettingsPicker` と揃う。
///
/// `SettingsPicker` と違って選択肢を型から列挙できないため、閉じた状態に出す文字列は
/// `currentTitle` で明示的に渡す。
///
/// - Note: `controlWidth` を指定しないとポップアップは内容幅になる。
///   選択肢が数十個あって長い文字列を含むとき(操作一覧など)は内容幅が過大になるため、
///   固定幅を渡してコントロールの境界を一定に保つこと。
struct SettingsPickerRow<Selection: Hashable, Options: View>: View {
    private let title: LocalizedStringKey
    private let currentTitle: LocalizedStringKey
    private let caption: LocalizedStringKey?
    private let controlWidth: CGFloat?
    @Binding private var selection: Selection
    private let options: Options

    init(
        _ title: LocalizedStringKey,
        selection: Binding<Selection>,
        currentTitle: LocalizedStringKey,
        caption: LocalizedStringKey? = nil,
        controlWidth: CGFloat? = nil,
        @ViewBuilder options: () -> Options
    ) {
        self.title = title
        self._selection = selection
        self.currentTitle = currentTitle
        self.caption = caption
        self.controlWidth = controlWidth
        self.options = options()
    }

    var body: some View {
        SettingRow(title, caption: caption) {
            SettingsPopUp(width: controlWidth) {
                Picker(selection: $selection) {
                    options
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(currentTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(currentTitle))
        }
    }
}

// MARK: - トグル

/// オン/オフ行。スイッチは幅が変わらないので常に右端固定で、ラベル側が幅を譲る。
///
/// ラベルはあくまで短い名詞句/動詞句にして、条件や副作用の説明は `caption` に置く。
struct SettingsToggle: View {
    private let title: LocalizedStringKey
    private let caption: LocalizedStringKey?
    @Binding private var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>, caption: LocalizedStringKey? = nil) {
        self.title = title
        self._isOn = isOn
        self.caption = caption
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    Text(caption)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(isOn: $isOn) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text(title))
        }
        .padding(.vertical, 2)
    }
}

// MARK: - スライダー

/// 数値スライダー行。
///
/// これまでは `Text("Interval: ") + Text("\(Int(v))") + Text(" sec")` のように
/// 文字列連結でラベルを組み立てていたが、これは
/// (a) 語順が固定されるためローカライズに弱く、
/// (b) ラベルと現在値が混ざって走査しづらい。
/// ここでは「左=項目名 / 右=現在値」に分け、値は等幅数字にして
/// ドラッグ中に桁数で行がガタつかないようにしている。
struct SettingsSlider: View {
    private let title: LocalizedStringKey
    private let caption: LocalizedStringKey?
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let format: (Double) -> String

    init(
        _ title: LocalizedStringKey,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        caption: LocalizedStringKey? = nil,
        format: @escaping (Double) -> String
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.caption = caption
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Slider(value: $value, in: range, step: step) {
                EmptyView()
            } minimumValueLabel: {
                Text(format(range.lowerBound))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            } maximumValueLabel: {
                Text(format(range.upperBound))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .labelsHidden()
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(format(value)))

            if let caption {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 箇条書き

/// 並列に並ぶ項目を箇条書きで見せるためのブロック。
///
/// 「お気に入り・ブックマーク・レイアウト設定・読書履歴が破損したり…」のように、
/// 中黒で並列要素をつないだ長い一文は、どこまでが列挙でどこからが述語なのかを
/// 読み手が毎回組み立て直す必要があり、走査しづらい。
/// 列挙は列挙として縦に割り、地の文は短い1文に保つ。
struct SettingsBulletList: View {
    private let items: [LocalizedStringKey]

    init(_ items: [LocalizedStringKey]) {
        self.items = items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "•")
                        .foregroundStyle(.secondary)
                        // 記号はVoiceOverでは読み上げない(項目の本文だけ読ませる)。
                        .accessibilityHidden(true)
                    Text(items[index])
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - タブの土台

/// 各設定タブの外枠。`Form` のスタイル・余白・スクロールの扱いを1か所に集約する。
///
/// タブごとに `.formStyle(.grouped).padding()` を書き写していると、
/// タブが増えるたびに微妙な差異が生まれる。ここを通すことで見た目が必ず揃い、
/// 将来「全タブに検索フィールドを足す」「全タブの余白を変える」といった変更も1か所で済む。
struct SettingsTabContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

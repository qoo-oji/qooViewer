import SwiftUI
import AppKit

/// 環境設定ウインドウの全画面で共有する行コンポーネント。
///
/// ■ これまでの問題
/// 各画面が `Form` + `.formStyle(.grouped)` に `Picker("長い説明文", selection:)` や
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
/// - ラベルは**短い語句**にする(長い文章はSectionヘッダとホバーの吹き出しに逃がす)
/// - ポップアップには**背景と境界線を自分で描いて**境界をはっきりさせる
///   (`SettingsPopUp` 参照。AppKitのセマンティックカラーを使うので、
///    ダークモードでは行の中でいちばん明るい要素になる)
/// - ポップアップの幅は内容幅に固定し、値とシェブロンを密着させる
/// - それでも幅が足りない言語・ウインドウ幅では `ViewThatFits` が
///   「ラベル上 / コントロール下(全幅)」の縦積みへ自動で切り替える(折り返しは起こさない)
///
/// ■ 説明文を常時表示するのをやめた(重要な方針転換)
/// 以前は「ラベルは短い名詞句にして、説明は行の下の caption に常時出す」という方針だった。
/// その結果ほぼすべての行が「項目名 / コントロール / 説明文」の3要素になり、
/// **画面が説明文で埋まって認知コストが高い**という指摘を受けた(ユーザーからの指摘)。
/// 1行ぶんの情報を読むのに必ず2行読まされるうえ、目的の項目を探すときには
/// 説明文がすべて雑音になる。
///
/// そこで優先順位を次のように決め直した。
///   1. **項目名に吸収できる説明は、項目名を伸ばして消す**
///      「前回の本を開く」+「前回終了したときに読んでいた本を開き直します」ではなく、
///      「前回読んでいた本を開き直す」の1行にする。ラベルが多少長くなっても、
///      読む量は半分以下になり、走査もしやすい。
///      (`SettingRow` は幅が足りなければ自動で段替えするので、多少の長さは吸収できる)
///   2. **吸収できないものだけホバーの吹き出しへ**(`help:`)
///      閾値の定義や、副作用・例外の注意書きなど、項目名に入れると長すぎるもの。
///      補足があることは項目名の右のⓘで示す。
///   3. **Pickerの選択肢に説明は付けない**
///      以前は選択肢ごとに1文の説明(`detailKey`)を持たせ、選ばれている項目のぶんを
///      行の下に出していた。整理にあたって一度これをメニューの中へ移したが、
///      最終的に説明そのものを廃止した。このアプリを使う人には選択肢名だけで十分であり、
///      説明が要るということは選択肢名のほうが悪い、という判断(ユーザーの指示)。
///      `SettingsOption` から `detailKey` ごと削除してある。
///
/// したがって新しい行を足すときは、**まず項目名だけで済ませられないかを試すこと**。
/// `help:` は最後の手段であって、既定の置き場所ではない。

// MARK: - 項目名

/// 設定行の項目名。補足(`help`)があるときは末尾にⓘを添える。
/// ⓘにカーソルを合わせると吹き出しが、クリックするとポップオーバーが出る。
///
/// ■ なぜⓘを**ボタン**にしてあるのか(重要。素の記号に戻さないこと)
/// 最初は「押せない、印だけの記号」にして、`.help()` を項目名とⓘを含む `HStack` 全体に
/// 付けていた。そのほうが小さな的を狙わせずに済むからである。
/// ところが実機で確認したところ、**`.help()` は素のコンテナ(`HStack`)に付けても
/// 吹き出しが出なかった**。同じビルドの中で `Button` に付けた `.help()` は正しく出るので、
/// `.help()` が効くかどうかはAppKit側のビューを伴うかどうかに依存している。
/// 補足の置き場所がここしか無い以上、「たぶん出る」では困るため、
/// 確実に吹き出しを持てる `Button` にした。
///
/// ボタンにしたことで、押したときの動作も与えられる。押すと同じ文がポップオーバーで開く。
/// ホバーで読めるものをクリックでも読めるようにするのは重複ではなく、
/// 「カーソルを止めて1〜2秒待つ」という操作を知らない/できない人への経路になる
/// (トラックパッドの操作中や、拡大表示を使っている場合など)。
///
/// ■ ⓘを出す条件
/// `help` があるときだけ。無い行に空の場所を確保して縦位置を揃える、といったことはしない。
/// ⓘが並んでいるかどうか自体が「補足のある行はどれか」の一覧になるほうが役に立つ。
struct SettingsRowLabel: View {
    let title: LocalizedStringKey
    let help: LocalizedStringKey?
    /// 項目名を1行に保つか。横並びの行(`SettingRow`)では1行を保ち、
    /// 幅が足りなければ呼び出し側の `ViewThatFits` が段替えする。
    /// トグルのように右のコントロールが固定幅の行では、折り返しを許す。
    var allowsWrapping: Bool = false

    @State private var isShowingHelp = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .lineLimit(allowsWrapping ? nil : 1)
                .fixedSize(horizontal: false, vertical: allowsWrapping)

            if let help {
                Button {
                    isShowingHelp = true
                } label: {
                    // 最初は .caption + .tertiary にしていたが、暗い下地でほとんど見えず、
                    // 「補足がある行」に気づけなかった(ユーザーからの指摘)。
                    // .tertiary は本来「あってもなくてもよい装飾」の濃さで、
                    // このⓘのように**気づかれなければ意味が無い**印には弱すぎる。
                    // 項目名(13pt)より少し小さい12ptに留めつつ、濃さは .secondary まで上げてある。
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text(help))
                .accessibilityLabel(Text("More Information"))
                .popover(isPresented: $isShowingHelp, arrowEdge: .bottom) {
                    // ■ 幅は `maxWidth` ではなく固定の `width` にしてある(重要)
                    // 以前は `.frame(maxWidth: 320)` だった。macOS 26 では問題なかったが、
                    // macOS 15 (Sequoia) で「ポップオーバーの窓だけが縦に異常に伸び、本文が
                    // 下端に張り付いて上が巨大な空白になる」という報告があった(ユーザー報告。
                    // こちらの26環境では再現せず)。本文の大きさは正しく、窓の高さだけが
                    // 外れているので、SwiftUIの中身ではなく NSPopover に渡る contentSize の
                    // 高さが誤っている形。`maxWidth` だけだと幅が「提案待ち」のまま高さを
                    // 測ることになり、提案が無い段階で測られると高さが定まらない。
                    // 幅を固定すれば折り返し位置が決まり高さが一意になるので、どのOSでも
                    // 同じ大きさに落ち着く。短い補足でも幅320ptの箱になるが、それは許容する。
                    Text(help)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 320, alignment: .leading)
                        .padding(12)
                }
            }
        }
    }
}

// MARK: - 汎用の1行

/// 設定1行の共通レイアウト。項目名 + コントロール(+ ホバーで出る補足)。
///
/// 幅が足りる間は「左ラベル / 右コントロール」、足りなくなると自動的に
/// 「上ラベル / 下コントロール」へ切り替わる。どちらの場合もラベルは1行を保つ。
struct SettingRow<Control: View>: View {
    private let title: LocalizedStringKey
    private let help: LocalizedStringKey?
    private let control: Control

    /// - Parameters:
    ///   - title: 項目名。**まずこれだけで意味が通るか試すこと**(ファイル冒頭の方針を参照)。
    ///   - help: 項目名に入れると長すぎる補足。ホバーの吹き出しで出る。
    init(
        _ title: LocalizedStringKey,
        help: LocalizedStringKey? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.help = help
        self.control = control()
    }

    var body: some View {
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
        .padding(.vertical, 2)
    }

    private var label: some View {
        SettingsRowLabel(title: title, help: help)
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
/// 最初は `NSColor.controlColor` を使ったが、「リセット」画面のボタンより明らかに明るくなった
/// (実機で確認済み)。あちらも同じセクションカードの上に載っているので、下地の違いではなく
/// 単に `controlColor` のほうが濃い、というだけだった。
///
/// macOSのボタンのベゼルは「下地の上にごく薄い白を重ねたもの」に近い。そこで同じ考え方で塗る。
/// - ダークモード … カードの上に**ごく薄い白**。カードよりわずかに明るくなり、ボタンと揃う
/// - ライトモード … 白。カード自体がほぼ白なので、実際に見えるのは境界線だけになる
///   (「枠線のみ」の見た目。これも標準ボタンと同じ振る舞い)
///
/// 濃さの数値は下の `faceOpacity` 1箇所だけ。ボタンとの見え方がずれたらここを触れば
/// 全画面のポップアップに一度に反映される。
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

    /// 下地に重ねる白の濃さ。「リセット」画面のボタンと同じ明るさになるよう合わせてある。
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
/// 閉じた状態にもメニューの中にも出るのは `shortTitleKey`(短い名前)だけ。
/// 選択肢ごとの説明は持たない(ファイル冒頭の方針3を参照)。
///
/// ■ メニュー項目に副題を出すのは断念した経緯(再挑戦する人向け)
/// 一時期、選択肢の説明をメニュー項目の副題(`NSMenuItem.subtitle`)として出そうとした。
/// SwiftUIには「`Button` のラベルに `Text` を2つ並べると、1つ目が題・2つ目が副題になる」
/// という橋渡しがあり、`Picker` の中でも `.tag` による選択反映と併用できる。
/// **しかし実機では、同じ書き方をした4つの選択肢のうち1つにしか副題が描かれず、
/// しかもその1つも文末が欠けた**(条件分岐の有無に関わらず再現。macOS 26で確認)。
/// この橋渡しはAppleも「発見的で、構成によって結果が変わる」と認めている挙動なので、
/// 見た目が安定しないまま使うことはできない。
/// 結果としてこの機能自体が不要と判断されたため追わなかったが、将来また副題を出したくなったら、
/// ここは**素直にAppKitでNSMenuを組む**べきところで、SwiftUIのTextの並べ方で粘る場所ではない。
struct SettingsPicker<Value: SettingsOption>: View {
    private let title: LocalizedStringKey
    private let help: LocalizedStringKey?
    @Binding private var selection: Value

    /// - Parameters:
    ///   - title: 項目名(例: 「開始ページ」)。
    ///   - help: 補足。ホバーの吹き出しで出る。
    init(
        _ title: LocalizedStringKey,
        selection: Binding<Value>,
        help: LocalizedStringKey? = nil
    ) {
        self.title = title
        self._selection = selection
        self.help = help
    }

    var body: some View {
        SettingRow(title, help: help) {
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
    private let help: LocalizedStringKey?
    private let controlWidth: CGFloat?
    @Binding private var selection: Selection
    private let options: Options

    init(
        _ title: LocalizedStringKey,
        selection: Binding<Selection>,
        currentTitle: LocalizedStringKey,
        help: LocalizedStringKey? = nil,
        controlWidth: CGFloat? = nil,
        @ViewBuilder options: () -> Options
    ) {
        self.title = title
        self._selection = selection
        self.currentTitle = currentTitle
        self.help = help
        self.controlWidth = controlWidth
        self.options = options()
    }

    var body: some View {
        SettingRow(title, help: help) {
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
/// スイッチの幅が固定で段替えの必要が無いぶん、ここのラベルは他の行より長くできる。
/// 「何がオンになるのか」が1行で言い切れるなら、`help` を使わずラベルに書いてしまうこと
/// (ファイル冒頭の方針を参照)。長くなれば折り返して縦に伸びるだけで、レイアウトは崩れない。
struct SettingsToggle: View {
    private let title: LocalizedStringKey
    private let help: LocalizedStringKey?
    @Binding private var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>, help: LocalizedStringKey? = nil) {
        self.title = title
        self._isOn = isOn
        self.help = help
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            SettingsRowLabel(title: title, help: help, allowsWrapping: true)
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
    private let help: LocalizedStringKey?
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let showsStepper: Bool
    private let format: (Double) -> String

    /// - Parameter showsStepper: 現在値の右に⬆⬇のステッパーを添える。
    ///   刻みが細かい設定でだけ使うこと ―― スライダーの1ステップが1pt未満になると
    ///   ドラッグでは狙った値に止められなくなるため(スライダーの実効幅はおよそ300pt
    ///   しかないので、`(range幅 / step)`が300を超えたら添えると考えてよい)。
    ///   刻みが粗い設定にまで付けると、押す必要のないボタンが全画面に並ぶことになる。
    init(
        _ title: LocalizedStringKey,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        help: LocalizedStringKey? = nil,
        showsStepper: Bool = false,
        format: @escaping (Double) -> String
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.help = help
        self.showsStepper = showsStepper
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                SettingsRowLabel(title: title, help: help, allowsWrapping: true)
                Spacer(minLength: 12)
                Text(format(value))
                    .monospacedDigit()
                    .fontWeight(.semibold)
                if showsStepper {
                    // ラベルはすぐ左の現在値が担っているので、ステッパー自身は矢印だけにする。
                    // 範囲を`Slider`と同じ`range`で与えているため、端まで来た側は自動的に
                    // 押せなくなる(スライダーと食い違って範囲外の値を作ることはない)。
                    Stepper(value: $value, in: range, step: step) {
                        EmptyView()
                    }
                    .labelsHidden()
                    .accessibilityLabel(Text(title))
                    .accessibilityValue(Text(format(value)))
                }
            }

            Slider(value: $value, in: range, step: step) {
                EmptyView()
            } minimumValueLabel: {
                // 両端の数値は「いまどのくらいの位置にいるのか」を読み取るための目盛りで、
                // 飾りではない。当初の .caption2 + .tertiary では暗い下地に埋もれて読めず、
                // .caption + .secondary へ上げてもまだ見づらいという再指摘を受けた。
                //
                // 色を薄くして順位を付けるのをやめ、**3つの数値すべてを地の文と同じ濃さで描く**。
                // 順位は色ではなく大きさと太さで示す ―― 現在値は本文サイズの太字、
                // 両端は一段小さい通常の太さ。薄い文字は「読めるが目立たない」ではなく
                // 単に「読めない」になりやすく、目盛りとしては役に立たない。
                //
                // `.foregroundStyle(.primary)` は**省略できない**。指定しないと
                // `Slider` が両端のラベルに独自の淡い色を当ててしまい、
                // 親から地の文の色を受け継いでくれない(実機で確認済み。
                // 濃さを2度上げても直らなかった原因はこれだった)。
                Text(format(range.lowerBound))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            } maximumValueLabel: {
                Text(format(range.upperBound))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .labelsHidden()
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(format(value)))
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 初期設定に戻す

/// 環境設定の各画面の末尾に置く「初期設定に戻す」セクション(ユーザー要望)。
///
/// ■ 文言は全画面で同じ「初期設定に戻す」に統一すること
/// 以前は画面ごとに違っていた(「Reset to Defaults」と「Reset This Mode to Defaults」)。
/// 同じ役割のボタンが画面によって別の名前で出てくると、押す前に「これは他と同じものか」を
/// 毎回考えることになる(ユーザーからの指摘)。**何が戻るのかの違いはラベルではなく
/// `help` で説明する** ―― 例えば「表示モード別の操作」は選択中の表示モードだけが対象で、
/// その但し書きはラベルに入れるには長すぎる。
///
/// ■ 置かない画面
/// 「フォルダのアクセス権」と「リセット」には置かない(ユーザーの指示)。前者はアクセス許可の
/// 一覧で、戻すべき「設定」を持たない。後者は画面そのものが削除操作の集まりで、
/// そこへ「初期設定に戻す」を足しても意味が重なるだけになる。
struct SettingsResetSection: View {
    /// 何が戻るのか(および何が戻らないのか)の説明。ラベルは全画面共通なので、
    /// 画面ごとの違いはここだけで表す。
    private let help: LocalizedStringKey
    private let action: () -> Void

    init(help: LocalizedStringKey, action: @escaping () -> Void) {
        self.help = help
        self.action = action
    }

    var body: some View {
        Section {
            Button("Reset to Defaults", role: .destructive, action: action)
                .help(Text(help))
        }
    }
}

// MARK: - 色見本

/// 色を1つ選ばせる行。項目名の右に現在の色の見本を置き、押すと色の指定ダイアログ
/// (`CustomColorPickerSheet`)を開く。
///
/// ■ なぜ`ColorPicker`(SwiftUI標準)を使わないのか
/// 標準のカラーウェルはmacOSのカラーパネルを開く。あれはアプリ全体で1枚しか無く、
/// 環境設定ウインドウより前面に居座るうえ、選んだ色は`Color`として返るため、
/// このアプリがUserDefaultsへ保存している形式(sRGBのRGB各8bit。RGBColorValue参照)へ
/// 落とすときに色空間の解釈がOS任せになる。既にパレット+RGB数値のダイアログを持っている
/// (背景色用に作った`CustomColorPickerSheet`)ので、色を選ぶ体験を1つに揃えている。
///
/// ■ ダイアログ自体はこの行が持たない
/// `.sheet`は行ではなく画面の土台側に付ける必要がある(Formのセクション内のViewに付けると、
/// スクロールによる行の再生成に表示状態が引きずられうる。RenderingSettingsView/
/// AppearanceSettingsViewの`.sheet`のコメント参照)。そのためこの行は「押された」ことを
/// `action`で伝えるだけにして、どのダイアログを開くかは画面側が決める。
struct SettingsColorRow: View {
    private let title: LocalizedStringKey
    private let help: LocalizedStringKey?
    private let color: Color
    private let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        color: Color,
        help: LocalizedStringKey? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.color = color
        self.help = help
        self.action = action
    }

    var body: some View {
        SettingRow(title, help: help) {
            Button(action: action) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(color)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                // 白や白に近い色が行の地に溶けないよう、常に薄い枠線を敷く
                                // (CustomColorPickerSheetのパレットのマスと同じ理由)。
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .frame(width: 36, height: 16)
                    Text("Change…")
                }
            }
            .accessibilityLabel(Text(title))
        }
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
        // 小さく薄い補足文としてではなく、本文として描く。
        // 使っているのは「リセット」画面の「何が消えるのか」だけで、そこは
        // 読み飛ばされては困る箇所だから(ResetDataSettingsView のコメント参照)。
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 画面の土台

/// 環境設定の各画面(サイドバーで選ぶ1項目分)の外枠。
/// `Form` のスタイル・余白・スクロールの扱いを1か所に集約する。
///
/// 画面ごとに `.formStyle(.grouped).padding()` を書き写していると、
/// 画面が増えるたびに微妙な差異が生まれる。ここを通すことで見た目が必ず揃い、
/// 将来「全画面に検索フィールドを足す」「全画面の余白を変える」といった変更も1か所で済む。
///
/// この分離は実際に効いた。環境設定を `TabView` の8タブから、システム設定と同じ
/// サイドバー方式(`SettingsView` / `SettingsPane`)へ作り替えたとき、
/// 8画面のどれも中身を書き換えずに済んでいる。
/// (型名は当時 `SettingsTabContainer` だったが、もうタブではないので改名した。)
struct SettingsPaneContainer<Content: View>: View {
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

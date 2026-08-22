import SwiftUI

/// 任意の色を指定するためのダイアログ。
///
/// 元はビューアの背景色専用(`BackgroundColorPickerSheet`)だったが、「外観」画面の追加で
/// 同じ体裁のダイアログが複数の設定 ― 背景色、すりガラスの面ごとの重ね色、ページ一覧で
/// 表示中のページを示す枠の色 ― から必要になったため、見出しだけを差し替えられる汎用の
/// ダイアログに一般化した。中身(パレット・RGB調整・プレビュー・Revert/Cancel/OK)は
/// どの用途でも同じでよい。
///
/// 上下2段の構成になっている。
/// - 上段: 汎用のカラーパレット。1マス押すと、その色が下段のRGBへ読み込まれる
///   (パレットは「だいたいの色をすばやく決める」ための入口で、確定手段ではない)
/// - 下段: R/G/Bそれぞれのスライダーと数値入力欄、および調整中の色のプレビュー
///
/// 編集中の値は`workingColor`(このView内の@State)だけに持ち、OKを押したときに初めて
/// 呼び出し元へ渡す。キャンセルすると何も起きないので、いじった結果が気に入らなければ
/// そのまま閉じれば元の色のままになる。
struct CustomColorPickerSheet: View {
    /// ダイアログの見出しに出す、何の色を選んでいるのかを表す文言。
    /// 呼び出し元ごとに違うのはここだけなので、パラメータもこれ1つに留めてある。
    let titleKey: LocalizedStringKey
    /// ダイアログを開いた時点のカスタム色(編集の出発点)。
    let initialColor: RGBColorValue
    /// OKが押されたときだけ、確定した色を渡して呼ばれる。キャンセル時は呼ばれない。
    let onCommit: (RGBColorValue) -> Void
    /// キャンセルされたときだけ呼ばれる。呼び出し元は「カスタム」を選んだこと自体を
    /// ダイアログを開く前の値へ戻すのに使う(AppearanceSettingsView参照)。
    ///
    /// `.sheet(onDismiss:)`ではなく専用のクロージャにしているのは、あちらがOKとキャンセルの
    /// どちらでも呼ばれてしまい区別できないため。このシートはシート外クリックでは閉じず、
    /// Escは下の「キャンセル」ボタン(`.cancelAction`)が受けるので、閉じる経路は
    /// OKとキャンセルの2つしかなく、取りこぼしは起きない。
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var workingColor: RGBColorValue

    init(
        titleKey: LocalizedStringKey,
        initialColor: RGBColorValue,
        onCommit: @escaping (RGBColorValue) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.titleKey = titleKey
        self.initialColor = initialColor
        self.onCommit = onCommit
        self.onCancel = onCancel
        self._workingColor = State(initialValue: initialColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                paletteSection
                Divider()
                adjustmentSection
            }
            .padding(16)

            Divider()
            bottomBar
        }
        // パレットの横幅(swatchSize×列数+間隔)+左右の余白で決まる幅に固定する。
        // 可変にすると、パレットのマスだけが伸び縮みして格子が歪んで見える。
        //
        // 縦の余白をやや詰めてあるのは、環境設定ウインドウ(高さ約590pt)にシート全体が
        // 収まるようにするため。macOSは親ウインドウより高いシートも下へはみ出させて描くが、
        // ボタン列だけがウインドウの外に浮いて見えるのを避けたい。
        .frame(width: Self.paletteWidth + 32)
    }

    // MARK: - 見出し

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleKey)
                .font(.headline)
            Text("Pick a color from the palette, then fine-tune it with the RGB sliders.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - 上段: パレット

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Palette")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: Self.swatchSpacing) {
                ForEach(Array(Self.palette.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: Self.swatchSpacing) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, entry in
                            swatchButton(for: entry)
                        }
                    }
                }
            }
        }
    }

    private func swatchButton(for entry: RGBColorValue) -> some View {
        let isSelected = entry == workingColor
        return Button {
            workingColor = entry
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(entry.color)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        // 白や白に近いマスが背景に溶けないよう、全マスに薄い枠線を敷く。
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .overlay {
                    if isSelected {
                        // チェックマークの色は下地の明るさで反転させる(暗いマスの上の黒い
                        // チェックマークは見えないため。RGBColorValue.isLight参照)。
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(entry.isLight ? Color.black : Color.white)
                    }
                }
                .frame(width: Self.swatchSize, height: Self.swatchSize)
        }
        .buttonStyle(.plain)
        .help(entry.hexString)
        .accessibilityLabel(Text(entry.hexString))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - 下段: RGB調整とプレビュー

    private var adjustmentSection: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 10) {
                channelRow("Red", value: $workingColor.red, tint: .red)
                channelRow("Green", value: $workingColor.green, tint: .green)
                channelRow("Blue", value: $workingColor.blue, tint: .blue)
            }
            .frame(maxWidth: .infinity)

            preview
        }
    }

    /// R/G/Bの1行。スライダーと数値入力欄はどちらも同じ`value`を編集するので、
    /// どちらを動かしてももう一方とプレビューが即座に追従する。
    private func channelRow(
        _ title: LocalizedStringKey,
        value: Binding<Int>,
        tint: Color
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 44, alignment: .leading)
                .lineLimit(1)

            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0.rounded()) }
                ),
                in: 0...255,
                step: 1
            )
            .tint(tint)
            .labelsHidden()
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(verbatim: "\(value.wrappedValue)"))

            // 数値の直接指定。RGBColorValue側で0〜255に丸められるため、範囲外を打ち込んでも
            // 壊れない(打ち込んだ直後は入力欄に範囲外の文字が残るが、確定時に丸められる)。
            TextField(
                title,
                value: value,
                format: .number
            )
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 56)
            .accessibilityLabel(Text(title))
        }
    }

    private var preview: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(workingColor.color)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .frame(width: 84, height: 84)
                .accessibilityLabel(Text("Preview"))
                .accessibilityValue(Text(workingColor.hexString))

            Text(workingColor.hexString)
                .font(.caption)
                .monospaced()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - ボタン

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // 開いた時点の色に戻す。パレットとスライダーで散々いじったあと、
            // ダイアログを閉じずにやり直せるようにするための逃げ道。
            Button("Revert") {
                workingColor = initialColor
            }
            .disabled(workingColor == initialColor)

            Spacer()

            Button("Cancel", role: .cancel) {
                onCancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("OK") {
                onCommit(workingColor)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - パレットの中身

    private static let swatchSize: CGFloat = 28
    private static let swatchSpacing: CGFloat = 4
    private static let paletteColumnCount = 12
    private static let paletteWidth =
        swatchSize * CGFloat(paletteColumnCount) + swatchSpacing * CGFloat(paletteColumnCount - 1)

    /// 汎用のカラーパレット(用途を問わず使える一般的な色見本)。
    ///
    /// 1行目がグレースケール(白→黒)、2行目以降が色相12段 × 明るさ/鮮やかさ5段。
    /// 定数表をベタ書きせず式から作っているのは、行や列を増減したくなったときに
    /// 下のtones/列数を変えるだけで格子が破綻せずに済むため。
    private static let palette: [[RGBColorValue]] = {
        var rows: [[RGBColorValue]] = []

        // グレースケール。白から黒までを列数ぶんの等間隔で並べる。
        rows.append((0..<paletteColumnCount).map { column in
            let level = Int((1 - Double(column) / Double(paletteColumnCount - 1)) * 255)
            return RGBColorValue(red: level, green: level, blue: level)
        })

        // 上2行は白を混ぜた淡い色、真ん中が純色、下2行は黒を混ぜた濃い色。
        let tones: [(saturation: Double, brightness: Double)] = [
            (0.25, 1.00),
            (0.50, 1.00),
            (1.00, 1.00),
            (1.00, 0.75),
            (1.00, 0.50),
        ]
        for tone in tones {
            rows.append((0..<paletteColumnCount).map { column in
                RGBColorValue.fromHSB(
                    hue: Double(column) / Double(paletteColumnCount),
                    saturation: tone.saturation,
                    brightness: tone.brightness
                )
            })
        }

        return rows
    }()
}

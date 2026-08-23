import SwiftUI

/// サイドパネルのリソースモニタの折れ線グラフ1枚(Windowsのタスクマネージャ風: 右端が
/// 「いま」で、時間が経つと左へ流れる)。CPU・メモリ・ディスクの3枚がこれを使う。
///
/// ■ Swift Chartsではなく`Canvas`で描く理由
/// 描くのは最大120点の折れ線が1〜2本と、横線が数本だけ。1秒ごとに再描画しても`Path`を
/// 1本作るだけで済み、Swift Chartsの軸・凡例・アニメーションの仕組みは不要で重い。
/// それ以上に、**「文字の影」(輪郭)の扱いを自分で決められる**ことが大きい(下記)。
///
/// ■ 「文字の影」(パネルの重ね色と同化する問題)への対処
/// グラフは3つの部品に分けて、それぞれ別の手当てをしている。
/// - プロット領域(枠): `Color.primary.opacity(0.07)`の自前の地を持つ。重ね色が何色でも
///   パネルより少しだけ濃い(ライト)/明るい(ダーク)面になるので、枠そのものが消えることは
///   ない。輪郭の設定が0より大きいときは、さらに反対色の細い縁を付ける(`panelControlWell`と
///   同じ考え方)。
/// - 折れ線: 輪郭の設定ぶんだけ太い反対色の線を**先に**描き、その上に本来の色の線を描く。
///   文字に`panelOutlinedContent`が掛けている「同じ形を太らせて後ろに敷く」をCanvasの中で
///   再現したもの。設定が0なら何も足さない。
/// - 右肩の数値・凡例(Text): 通常どおり`panelOutlinedContent()`。
///
/// ■ 縦軸
/// `maxValue`を呼び出し側が決める(CPUは100%固定、メモリは上限と実測の大きいほう、
/// ディスクは実測の最大)。データに合わせて毎秒スケールが伸び縮みすると読みづらいので、
/// 呼び出し側で切りの良い値に丸めてから渡す(`ResourceGraphScale`参照)。
struct ResourceGraphView: View {
    struct Series: Identifiable {
        var id: String
        var color: Color
        /// 古い順。右詰めで描く(足りないぶんは左が空く)。
        var values: [Double]
    }

    var series: [Series]
    /// 横軸に並べる点の数(= 時間幅 ÷ サンプル間隔)。`values.count`がこれより少なければ左が空く。
    var capacity: Int
    var maxValue: Double
    /// 横の目盛り線の本数(0なら無し)。
    var gridLineCount = 3

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelContentOutlineWidth) private var outlineWidth

    private static let cornerRadius: CGFloat = 4

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            draw(in: &context, size: size)
        }
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .overlay {
            if outlineWidth > 0 {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(oppositeColor.opacity(0.35), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var oppositeColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let inset: CGFloat = 1
        let plot = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        guard plot.width > 0, plot.height > 0 else { return }

        // 目盛り線(薄く)。
        if gridLineCount > 0 {
            var grid = Path()
            for i in 1...gridLineCount {
                let y = plot.minY + plot.height * CGFloat(i) / CGFloat(gridLineCount + 1)
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
            context.stroke(grid, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
        }

        let scale = maxValue > 0 ? maxValue : 1
        let stepX = plot.width / CGFloat(max(capacity - 1, 1))

        for s in series where !s.values.isEmpty {
            let count = min(s.values.count, capacity)
            let values = s.values.suffix(count)
            // 右詰め: 最新の点がplot.maxXに来る。
            let startX = plot.maxX - stepX * CGFloat(count - 1)
            var line = Path()
            var area = Path()
            for (i, value) in values.enumerated() {
                let x = startX + stepX * CGFloat(i)
                let clamped = min(max(value / scale, 0), 1)
                let y = plot.maxY - plot.height * CGFloat(clamped)
                let point = CGPoint(x: x, y: y)
                if i == 0 {
                    line.move(to: point)
                    area.move(to: CGPoint(x: x, y: plot.maxY))
                    area.addLine(to: point)
                } else {
                    line.addLine(to: point)
                    area.addLine(to: point)
                }
            }
            area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
            area.closeSubpath()

            context.fill(area, with: .color(s.color.opacity(0.18)))
            if outlineWidth > 0 {
                context.stroke(
                    line, with: .color(oppositeColor),
                    style: StrokeStyle(lineWidth: 1.5 + outlineWidth * 2, lineCap: .round, lineJoin: .round)
                )
            }
            context.stroke(
                line, with: .color(s.color),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
    }
}

/// グラフの縦軸の上限を、データから切りの良い値へ丸める。
enum ResourceGraphScale {
    /// `value`以上で最も近い「1・2・5 × 10^n」。0なら`fallback`。
    static func niceCeiling(_ value: Double, fallback: Double) -> Double {
        guard value > 0 else { return fallback }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        for multiplier in [1.0, 2.0, 5.0, 10.0] where base * multiplier >= value {
            return base * multiplier
        }
        return base * 10
    }
}

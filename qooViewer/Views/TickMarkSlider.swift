import AppKit
import SwiftUI

/// 目盛り付きのスライダー。
///
/// ■ なぜSwiftUIの`Slider`をそのまま使わないのか
/// SwiftUIの`Slider`は`step:`を渡すと**刻みの数だけ目盛りを描く**。刻みが細かい設定では
/// 目盛りが潰れて1本の直線に見えるだけになり、目盛りとして読めない
/// (ユーザー報告: カラーパレットのRGB調整。0〜255を1刻みで動かすため目盛りが256本あった。
/// 同じ指摘は以前スライドショーの間隔でも受けている ―― 0.5〜30秒を0.1秒刻みで296本)。
/// SwiftUI側には「値の刻みは細かいまま、目盛りだけ間引く」手段が無い ―― 本数は刻みから
/// 自動で決まってしまう。
///
/// ■ なぜ`NSSlider`の`numberOfTickMarks`でもないのか
/// AppKitなら本数を刻みと別に指定できるが、**目盛りは両端を含めて等分**にしか置けない。
/// 間隔は`範囲の幅 ÷ 区間数`に限られるので、幅が丸くない範囲では目盛りの載る値も間隔も
/// 半端な数になる(RGBの0〜255なら15か17か51刻み、スライドショーの0.5〜30秒なら1.475秒刻み。
/// 「数字として半端で目盛りらしくない」という指摘を受けた)。
///
/// そこで**目盛りだけ自前で描く**(`numberOfTickMarks`は0のまま)。目盛りは
/// 5, 10, 20, 50 … といった丸い値の上にだけ置き、範囲の端に目盛りが来なくてもよいことにする
/// (両端の数値は`SettingsSlider`が左右に文字で出しているので、端に目盛りは要らない)。
/// 物差しと同じ考え方で、これなら「20ごと」「0.5ごと」と読める。
///
/// ■ 値の刻み
/// 目盛りの位置に値を限る(`allowsTickMarkValuesOnly`)のではなく、`step`で自前に丸める。
/// 目盛りは「いまどのあたりにいるか」を読むための物差しであって、止まれる場所の一覧ではない
/// ―― 目盛りを間引いた分だけ値が粗くなるのでは本末転倒になる。
struct TickMarkSlider: NSViewRepresentable {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let tickValues: [Double]
    private let trackFillColor: NSColor?

    /// - Parameters:
    ///   - step: ドラッグで止まれる値の刻み。0以下なら連続(丸めない)。
    ///   - tickValues: 目盛りを置く値。省略すると`tickValues(in:step:)`が決める。
    ///   - trackFillColor: つまみより左側の塗り色。省略するとシステム既定(アクセントカラー)。
    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        tickValues: [Double]? = nil,
        trackFillColor: NSColor? = nil
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.tickValues = tickValues ?? Self.tickValues(in: range, step: step)
        self.trackFillColor = trackFillColor
    }

    func makeNSView(context: Context) -> TickMarkSliderView {
        let slider = TickMarkSliderView()
        slider.isContinuous = true
        // 目盛りはTickMarkSliderView自身が描く(上の「なぜnumberOfTickMarksでもないのか」参照)。
        slider.numberOfTickMarks = 0
        // 横方向はSwiftUIに与えられた幅いっぱいまで伸び縮みさせる。
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.target = slider
        slider.action = #selector(TickMarkSliderView.sliderValueChanged(_:))
        return slider
    }

    func updateNSView(_ slider: TickMarkSliderView, context: Context) {
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.trackFillColor = trackFillColor
        slider.tickValues = tickValues
        slider.quantize = { [range, step] raw in
            Self.quantized(raw, in: range, step: step)
        }

        let binding = _value
        slider.onChange = { newValue in
            // 同じ値を書き戻してSwiftUIの更新を誘発しない。
            if binding.wrappedValue != newValue {
                binding.wrappedValue = newValue
            }
        }

        // ドラッグ中の書き戻しでつまみが震えないよう、ずれているときだけ入れ直す。
        if abs(slider.doubleValue - value) > 1e-9 {
            slider.doubleValue = value
        }
    }

    /// 閉包を切る(WindowMouseExitAccessor.dismantleNSViewのコメント参照 ――
    /// SwiftUIが渡した閉包はAppKit側のオブジェクトに保持され、ウインドウより長く生きうる)。
    static func dismantleNSView(_ nsView: TickMarkSliderView, coordinator: ()) {
        nsView.onChange = nil
        nsView.quantize = nil
        nsView.target = nil
        nsView.action = nil
    }

    /// 高さはAppKitに決めさせ(目盛りは`NSSlider`本来の高さの中に収まるので増えない)、
    /// 幅は与えられた分だけ使う。提案された幅が無いとき・無限のとき(レイアウトの測り直しで来る)
    /// だけ`NSSlider`自身の幅へ落とす ―― そのまま無限を返すと行が壊れる。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TickMarkSliderView, context: Context) -> CGSize? {
        let fitting = nsView.fittingSize
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else {
            width = fitting.width
        }
        return CGSize(width: width, height: fitting.height)
    }

    // MARK: - 目盛りを置く値

    /// 目盛りを置く値を決める。
    ///
    /// 間隔は「1・2・5の10の冪倍」(物差しや目盛り軸で使われる丸い数)のうち、
    /// **刻みの整数倍**であり、かつ本数が`maximum`以下になる最小のものを選ぶ。
    /// 目盛りは`lowerBound`からではなく**その間隔の倍数の上**に置くので、
    /// 0.5〜30秒なら2秒ごと(2, 4, … 30)、0〜255なら20ごと(0, 20, … 240)になる。
    ///
    /// 刻み自体が丸い数と噛み合わないとき(32MB刻みなど)は、刻みの2の冪倍へ落とす。
    ///
    /// - Parameter maximum: 目盛りの本数の上限。環境設定のスライダーの実効幅はおよそ300ptなので、
    ///   21本でも15pt間隔になり、まだ1本1本を見分けられる。
    static func tickValues(in range: ClosedRange<Double>, step: Double, maximum: Int = 21) -> [Double] {
        let span = range.upperBound - range.lowerBound
        // 範囲・刻みが有限であること(無限・非数で下の Int への変換がトラップし、ループが終わらない。2026-09-23 の 3 回目の
        // 監査の低 ―― 今の呼び出しはどれも定数の小さな範囲なので起きないが、防いでおく)。
        guard range.lowerBound.isFinite, range.upperBound.isFinite, span.isFinite, span > 0, maximum >= 2 else { return [] }
        let step = step > 0 && step.isFinite ? step : span / 1000

        guard let spacing = tickSpacing(span: span, step: step, maximum: maximum) else { return [] }

        // 端の値が浮動小数の誤差で1本落ちないよう、刻みの1/1000だけ余裕を見る。
        let slack = step / 1000
        var values: [Double] = []
        var index = (range.lowerBound / spacing).rounded(.up)
        // 本数は多くても maximum(+ 端の余裕)。index が大きすぎて 1 を足しても変わらない値でも回り続けないよう、回数で止める。
        for _ in 0..<(maximum + 2) {
            let value = index * spacing
            // 1 を足しても値が進まない(桁が足りない)なら、同じ値を並べずに止める。
            if value > range.upperBound + slack || values.last.map({ value <= $0 }) == true { break }
            if value >= range.lowerBound - slack {
                values.append(min(max(value, range.lowerBound), range.upperBound))
            }
            index += 1
        }
        return values.count >= 2 ? values : []
    }

    /// 目盛りの間隔。丸い数の候補を細かい方から見て、本数が収まる最初のものを採る。
    private static func tickSpacing(span: Double, step: Double, maximum: Int) -> Double? {
        func fits(_ spacing: Double) -> Bool {
            // Int へ変える前に大きさを見る(巨大な範囲で Int の変換がトラップしないように)。
            let intervals = (span / spacing).rounded(.down)
            guard intervals.isFinite, intervals + 1 <= Double(maximum) else { return false }
            return Int(intervals) + 1 >= 2
        }

        // 1・2・5の10の冪倍。2.5系(0.25や25)は入れない ―― 間隔は「きりのいい数字」である
        // ことが目盛りらしさそのものなので、候補を丸い数だけに絞る(ユーザーの指摘)。
        // 刻みの整数倍でないものも、目盛りが止まれない値の上に載ってしまうので捨てる
        // (例: 32MB刻みに100MBの目盛り)。範囲の幅より広い間隔も、目盛りが1本も
        // (または1本しか)引けないので捨てる。
        var candidates: [Double] = []
        for exponent in -6...9 {
            let decade = pow(10.0, Double(exponent))
            for multiplier in [1.0, 2.0, 5.0] {
                let spacing = multiplier * decade
                guard spacing >= step - step / 1000, spacing <= span else { continue }
                let quotient = spacing / step
                guard abs(quotient - quotient.rounded()) < 1e-6 else { continue }
                candidates.append(spacing)
            }
        }
        // 丸い数が刻みと噛み合わない設定(32MB刻みなど)のための逃げ道。
        if !candidates.contains(where: fits) {
            candidates += (0...12)
                .map { step * pow(2.0, Double($0)) }
                .filter { $0 <= span }
        }

        return candidates.sorted().first(where: fits)
    }

    private static func quantized(_ raw: Double, in range: ClosedRange<Double>, step: Double) -> Double {
        guard step > 0 else {
            return min(max(raw, range.lowerBound), range.upperBound)
        }
        let snapped = (((raw - range.lowerBound) / step).rounded() * step) + range.lowerBound
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

/// `TickMarkSlider`が実際に置く`NSSlider`。自分自身をtargetにして値の変化を受ける
/// (`NSControl.target`は弱参照なので循環参照にはならない)。目盛りも自分で描く。
final class TickMarkSliderView: NSSlider {
    var onChange: ((Double) -> Void)?
    var quantize: ((Double) -> Double)?
    var tickValues: [Double] = [] {
        didSet {
            if tickValues != oldValue { needsDisplay = true }
        }
    }

    @objc func sliderValueChanged(_ sender: NSSlider) {
        let snapped = quantize?(sender.doubleValue) ?? sender.doubleValue
        // 丸めた結果へつまみを寄せる。ここで入れ直さないと、丸めた値が直前と同じだったとき
        // (SwiftUI側に変化が伝わらないとき)つまみだけが刻みの間に取り残される。
        if sender.doubleValue != snapped {
            sender.doubleValue = snapped
        }
        onChange?(snapped)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawTickMarks()
    }

    /// 目盛りを描く。位置と見た目は`NSSlider`自身の目盛り(`numberOfTickMarks`)を実測して
    /// 合わせてある ―― 本数だけが違う同じ物に見えるようにするため。
    ///
    /// 実測値(macOS 27、太さ`.regular`、幅300ptのスライダー):
    /// - つまみの中心は`barRect.minX + つまみの幅/2`から`barRect.maxX - つまみの幅/2`まで動く
    /// - 目盛りはその範囲を等分した位置に、直径2ptの丸で描かれる
    /// - 縦はバーの下端から3pt下(スライダー本来の高さ16ptの、下2pt)
    private func drawTickMarks() {
        guard tickValues.count >= 2,
              let cell = cell as? NSSliderCell,
              maxValue > minValue
        else { return }

        let bar = cell.barRect(flipped: isFlipped)
        let knobWidth = cell.knobThickness
        let travel = bar.width - knobWidth
        guard travel > 0 else { return }

        let diameter: CGFloat = 2
        let gap: CGFloat = 3
        let y = isFlipped ? bar.maxY + gap : bar.minY - gap - diameter

        // つまみの下に潜る目盛りは描かない(AppKitの目盛りもつまみに隠れる)。
        let knobCenter = bar.minX + knobWidth / 2
            + CGFloat((doubleValue - minValue) / (maxValue - minValue)) * travel

        NSColor.tertiaryLabelColor.setFill()
        for value in tickValues {
            let fraction = CGFloat((value - minValue) / (maxValue - minValue))
            let x = bar.minX + knobWidth / 2 + fraction * travel
            guard abs(x - knobCenter) > knobWidth / 2 else { continue }
            NSBezierPath(ovalIn: NSRect(x: x - diameter / 2, y: y, width: diameter, height: diameter)).fill()
        }
    }
}

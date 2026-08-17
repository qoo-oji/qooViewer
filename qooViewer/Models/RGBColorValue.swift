import SwiftUI

/// ユーザーが自由に指定できる色を、sRGBのR/G/B各8bit(0〜255)で表す値。
///
/// SwiftUIの`Color`やAppKitの`NSColor`をそのままUserDefaultsへ保存しようとすると
/// NSKeyedArchiverによるアーカイブが必要になり、保存された中身が人間には読めなくなるうえ、
/// 色空間の解釈もOS任せになる。ここでは「#RRGGBB」の文字列1本で保存し、復元時は
/// `Color(.sRGB, ...)`と明示的にsRGBで組み立てることで、保存形式が読めて、かつ
/// 保存→復元で色がずれないようにしている。
struct RGBColorValue: Equatable, Hashable {
    /// 0〜255の範囲に丸められる(範囲外の値を代入しても安全)。
    /// didSet内での再代入はdidSetを再帰的に呼ばないため、無限ループにはならない。
    var red: Int { didSet { red = Self.clamped(red) } }
    var green: Int { didSet { green = Self.clamped(green) } }
    var blue: Int { didSet { blue = Self.clamped(blue) } }

    init(red: Int, green: Int, blue: Int) {
        self.red = Self.clamped(red)
        self.green = Self.clamped(green)
        self.blue = Self.clamped(blue)
    }

    private static func clamped(_ value: Int) -> Int { min(255, max(0, value)) }

    /// SwiftUIで実際に描画に使う色。色空間を明示しないと、同じ数値でも表示環境によって
    /// 見え方が変わりうるため、必ずsRGBとして解釈させる。
    var color: Color {
        Color(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }

    /// UserDefaultsへの保存形式であり、ダイアログ上の表示にもそのまま使う。
    var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// `hexString`の逆。先頭の`#`は省略可。6桁の16進数として解釈できない場合はnil
    /// (保存値が壊れていた場合に既定色へフォールバックさせるため、失敗可能イニシャライザにしてある)。
    init?(hexString: String) {
        var digits = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Int((value >> 16) & 0xFF),
            green: Int((value >> 8) & 0xFF),
            blue: Int(value & 0xFF)
        )
    }

    /// HSB(色相・彩度・明度)からsRGBの値を組み立てる。カラーパレットの各マスを
    /// ベタ書きの定数表ではなく式から生成するために使う。
    ///
    /// `NSColor(hue:saturation:brightness:alpha:)`を使わないのは、あれがcalibrated RGB空間で
    /// 色を作るため、sRGBへ変換した時点で指定した色相からわずかにずれてしまい、
    /// 「パレットの見た目」と「下のRGB数値」が微妙に食い違って見えるため。自前で計算すれば
    /// パレットの色はそのままsRGBの値になり、両者が必ず一致する。
    ///
    /// - Parameters:
    ///   - hue: 色相(0〜1で一周。範囲外は一周させて正規化する)
    ///   - saturation: 彩度(0〜1)
    ///   - brightness: 明度(0〜1)
    static func fromHSB(hue: Double, saturation: Double, brightness: Double) -> RGBColorValue {
        let normalizedHue = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        let sector = normalizedHue * 6
        let saturation = min(1, max(0, saturation))
        let brightness = min(1, max(0, brightness))

        let sectorIndex = Int(sector.rounded(.down)) % 6
        let fraction = sector - sector.rounded(.down)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))

        let components: (Double, Double, Double)
        switch sectorIndex {
        case 0: components = (brightness, t, p)
        case 1: components = (q, brightness, p)
        case 2: components = (p, brightness, t)
        case 3: components = (p, q, brightness)
        case 4: components = (t, p, brightness)
        default: components = (brightness, p, q)
        }

        return RGBColorValue(
            red: Int((components.0 * 255).rounded()),
            green: Int((components.1 * 255).rounded()),
            blue: Int((components.2 * 255).rounded())
        )
    }

    /// 明るい色かどうか。この色を下地にして上に重ねる要素(パレットで選択中を示すチェックマークなど)を
    /// 白と黒のどちらで描くかを決めるのに使う。係数はNTSCの輝度式で、単純な平均より
    /// 人間の明るさの感じ方に近い(緑を明るく、青を暗く感じる)。
    var isLight: Bool {
        let luminance = (0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)) / 255
        return luminance > 0.6
    }
}

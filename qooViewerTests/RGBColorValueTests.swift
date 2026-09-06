import Foundation
import Testing

@testable import qooViewer

/// ユーザーが選んだ色の保存形式(Models/RGBColorValue.swift)。
///
/// `hexString` は **UserDefaults に入る文字列そのもの**(すりガラスの面の色・文字色・影の色)なので、
/// 書式が変わると既存の設定が読めなくなる。`init?(hexString:)` が壊れた値に対して nil を返すことも
/// 同じ理由で固定しておく ―― 呼び出し側はそこで既定色へ落ちる。
@MainActor
struct RGBColorValueTests {
    @Test("保存形式は必ず # + 大文字 6 桁")
    func theHexStringIsUppercaseAndZeroPadded() {
        #expect(RGBColorValue(red: 0, green: 0, blue: 0).hexString == "#000000")
        #expect(RGBColorValue(red: 255, green: 255, blue: 255).hexString == "#FFFFFF")
        #expect(RGBColorValue(red: 1, green: 2, blue: 3).hexString == "#010203")
        #expect(RGBColorValue(red: 171, green: 205, blue: 239).hexString == "#ABCDEF")
    }

    @Test("保存 → 読み直しで同じ色に戻る")
    func theHexStringRoundTrips() {
        for value in stride(from: 0, through: 255, by: 17) {
            let color = RGBColorValue(red: value, green: 255 - value, blue: (value * 3) % 256)
            #expect(RGBColorValue(hexString: color.hexString) == color)
        }
    }

    @Test("先頭の # は省略でき、前後の空白は無視する")
    func theLeadingHashAndSurroundingSpaceAreOptional() {
        let expected = RGBColorValue(red: 0x12, green: 0x34, blue: 0x56)
        #expect(RGBColorValue(hexString: "#123456") == expected)
        #expect(RGBColorValue(hexString: "123456") == expected)
        #expect(RGBColorValue(hexString: "  #123456  ") == expected)
        #expect(RGBColorValue(hexString: "\n123456\n") == expected)
        // 16 進数の大小文字は問わない(書くのは大文字だが、手で書き換えた値も読めるように)。
        #expect(RGBColorValue(hexString: "#abcdef") == RGBColorValue(hexString: "#ABCDEF"))
    }

    @Test("6 桁の 16 進数として読めない値は nil(呼び出し側が既定色へ落ちる)",
          arguments: ["", "#", "12345", "1234567", "#12345", "GGGGGG", "#12 34 56", "#-12345", "red",
                      "#FFF", "0x123456"])
    func aBrokenStoredValueIsRejected(text: String) {
        #expect(RGBColorValue(hexString: text) == nil)
    }

    @Test("範囲外の成分は 0〜255 に丸める(初期化でも代入でも)")
    func componentsAreClamped() {
        let clamped = RGBColorValue(red: -1, green: 300, blue: 255)
        #expect(clamped == RGBColorValue(red: 0, green: 255, blue: 255))

        var mutated = RGBColorValue(red: 10, green: 10, blue: 10)
        mutated.red = 999
        mutated.green = -999
        mutated.blue = 128
        #expect(mutated == RGBColorValue(red: 255, green: 0, blue: 128))
    }

    @Test("HSB からは sRGB の値がそのまま出る(パレットの見た目と下の数値が一致する)")
    func hsbProducesExactSRGBValues() {
        #expect(RGBColorValue.fromHSB(hue: 0, saturation: 1, brightness: 1)
                == RGBColorValue(red: 255, green: 0, blue: 0))
        #expect(RGBColorValue.fromHSB(hue: 1.0 / 3, saturation: 1, brightness: 1)
                == RGBColorValue(red: 0, green: 255, blue: 0))
        #expect(RGBColorValue.fromHSB(hue: 2.0 / 3, saturation: 1, brightness: 1)
                == RGBColorValue(red: 0, green: 0, blue: 255))
        // 彩度 0 は無彩色。明度がそのまま 3 成分になる。
        #expect(RGBColorValue.fromHSB(hue: 0.42, saturation: 0, brightness: 0.5)
                == RGBColorValue(red: 128, green: 128, blue: 128))
        #expect(RGBColorValue.fromHSB(hue: 0.42, saturation: 0, brightness: 0)
                == RGBColorValue(red: 0, green: 0, blue: 0))
    }

    @Test("色相は一周させて正規化する(0 と 1、-1/6 と 5/6 が同じ色)")
    func theHueWrapsAround() {
        #expect(RGBColorValue.fromHSB(hue: 1, saturation: 1, brightness: 1)
                == RGBColorValue.fromHSB(hue: 0, saturation: 1, brightness: 1))
        #expect(RGBColorValue.fromHSB(hue: -1.0 / 6, saturation: 1, brightness: 1)
                == RGBColorValue.fromHSB(hue: 5.0 / 6, saturation: 1, brightness: 1))
        #expect(RGBColorValue.fromHSB(hue: 2.25, saturation: 1, brightness: 1)
                == RGBColorValue.fromHSB(hue: 0.25, saturation: 1, brightness: 1))
    }

    @Test("彩度・明度も 0〜1 に丸める")
    func saturationAndBrightnessAreClamped() {
        #expect(RGBColorValue.fromHSB(hue: 0, saturation: 5, brightness: 5)
                == RGBColorValue.fromHSB(hue: 0, saturation: 1, brightness: 1))
        #expect(RGBColorValue.fromHSB(hue: 0, saturation: -5, brightness: -5)
                == RGBColorValue(red: 0, green: 0, blue: 0))
    }

    @Test("明るさの判定は NTSC の輝度式(単純な平均ではない)")
    func lightnessUsesTheNTSCLuminance() {
        #expect(RGBColorValue(red: 255, green: 255, blue: 255).isLight)
        #expect(!RGBColorValue(red: 0, green: 0, blue: 0).isLight)
        // 緑は明るく、青は暗く感じる。平均なら緑(85)も青(85)も同じ扱いになってしまう。
        #expect(RGBColorValue(red: 0, green: 255, blue: 255).isLight)   // 0.701
        #expect(!RGBColorValue(red: 0, green: 255, blue: 0).isLight)    // 0.587 ―― 境目の 0.6 より下
        #expect(!RGBColorValue(red: 255, green: 0, blue: 0).isLight)    // 0.299
        #expect(!RGBColorValue(red: 0, green: 0, blue: 255).isLight)    // 0.114
    }
}

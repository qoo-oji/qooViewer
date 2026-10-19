import Foundation
import Testing

@testable import qooViewer

/// トーストを出しておく時間(ToastDuration)。気づくまでの 1 秒 + 漢字・かな 1 字 1/6 秒 + 英数字 1 字 1/15 秒、2.5〜10 秒。
struct ToastDurationTests {
    @Test("漢字・かなは 1 秒 6 字、英数字は 1 秒 15 字で数え、気づくまでの 1 秒を足す(空白は数えない)")
    func countsByCharacterWidth() {
        // 30 字の日本語: 1 + 30/6 = 6 秒。
        #expect(ToastDuration.duration(for: String(repeating: "あ", count: 30)) == .seconds(6))
        // 60 字の英字と空白: 1 + 60/15 = 5 秒。
        #expect(ToastDuration.duration(for: String(repeating: "ab ", count: 30)) == .seconds(5))
        // 混ざった文: StackNest(9 字)で 0.6 秒 + かな 12 字で 2 秒 + 1 秒。
        #expect(ToastDuration.duration(for: "StackNest のほんにはなにもないです") == .milliseconds(3600))
    }

    @Test("短い文でも 2.5 秒、長い文でも 10 秒で止める")
    func clamps() {
        #expect(ToastDuration.duration(for: "") == ToastDuration.minimum)
        #expect(ToastDuration.duration(for: "済") == ToastDuration.minimum)
        #expect(ToastDuration.duration(for: String(repeating: "長", count: 200)) == ToastDuration.maximum)
    }

    @Test("シークレットフォルダ・StackNest の本の知らせは、どちらの言語でも上限の手前で読み切れる長さ")
    func noRecordNoticesFit() {
        for key in ["Books in secret folders leave no history or saved data.", "Books from StackNest leave no history or saved data."] {
            for language in ["en", "ja"] {
                let message = String(localized: String.LocalizationValue(key), language: Locale(identifier: language))
                #expect(ToastDuration.duration(for: message) < ToastDuration.maximum, "\(language): \(message)")
            }
        }
    }
}

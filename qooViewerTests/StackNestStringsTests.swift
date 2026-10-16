import Foundation
import Testing

@testable import qooViewer

/// qooViewer に残る StackNest の文言(原文は英語、日本語の訳がカタログにあること)。参照ファイル・通信・書き戻しの知らせの
/// 文言は StackNestViewerKit の既定の英日の文言を使う(StackNestText。部品の試験が全件の英日を押さえ、qooViewer の言語と
/// アプリの名前で出すことは StackNestSessionsTests が押さえる)。
struct StackNestStringsTests {
    private let japanese = Locale(identifier: "ja")
    private let english = Locale(identifier: "en")

    @Test("StackNest の本は書き出せない、の文言に日本語の訳がある")
    func exportRefusalIsTranslated() {
        let key = String(localized: "A StackNest book can’t be exported.", language: english)
        #expect(key == "A StackNest book can’t be exported.")
        #expect(String(localized: "A StackNest book can’t be exported.", language: japanese) == "StackNest の本は書き出せません。")
    }
}

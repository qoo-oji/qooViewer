import Foundation
import Testing

@testable import qooViewer

/// ファイル名/フォルダ名からのタイトル・著者名の推測(Services/TitleAuthorFilenameParser.swift)。
///
/// EPUB 書き出しウインドウの初期値を埋めるためのもの(Apple Books 互換性のユーザー要望)。
/// 受け取るのは**拡張子を除いた**名前で、拡張子を落とすのは呼び出し側の仕事。
/// 実装の doc コメントに並んでいる 6 つのパターンを、そのままの形で固定する。
@MainActor
struct TitleAuthorFilenameParserTests {
    private func parse(_ baseName: String) -> TitleAuthorFilenameParser.Result {
        TitleAuthorFilenameParser.parse(baseName: baseName)
    }

    // MARK: - doc コメントの 6 パターン

    @Test("パターン 1: (任意) [著者名] タイトル (任意)")
    func patternOne() {
        #expect(parse("(月刊コミック) [山田太郎] 冒険の書 (単行本)")
                == .init(title: "冒険の書", author: "山田太郎"))
    }

    @Test("パターン 2: 末尾が (任意) [任意] の 2 つでも同じ")
    func patternTwo() {
        #expect(parse("(月刊コミック) [山田太郎] 冒険の書 (単行本) [DL版]")
                == .init(title: "冒険の書", author: "山田太郎"))
    }

    @Test("パターン 3: 著者名トークンの中の丸括弧は著者名の一部として残す")
    func patternThree() {
        #expect(parse("(月刊コミック) [山田太郎 (さくら工房)] 冒険の書 (単行本) [DL版]")
                == .init(title: "冒険の書", author: "山田太郎 (さくら工房)"))
    }

    @Test("パターン 4: 末尾が [任意] だけでも同じ")
    func patternFour() {
        #expect(parse("(月刊コミック) [山田太郎] 冒険の書 [DL版]")
                == .init(title: "冒険の書", author: "山田太郎"))
    }

    @Test("パターン 5: [著者名] タイトル")
    func patternFive() {
        #expect(parse("[山田太郎] 冒険の書") == .init(title: "冒険の書", author: "山田太郎"))
    }

    @Test("パターン 6: 角括弧が無ければ「タイトル - 著者名」を試す")
    func patternSix() {
        #expect(parse("冒険の書 - 山田太郎") == .init(title: "冒険の書", author: "山田太郎"))
    }

    // MARK: - 規則そのもの

    @Test("最初の角括弧が著者名。その前にあるものは捨てる")
    func theFirstBracketWinsAndAnythingBeforeItIsDropped() {
        #expect(parse("月刊コミック [山田太郎] 冒険の書") == .init(title: "冒険の書", author: "山田太郎"))
        #expect(parse("(A) (B) [山田太郎] 冒険の書") == .init(title: "冒険の書", author: "山田太郎"))
    }

    @Test("タイトルは著者名の直後から、次のトークンが現れるまで")
    func theTitleStopsAtTheNextToken() {
        #expect(parse("[山田太郎] 冒険の書 第1巻 (単行本)")
                == .init(title: "冒険の書 第1巻", author: "山田太郎"))
    }

    @Test("タイトルの前後に残る区切り記号(- _ 空白・全角空白)は落とす")
    func separatorsAroundTheTitleAreStripped() {
        #expect(parse("[山田太郎] - 冒険の書 - (単行本)") == .init(title: "冒険の書", author: "山田太郎"))
        #expect(parse("[山田太郎]___冒険の書___(単行本)") == .init(title: "冒険の書", author: "山田太郎"))
        #expect(parse("[山田太郎]　冒険の書　(単行本)") == .init(title: "冒険の書", author: "山田太郎"))
    }

    @Test("著者名トークンの前後の空白も落とす")
    func theAuthorIsTrimmed() {
        #expect(parse("[  山田太郎  ] 冒険の書") == .init(title: "冒険の書", author: "山田太郎"))
    }

    @Test("ハイフン区切りは最初の「 - 」で切る(非貪欲)")
    func theDashSplitsAtTheFirstSeparator() {
        #expect(parse("冒険の書 - 第1巻 - 山田太郎") == .init(title: "冒険の書", author: "第1巻 - 山田太郎"))
    }

    @Test("ハイフンの前後に空白が無ければ区切りとは見なさない")
    func aDashWithoutSpacesIsNotASeparator() {
        #expect(parse("冒険の書-山田太郎") == .init(title: "冒険の書-山田太郎", author: ""))
    }

    @Test("どのパターンにも当てはまらなければ全体がタイトルで著者名は空")
    func anUnrecognizedNameBecomesTheTitle() {
        #expect(parse("冒険の書") == .init(title: "冒険の書", author: ""))
        #expect(parse("comic_001") == .init(title: "comic_001", author: ""))
        #expect(parse("(単行本) 冒険の書") == .init(title: "(単行本) 冒険の書", author: ""))
    }

    @Test("角括弧の直後にタイトルが無い場合も、全体をタイトルとして返す(著者名だけ拾うことはしない)")
    func aBracketWithNoTitleFallsBackToTheWholeName() {
        // 著者名だけを拾って title を空にすると、書き出しウインドウのタイトル欄が空で始まる。
        // タイトルは必須項目なので、推測に失敗したときは名前そのものを入れておく。
        #expect(parse("[山田太郎]") == .init(title: "[山田太郎]", author: ""))
        #expect(parse("[山田太郎] [DL版]") == .init(title: "[山田太郎] [DL版]", author: ""))
    }

    @Test("空の名前は空の結果(呼び出し側で例外扱いしないで済むように)")
    func anEmptyNameYieldsEmptyResult() {
        #expect(parse("") == .init(title: "", author: ""))
        #expect(parse("   ") == .init(title: "", author: ""))
    }

    @Test("前後の空白は結果に残らない")
    func theInputIsTrimmed() {
        #expect(parse("  [山田太郎] 冒険の書  ") == .init(title: "冒険の書", author: "山田太郎"))
        #expect(parse("  冒険の書  ") == .init(title: "冒険の書", author: ""))
    }
}

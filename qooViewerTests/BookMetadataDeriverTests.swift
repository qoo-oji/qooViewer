import Foundation
import Testing

@testable import qooViewer

/// ファイル名からの書誌メタデータ推測(Services/MetadataFormatCompiler.swift・
/// Services/BookMetadataDeriver.swift)。
///
/// ルール自体はユーザーが編集ダイアログで書き換えられるが、**既定のルール表**(ユーザー要望で
/// 決まった 12 のファイル名フォーマット・7 の巻数フォーマット・3 の除外文字列)は
/// 「メタデータの編集」ウインドウを初めて開いた人が見る結果そのものなので、ここで固定する。
/// 並び順自体が意味を持つ(上から順に照合し、最初に一致したものを採る)。
struct BookMetadataDeriverTests {
    private let rules = CompiledMetadataRuleSet(
        filenameFormats: MetadataFilenameFormat.defaults,
        volumeRules: VolumeFormatRule.defaults,
        exclusionRules: MetadataExclusionRule.defaults
    )

    private func derive(_ baseName: String) -> DerivedBookMetadata {
        BookMetadataDeriver.derive(baseName: baseName, rules: rules)
    }

    // MARK: - 既定のルール表(著者・タイトル)

    @Test("既定のフォーマットで著者とタイトルを取り出す", arguments: [
        // 入力(拡張子を除いたファイル名) → 著者, タイトル
        ("[作者] タイトル", "作者", "タイトル"),
        ("[作者]タイトル", "作者", "タイトル"), // 空白は 0 文字でもよい
        ("[作者]    タイトル", "作者", "タイトル"),
        ("[作者 (サークル)] タイトル", "作者", "タイトル"),
        ("[作者 (サークル)] タイトル (雑誌)", "作者", "タイトル"),
        ("[作者 (サークル)] タイトル (雑誌) [タグ]", "作者", "タイトル"),
        ("[作者] タイトル (雑誌)", "作者", "タイトル"),
        ("[作者] タイトル (雑誌) [タグ]", "作者", "タイトル"),
        ("(同人誌) [作者] タイトル", "作者", "タイトル"),
        ("(同人誌) [作者 (サークル)] タイトル (雑誌) [タグ]", "作者", "タイトル"),
    ])
    func defaultFilenameFormats(baseName: String, author: String, title: String) {
        let derived = derive(baseName)
        #expect(derived.author == author)
        #expect(derived.title == title)
    }

    @Test("どのフォーマットにも当てはまらなければ、著者は空欄・全体がタイトル")
    func theFallbackKeepsEverythingAsTheTitle() {
        #expect(derive("ただのファイル名") == DerivedBookMetadata(title: "ただのファイル名"))
        #expect(derive("作者 - タイトル") == DerivedBookMetadata(title: "作者 - タイトル"))
    }

    @Test("タイトルが空になる一致は採らず、次のフォーマットへ進む")
    func anEmptyTitleIsNotAMatch() {
        // `@title` は `(.+?)`(1文字以上)なので、そもそも空一致はしない。ここで見たいのは
        // 「著者だけの名前」が最後のフォールバックへ落ちること。
        #expect(derive("[作者]") == DerivedBookMetadata(title: "[作者]"))
    }

    // MARK: - 既定のルール表(除外文字列)

    @Test("既定の除外文字列(年号・完結を示す括弧書き)を削る", arguments: [
        ("(2023) [作者] タイトル", "タイトル"),
        ("(1999) [作者] タイトル", "タイトル"),
        ("[作者] タイトル (完)", "タイトル"),
        ("[作者] タイトル (完結)", "タイトル"),
        ("[作者] タイトル (完全版)", "タイトル"),
        ("[作者] タイトル (終)", "タイトル"),
        ("[作者] タイトル (結)", "タイトル"),
    ])
    func defaultExclusionRules(baseName: String, title: String) {
        #expect(derive(baseName).title == title)
        #expect(derive(baseName).author == "作者")
    }

    @Test("2100 年以降は年号として扱わない(既定ルールの範囲外)")
    func yearsOutsideTheRangeAreKept() {
        #expect(derive("[作者] タイトル (2100)").title == "タイトル")
        // (2100) は削られないので `@ignore` として吸われる。削られたのではないことを確かめる。
        #expect(BookMetadataDeriver.removingExclusions(from: "(2100)", rules: rules) == "(2100)")
        #expect(BookMetadataDeriver.removingExclusions(from: "(2099)", rules: rules) == "")
    }

    @Test("削った跡に空白が残っても、フォーマットの照合は通る")
    func leftoverWhitespaceDoesNotBreakMatching() {
        // フォーマット中の空白は「0文字以上の空白」としてコンパイルされる。
        #expect(BookMetadataDeriver.removingExclusions(from: "(2023) [作者] タイトル", rules: rules)
            == " [作者] タイトル")
        #expect(derive("(2023) [作者] タイトル").author == "作者")
    }

    // MARK: - 既定のルール表(巻数・シリーズ)

    @Test("既定の巻数フォーマットでシリーズ名と巻数に分ける", arguments: [
        // タイトル → シリーズ, 巻数
        ("シリーズ 第3巻", "シリーズ", "3"),
        ("シリーズ 第３巻", "シリーズ", "3"), // 全角数字は半角へ
        ("シリーズ 3巻", "シリーズ", "3"),
        ("シリーズ 12巻", "シリーズ", "12"),
        ("シリーズ v3", "シリーズ", "3"),
        ("シリーズ_v3", "シリーズ", "3"),
        ("シリーズ-v3", "シリーズ", "3"),
        ("シリーズ vol.3", "シリーズ", "3"),
        ("シリーズ Vol 3", "シリーズ", "3"),
        ("シリーズ VOLUME3", "シリーズ", "3"),
        ("シリーズ v.3", "シリーズ", "3"),
    ])
    func defaultVolumeRules(title: String, series: String, index: String) {
        let split = BookMetadataDeriver.splitSeriesAndVolume(title: title, rules: rules)
        #expect(split.series == series)
        #expect(split.seriesIndex == index)
    }

    @Test("シリーズ名を分けるだけで、巻数欄には入れないもの", arguments: [
        ("シリーズ 上巻", "シリーズ"),
        ("シリーズ 下巻", "シリーズ"),
        ("シリーズ 前編", "シリーズ"),
        ("シリーズ 中編", "シリーズ"),
        ("シリーズ 後編", "シリーズ"),
        ("シリーズ 完結編", "シリーズ"),
        ("シリーズ 総集編", "シリーズ"),
        // 「フルカラー」ごとシリーズ名から切り離す(ユーザー要望)。
        ("シリーズ フルカラー総集編", "シリーズ"),
        ("シリーズ フルカラー総集編2", "シリーズ"),
        ("シリーズ 総集編3", "シリーズ"),
    ])
    func seriesSeparatorOnlyRules(title: String, series: String) {
        let split = BookMetadataDeriver.splitSeriesAndVolume(title: title, rules: rules)
        #expect(split.series == series)
        // キャプチャグループを持つフォーマットでも、巻数欄は空欄のまま。
        #expect(split.seriesIndex == "")
    }

    @Test("「第」がシリーズ名に残らない(具体的なルールを先に置いてある)")
    func theMoreSpecificVolumeRuleWins() {
        #expect(BookMetadataDeriver.splitSeriesAndVolume(title: "シリーズ 第3巻", rules: rules).series == "シリーズ")
    }

    @Test("末尾に一致する巻数フォーマットが無ければ、シリーズ欄は空欄")
    func aStandaloneBookHasNoSeries() {
        // 「1冊完結の本にはシリーズという概念が無い」―― タイトルがそのままシリーズ名になることは無い。
        #expect(BookMetadataDeriver.splitSeriesAndVolume(title: "タイトル", rules: rules) == ("", ""))
        // 巻数表記が末尾に無い(後ろに文字が続く)場合も一致しない。
        #expect(BookMetadataDeriver.splitSeriesAndVolume(title: "シリーズ 第3巻 おまけ", rules: rules) == ("", ""))
    }

    @Test("空のタイトルは何も返さない")
    func anEmptyTitleSplitsToNothing() {
        #expect(BookMetadataDeriver.splitSeriesAndVolume(title: "   ", rules: rules) == ("", ""))
    }

    // MARK: - 通しで

    @Test("除外 → 著者・タイトル → シリーズ・巻数 の順に効く")
    func theWholePipeline() {
        #expect(derive("(2023) [作者 (サークル)] シリーズ 第3巻 (雑誌) [タグ]") == DerivedBookMetadata(
            author: "作者", title: "シリーズ 第3巻", series: "シリーズ", seriesIndex: "3"
        ))
    }

    @Test("全角数字は巻数欄でだけ半角へ直す")
    func fullwidthDigitsAreNormalizedOnlyInTheVolumeNumber() {
        // 数字以外(カタカナ・記号)まで巻き込まないための自前実装。
        #expect(BookMetadataDeriver.normalizingFullwidthDigits("３１４") == "314")
        #expect(BookMetadataDeriver.normalizingFullwidthDigits("ＡＢＣ") == "ＡＢＣ")
        #expect(BookMetadataDeriver.normalizingFullwidthDigits("シリーズ３") == "シリーズ3")
        // タイトル側は全角のまま。
        #expect(derive("[作者] シリーズ 第３巻").title == "シリーズ 第３巻")
        #expect(derive("[作者] シリーズ 第３巻").seriesIndex == "3")
    }
}

/// ルールを正規表現へ変換する側(Services/MetadataFormatCompiler.swift)。
struct MetadataFormatCompilerTests {
    // MARK: - ファイル名フォーマット

    @Test("予約語を1つも含まないフォーマットは使わない")
    func aFormatWithoutKeywordsIsRejected() {
        #expect(MetadataFormatCompiler.compile(filenameFormat: "[作者] タイトル") == nil)
        #expect(MetadataFormatCompiler.compile(filenameFormat: "") == nil)
        #expect(!MetadataFormatCompiler.isValidFilenameFormat("ただの文字列"))
        #expect(MetadataFormatCompiler.isValidFilenameFormat("@title"))
    }

    @Test("3語のいずれでもない @ は、ただの文字として扱う")
    func anUnknownAtSignIsALiteral() throws {
        let format = try #require(MetadataFormatCompiler.compile(filenameFormat: "@name @title"))
        #expect(format.authorGroupIndex == nil)
        #expect(format.titleGroupIndex == 1)
        let rules = CompiledMetadataRuleSet(
            filenameFormats: [MetadataFilenameFormat(pattern: "@name @title")],
            volumeRules: [], exclusionRules: []
        )
        #expect(BookMetadataDeriver.derive(baseName: "@name タイトル", rules: rules)
            == DerivedBookMetadata(title: "タイトル"))
    }

    @Test("予約語を2回書いても、コンパイルは失敗せず1つ目を採る")
    func aRepeatedKeywordUsesTheFirstGroup() throws {
        // 名前付きキャプチャを使わないのはこのため(同じ名前の重複でコンパイルごと失敗する)。
        let format = try #require(MetadataFormatCompiler.compile(filenameFormat: "[@author] @title - @author"))
        #expect(format.authorGroupIndex == 1)
        #expect(format.titleGroupIndex == 2)
    }

    @Test("@title だけのフォーマットでは、著者欄は空になる")
    func aFormatWithoutAnAuthorLeavesItEmpty() {
        let rules = CompiledMetadataRuleSet(
            filenameFormats: [MetadataFilenameFormat(pattern: "[@ignore] @title")],
            volumeRules: [], exclusionRules: []
        )
        #expect(BookMetadataDeriver.derive(baseName: "[作者] タイトル", rules: rules)
            == DerivedBookMetadata(title: "タイトル"))
    }

    @Test("リテラルは正規表現としてエスケープされる")
    func literalsAreEscaped() {
        let rules = CompiledMetadataRuleSet(
            filenameFormats: [MetadataFilenameFormat(pattern: "@title (+)")],
            volumeRules: [], exclusionRules: []
        )
        // "(+)" が正規表現として解釈されていたらコンパイルに失敗するか、別の入力に一致する。
        #expect(BookMetadataDeriver.derive(baseName: "タイトル (+)", rules: rules).title == "タイトル")
        #expect(BookMetadataDeriver.derive(baseName: "タイトル (x)", rules: rules).title == "タイトル (x)")
    }

    @Test("フォーマット全体がファイル名全体と一致すること(部分一致では採らない)")
    func matchingIsAnchoredToTheWholeName() {
        let rules = CompiledMetadataRuleSet(
            filenameFormats: [MetadataFilenameFormat(pattern: "[@author] @title")],
            volumeRules: [], exclusionRules: []
        )
        // 先頭に余計な文字があると `[@author]` の `[` に届かない。
        #expect(BookMetadataDeriver.derive(baseName: "序 [作者] タイトル", rules: rules).author == "")
    }

    // MARK: - 巻数フォーマット

    @Test("選択肢だけのパターンでも、末尾アンカーが全体にかかる")
    func alternationIsWrappedBeforeAnchoring() {
        // `(?:…)` で包まないと、`上巻|下巻` の `$` が最後の選択肢にしかかからない。
        let rules = CompiledMetadataRuleSet(
            filenameFormats: [], volumeRules: [VolumeFormatRule(pattern: "上巻|下巻", kind: .seriesSeparatorOnly)],
            exclusionRules: []
        )
        #expect(BookMetadataDeriver.splitSeriesAndVolume(title: "シリーズ 上巻", rules: rules).series == "シリーズ")
        #expect(BookMetadataDeriver.splitSeriesAndVolume(title: "シリーズ 下巻", rules: rules).series == "シリーズ")
    }

    @Test("キャプチャグループが無い巻数フォーマットは、一致部分の数字を拾う")
    func aRuleWithoutACaptureGroupFallsBackToTheDigits() {
        let rules = CompiledMetadataRuleSet(
            filenameFormats: [], volumeRules: [VolumeFormatRule(pattern: "#[0-9]+", kind: .volumeNumber)],
            exclusionRules: []
        )
        let split = BookMetadataDeriver.splitSeriesAndVolume(title: "シリーズ #12", rules: rules)
        #expect(split == ("シリーズ", "12"))
    }

    @Test("空パターンの巻数フォーマット・除外文字列は捨てる")
    func emptyPatternsAreDropped() {
        // 空の正規表現はすべての位置に一致するため、そのまま使うと文字列が消える。
        #expect(MetadataFormatCompiler.compile(volumeRule: VolumeFormatRule(pattern: "", kind: .volumeNumber)) == nil)
        #expect(MetadataFormatCompiler.compile(exclusionRule: MetadataExclusionRule(pattern: "")) == nil)
    }

    // MARK: - まとめてコンパイルする側

    @Test("壊れたルールだけを取り除き、残りは動き続ける")
    func invalidRulesAreDroppedIndividually() {
        let rules = CompiledMetadataRuleSet(
            filenameFormats: [
                MetadataFilenameFormat(pattern: "予約語なし"),
                MetadataFilenameFormat(pattern: "[@author] @title"),
            ],
            volumeRules: [
                VolumeFormatRule(pattern: "[", kind: .volumeNumber),
                VolumeFormatRule(pattern: #"第([0-9]+)巻"#, kind: .volumeNumber),
            ],
            exclusionRules: [
                MetadataExclusionRule(pattern: "("),
                MetadataExclusionRule(pattern: #"\(2023\)"#),
            ]
        )
        #expect(rules.filenameFormats.count == 1)
        #expect(rules.volumeRules.count == 1)
        #expect(rules.exclusionRules.count == 1)
        #expect(BookMetadataDeriver.derive(baseName: "(2023) [作者] シリーズ 第3巻", rules: rules)
            == DerivedBookMetadata(author: "作者", title: "シリーズ 第3巻", series: "シリーズ", seriesIndex: "3"))
    }

    @Test("ルールが1件も無ければ、全体がタイトルになるだけ")
    func anEmptyRuleSetIsHarmless() {
        let rules = CompiledMetadataRuleSet(filenameFormats: [], volumeRules: [], exclusionRules: [])
        #expect(BookMetadataDeriver.derive(baseName: "[作者] タイトル", rules: rules)
            == DerivedBookMetadata(title: "[作者] タイトル"))
    }

    // MARK: - 編集ダイアログの妥当性チェック

    @Test("正規表現の妥当性(空は「書きかけ」として無効)")
    func regularExpressionValidation() {
        #expect(!MetadataFormatCompiler.isValidRegularExpression(""))
        #expect(!MetadataFormatCompiler.isValidRegularExpression("["))
        #expect(!MetadataFormatCompiler.isValidRegularExpression("(?<"))
        #expect(MetadataFormatCompiler.isValidRegularExpression(#"第([0-9]+)巻"#))
    }
}

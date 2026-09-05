import Foundation
import Testing

@testable import qooViewer

/// アプリ内表示言語(Models/AppLanguage.swift)。
///
/// この設定は **OS のロケールとは独立** していて、Foundation の `String(localized:locale:)` では
/// 切り替わらない ―― あの `locale:` は埋め込む数値などの書式にしか効かず、翻訳そのものは常に
/// `Bundle.main`(= OS の言語)から引かれる。アプリ内の全箇所がそれで書かれていたために、
/// ウインドウのタイトル・NSAlert の文言・ViewModel が組み立てる文字列が OS の言語のまま
/// 残っていた(監査で発覚)。ここで固定するのは、`String(localized:language:)` が
/// **翻訳の選択まで**切り替えることそのもの。
///
/// OS の言語がどちらでも同じ結果になるように書く(手元は日本語、CI は英語)。
struct AppLanguageTests {
    private let japanese = Locale(identifier: "ja")
    private let english = Locale(identifier: "en")

    // MARK: - 翻訳の選択

    @Test("language: を渡すと、翻訳そのものが指定した言語で引かれる")
    func theLanguageParameterSelectsTheTranslation() {
        #expect(String(localized: "Single Page", language: japanese) == "単ページ")
        #expect(String(localized: "Single Page", language: english) == "Single Page")
        #expect(String(localized: "Spread Right", language: japanese) == "見開き右")
        #expect(String(localized: "Spread Right", language: english) == "Spread Right")
    }

    @Test("同じキーでも、言語が違えば違う文字列になる")
    func differentLanguagesGiveDifferentStrings() {
        // OS の言語に依存しない形の確認 ―― Foundation の `locale:` 版ではここが必ず一致してしまう。
        #expect(String(localized: "Follow System", language: japanese)
            != String(localized: "Follow System", language: english))
    }

    @Test("翻訳を持たない言語は Bundle.main に任せる(落ちない)")
    func anUnsupportedLanguageFallsBackToTheMainBundle() {
        #expect(Locale(identifier: "fr").displayLanguageBundle == Bundle.main)
        // 引けること自体は保証する(何語になるかは OS の言語リスト次第)。
        #expect(!String(localized: "Single Page", language: Locale(identifier: "fr")).isEmpty)
    }

    @Test("地域付きのロケールでも、言語コードで .lproj を引ける")
    func regionalLocalesResolveByLanguageCode() {
        #expect(String(localized: "Single Page", language: Locale(identifier: "ja_JP")) == "単ページ")
        #expect(String(localized: "Single Page", language: Locale(identifier: "en_US")) == "Single Page")
    }

    @Test("PageLayoutState.title(locale:) も同じ言語で引く")
    func callersUseTheSameMechanism() {
        // AppKit 側(NSMenuItem.title)のように LocalizedStringKey を渡せない場所の入口。
        #expect(PageLayoutState.single.title(locale: japanese) == "単ページ")
        #expect(PageLayoutState.single.title(locale: english) == "Single Page")
    }

    // MARK: - 設定の値

    @Test("「システムに従う」だけが上書きを持たない")
    func onlyTheSystemCaseHasNoOverride() {
        #expect(AppLanguage.system.localeOverride == nil)
        #expect(AppLanguage.japanese.localeOverride == Locale(identifier: "ja"))
        #expect(AppLanguage.english.localeOverride == Locale(identifier: "en"))
        #expect(AppLanguage.japanese.locale == Locale(identifier: "ja"))
        // 「システムに従う」は OS 側のロケールになる(値そのものは環境次第)。
        #expect(AppLanguage.system.locale == AppLanguage.systemLocale)
    }

    @Test("rawValue は UserDefaults に入る識別子なので変えられない")
    func rawValuesAreFrozen() {
        #expect(AppLanguage.allCases.map(\.rawValue) == ["system", "japanese", "english"])
        #expect(AppLanguage.defaultsKey == "qooViewer.pref.displayLanguage")
        #expect(AppLanguage(rawValue: "klingon") == nil)
    }

    // MARK: - AppleLanguages への書き込み

    @Test("言語を選ぶと AppleLanguages に書き、システムに戻すと自分が書いたぶんだけ消す")
    func appleLanguagesOverrideIsWrittenAndRemoved() throws {
        // **共有の保存先には触れない** ―― その場限りの suite を作って使い、最後に消す。
        let suiteName = "qooViewerTests.applelanguages.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        AppLanguage.applyAppleLanguagesOverride(for: .japanese, defaults: defaults)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["ja"])

        AppLanguage.applyAppleLanguagesOverride(for: .english, defaults: defaults)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])

        AppLanguage.applyAppleLanguagesOverride(for: .system, defaults: defaults)
        // `AppleLanguages` は NSGlobalDomain にもある(OS の言語リスト)ため、消した後の
        // `stringArray(forKey:)` は OS の値へ抜けて返ってくる ―― nil にはならない。
        // 「アプリの領域から消えたこと」を見るには、その領域を直接覗く。
        #expect(UserDefaults().persistentDomain(forName: suiteName)?["AppleLanguages"] == nil)
    }

    @Test("ユーザーがシステム設定で指定した AppleLanguages は消さない")
    func aUserSuppliedAppleLanguagesValueIsKept() throws {
        // 「システム設定 › 一般 › 言語と地域 › アプリケーション」で指定された値と同じキーなので、
        // 自分が書いた印(overrideMarker)が無いときは触らない。
        let suiteName = "qooViewerTests.applelanguages.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        defaults.set(["fr"], forKey: "AppleLanguages")
        AppLanguage.applyAppleLanguagesOverride(for: .system, defaults: defaults)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["fr"])
    }
}

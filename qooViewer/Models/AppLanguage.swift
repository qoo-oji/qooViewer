import SwiftUI

/// アプリの表示言語。「システムに従う」を選ぶと、macOS本体の言語設定に従う(既定)。
/// それ以外を選ぶと、macOS本体の言語設定にかかわらず常にその言語で表示する。
enum AppLanguage: String, CaseIterable, Identifiable, Codable, Hashable {
    case system
    case japanese
    case english

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .system: return "Follow System"
        case .japanese: return "Japanese"
        case .english: return "English"
        }
    }

    /// この設定が実際に対応する Locale。「システムに従う」の場合は nil を返す
    /// (呼び出し側は nil のとき Locale.autoupdatingCurrent 等、システムのロケールをそのまま使う)。
    var localeOverride: Locale? {
        switch self {
        case .system: return nil
        case .japanese: return Locale(identifier: "ja")
        case .english: return Locale(identifier: "en")
        }
    }

    /// 選んだ表示言語を、**次回の起動から**アプリ全体(メニューバー・AppKitが出すダイアログや
    /// ボタン・`String(localized:)`のすべて)にも効かせる。
    ///
    /// 起動中に切り替わるのは、SwiftUIの`.environment(\.locale, ...)`に従うウインドウの中身と、
    /// `String(localized:language:)`で組み立てている文字列だけ。メニューバー(`.commands`)の
    /// 項目名は、Sceneに`.environment(\.locale, ...)`を付けてもOSの言語のまま変わらない
    /// (SwiftUIに切り替える手段が無い)。そこで、macOSの「システム設定 › 一般 › 言語と地域 ›
    /// アプリケーション」がアプリごとの言語を指定するのと同じ仕組み ―― アプリ自身の
    /// UserDefaultsの`AppleLanguages` ―― に選んだ言語を書いておく。Foundationは起動時に
    /// これを読んでアプリの言語を決めるので、次の起動からは何もしなくても全体が揃う。
    ///
    /// 「システムに従う」へ戻したときは、**自分が書いたときだけ**消す(`overrideMarkerKey`)。
    /// ユーザーが上記のシステム設定でこのアプリの言語を指定していると同じキーに値が入っている
    /// ので、それを勝手に消してしまわないため。
    static func applyAppleLanguagesOverride(for language: AppLanguage, defaults: UserDefaults = .standard) {
        let appleLanguagesKey = "AppleLanguages"
        if let code = language.localeOverride?.language.languageCode?.identifier {
            defaults.set([code], forKey: appleLanguagesKey)
            defaults.set(true, forKey: overrideMarkerKey)
        } else if defaults.bool(forKey: overrideMarkerKey) {
            defaults.removeObject(forKey: appleLanguagesKey)
            defaults.removeObject(forKey: overrideMarkerKey)
        }
    }

    /// `AppleLanguages`を書いたのがこのアプリ自身であることの印(applyAppleLanguagesOverride参照)。
    private static let overrideMarkerKey = "qooViewer.pref.appleLanguagesOverrideApplied"
}

// MARK: - 表示言語で翻訳を引く

extension Locale {
    /// このロケールの言語の翻訳が入った `.lproj` バンドル。
    ///
    /// 翻訳を持たない言語のときは `Bundle.main` を返し、Foundation の通常の言語選択(OS の
    /// 言語リストから、このアプリが持つ言語のうち最も優先されるもの)に任せる。「システムに従う」の
    /// `Locale.autoupdatingCurrent` は、OS の第1言語がこのアプリの対応言語ならその `.lproj`、
    /// 対応外(例: フランス語)なら `Bundle.main` となり、どちらも OS の言語設定と同じ結果になる。
    nonisolated var displayLanguageBundle: Bundle {
        guard let code = language.languageCode?.identifier,
              let bundle = Self.displayLanguageBundles[code] else { return .main }
        return bundle
    }

    /// 言語コード → その言語の `.lproj` バンドル。アプリが持つローカライズ(String Catalog から
    /// ビルド時に `en.lproj`/`ja.lproj` へ書き出される)を起動後に1回だけ列挙して作る。
    private nonisolated static let displayLanguageBundles: [String: Bundle] = {
        var bundles: [String: Bundle] = [:]
        for localization in Bundle.main.localizations {
            guard let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            bundles[localization] = bundle
            // "ja-JP" のように地域付きのロケールからも引けるよう、言語コードだけでも登録する
            // (同じ言語コードの lproj が複数あるときは最初のものを採る)。
            if let code = Locale(identifier: localization).language.languageCode?.identifier,
               bundles[code] == nil {
                bundles[code] = bundle
            }
        }
        return bundles
    }()
}

extension String {
    /// 環境設定「表示言語」の言語で翻訳を引く `String(localized:)`。
    ///
    /// **Foundation の `String(localized:locale:)` の `locale:` は翻訳の選択には関わらない。**
    /// あれは埋め込む数値などの書式にだけ効き、翻訳そのものは常に `Bundle.main`、つまり OS の
    /// 言語設定で選ばれる。このアプリの表示言語は OS とは独立に選べる(AppLanguage)ため、
    /// 言語に対応する `.lproj` のバンドルを明示して引く必要がある。
    ///
    /// 以前はアプリ内の全箇所が `String(localized:locale:)` で書かれていて、環境設定で言語を
    /// 切り替えても、View の `Text`(こちらは `.environment(\.locale, ...)` に従う)以外 ――
    /// ウインドウのタイトル、NSAlert/NSOpenPanel の文言、ViewModel が組み立てる文字列 ――
    /// は OS の言語のまま残っていた(監査で発覚。数値の書式だけが切り替わることで判明)。
    /// ラベルを `locale:` ではなく `language:` にしているのは、Foundation のものと取り違えて
    /// 同じ不具合を作り直さないため。表示言語で引く文字列は必ずこちらを使うこと。
    ///
    /// - Parameter locale: `preferences.effectiveLocale` または View の `@Environment(\.locale)`。
    nonisolated init(localized keyAndValue: String.LocalizationValue, language locale: Locale) {
        self.init(localized: keyAndValue, bundle: locale.displayLanguageBundle, locale: locale)
    }
}

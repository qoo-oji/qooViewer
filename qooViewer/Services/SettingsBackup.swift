import Foundation

/// 環境設定を `UserDefaults` のまま書き出し・取り込みする窓口(2026-09-23、利用者の運用:
/// 保存データの JSON とコレクション表紙の組をバックアップとして持ち、**フォルダのアクセス権
/// 以外は JSON を読めば環境が戻る**ようにしたい)。
///
/// ■ キーは「一覧を持つ」のではなく「接頭辞で決める」
/// 設定は 200 近くあり増え続ける。書き出す対象を手で並べると、設定を足すたびにここへも
/// 足す必要があり、足し忘れが「その設定だけ戻らない」という静かな形で現れる。
/// `AppPreferences` と `AppearanceSettings`(ノーマル・シークレット・すりガラスの面ごとの設定)は
/// **すべて `qooViewer.pref.` で始まるキー**に保存しているので、接頭辞で拾えば足し忘れようがない。
/// キー割り当て(`KeyBindingStore`)だけは別の接頭辞なので、そちらは明示して足す。
///
/// ■ 入れないもの
/// - フォルダのアクセス権(`FolderAccessStore.defaultsKey` / `FolderSettingBookmarks`)と
///   最近開いた本の履歴(`RecentFilesStore`)、最後に開いていた本 ―― どれもセキュリティスコープ付き
///   ブックマークで、**書き出した端末でしか意味を持たない**(お気に入り・コレクションの本で
///   ブックマークを書き出していないのと同じ理由)
/// - スマートライブラリ・よく使う項目・自動リネーム ―― パスを含むので、読める形で別のカテゴリ
///   として書く(`ExportedSmartLibrary` / `ExportedFileBrowser`)
/// - ウインドウの位置、最後に開いていた環境設定の画面、スキーマの世代、やり直しの予約などの
///   「そのときの状態」
/// - 言語の上書きを適用済みかの印(`AppLanguage.overrideMarkerKey`)。取り込んだ端末では
///   その端末の判断でやり直す
enum SettingsBackup {
    /// `AppPreferences` と `AppearanceSettings` が使う接頭辞。
    static let preferencePrefix = "qooViewer.pref."

    /// 接頭辞では拾えない、キー割り当ての保存先(`KeyBindingStore`)。
    static let keyBindingKeys = [
        "qooViewer.keyBindings.v1",
        "qooViewer.mouseTriggerBindings.v1",
        "qooViewer.modeKeyBindings.v1",
        "qooViewer.modeMouseTriggerBindings.v1",
        "qooViewer.modeWheelBehaviors.v1",
        "qooViewer.modeScrollSteps.v1"
    ]

    /// 接頭辞には合うが、設定ではないので入れないキー。
    static let excludedKeys: Set<String> = [
        // 「表示言語を AppleLanguages へ書き戻した」という印(AppLanguage.applyAppleLanguagesOverride)。
        "qooViewer.pref.appleLanguagesOverrideApplied",
        // 廃止した設定(PageOrder.retiredSettingKey)。読み替えは済んでいる。
        "qooViewer.pref.usesFinderSortOrder"
    ]

    static func isBackupKey(_ key: String) -> Bool {
        if excludedKeys.contains(key) { return false }
        return key.hasPrefix(preferencePrefix) || keyBindingKeys.contains(key)
    }

    /// いまの環境設定を書き出す。値を持たないキー(= 出荷時の既定のまま)は書かない ――
    /// 取り込み側が「書いてあるキーだけ上書き」なので、書かなければ相手の既定のままになる。
    static func export(from defaults: UserDefaults) -> ExportedSettings {
        var values: [String: ExportedDefaultsValue] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where isBackupKey(key) {
            // 表せない型は飛ばす(ExportedDefaultsValue のコメント)。
            guard let exported = ExportedDefaultsValue(defaultsValue: value) else { continue }
            values[key] = exported
        }
        return ExportedSettings(values: values)
    }

    /// 取り込む。**書いてあるキーだけ上書きし、無いキーは手元の値のまま**(利用者の指示)。
    /// 書き出したファイルに無い設定まで既定へ戻すと、新しい設定が増えたあとに古いバックアップを
    /// 読んだだけでその設定が消えることになる。
    ///
    /// 念のため取り込み側でも `isBackupKey` で濾す ―― 手で書き替えた JSON が、アクセス権や
    /// ウインドウの状態のキーを紛れ込ませても書かない。
    static func apply(_ settings: ExportedSettings, to defaults: UserDefaults) -> Int {
        var applied = 0
        for (key, value) in settings.values where isBackupKey(key) {
            defaults.set(value.defaultsValue, forKey: key)
            applied += 1
        }
        return applied
    }
}

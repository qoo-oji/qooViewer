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
        "qooViewer.pref.usesFinderSortOrder",
        // 廃止した「初回起動時に決めた読み方向」(AppPreferences.Keys.retiredDefaultReadingDirection)。
        "qooViewer.pref.defaultReadingDirection"
    ]

    /// 接頭辞には合うが、セキュリティスコープ付きブックマーク(とそのパス・パネルの位置の控え)なので入れないキーの印
    /// (`LastUsedFolderMemory`: 前回のフォルダ・固定の保存先。2026-09-23 の 3 回目の監査の低 ―― 上の「入れないもの」の決まりに
    /// 反して入っていて、別の Mac ではその場で解決できないブックマーク・パスが環境設定に出た)。
    static let excludedKeyMarker = "FolderBookmark"

    static func isBackupKey(_ key: String) -> Bool {
        if excludedKeys.contains(key) || key.contains(excludedKeyMarker) { return false }
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
    ///
    /// 値の形も確かめる(2026-09-23 の 3 回目の監査の中 3): 数でない数(JSON には書けないが念のため)と、手元に同じキーの値が
    /// あるのに種類が違う値(真偽値の設定へ文字列など)は書かない。**範囲は読む側が収める**(`AppPreferences.storedDouble`)。
    static func apply(_ settings: ExportedSettings, to defaults: UserDefaults) -> Int {
        var applied = 0
        for (key, value) in settings.values where isBackupKey(key) {
            if case let .double(number) = value, !number.isFinite { continue }
            if let object = defaults.object(forKey: key), let current = ExportedDefaultsValue(defaultsValue: object),
               !current.isSameKind(as: value) {
                continue
            }
            defaults.set(value.defaultsValue, forKey: key)
            applied += 1
        }
        return applied
    }
}

/// バックアップから取り込むパスだけのフォルダの設定(よく使う項目・スマートライブラリの対象フォルダ・自動リネームの対象)を、
/// 登録してよいか(2026-09-23 の 3 回目の監査の中 5)。
///
/// 以前は「その場所に実際にフォルダがあるときだけ」で、外付けやネットワークのボリュームを繋がずに戻すと、そこの設定が黙って
/// 落ちた(「置き換え」は先に手元の分を全部消すので、両方から消えた)。いま繋がっていないボリュームの上のパスは、確かめずに
/// 登録する(繋げばそのまま使える。権限は別途「アクセスを許可」)。繋がっているネットワークのボリュームも確かめない
/// (応答しない共有でメインが止まる)。繋がっているローカルのボリュームで、フォルダが無いものだけを落とす。
enum BackupFolderPaths {
    static func shouldImport(_ path: String, mounts: MountTable) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if mounts.isOnAnUnmountedVolume(url) || mounts.isRemote(url) { return true }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

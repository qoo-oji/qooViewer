import Foundation

/// 「エイリアスを作成」で付ける名前(2026-10-01、利用者の判断「Finder に合わせて」)。**Finder の付け方を写したもの**で、変えるときは
/// 本物の Finder と突き合わせる(一括リネームの `BulkRename` と同じ約束)。
///
/// ■ 実測(macOS 27、日本語、使い捨ての APFS ボリューム。AppleScript の `make new alias file` で Finder に作らせて名前を読んだ)
/// - 基は**Finder に見えている名前**(`localizedName`): `photo.jpg` → `photo.jpgのエイリアス`(拡張子の後ろに付く)、拡張子を隠した
///   `hidext.txt` → `hidextのエイリアス`、`Sample.app` → `Sampleのエイリアス`。見えている名前の `/` はディスクでは `:`
///   (`a:b` → `a:bのエイリアス`、Finder には `a/bのエイリアス` と見える)。
/// - 塞がっていれば ` 2`, ` 3` … を**末尾に**付ける(`photo.jpgのエイリアス 2`。拡張子の前には入れない)。2 から数えて最初に空いた番号で、
///   基の名前が空いていれば番号は付けない(`xのエイリアス 3` だけがあるなら `xのエイリアス`)。同じ名前のフォルダも、大文字小文字だけ
///   違う名前(大文字小文字を区別しないボリューム)も塞がっているものとして数える。
/// - 名前は UTF-16 で 255 まで(APFS の上限も同じ単位: 絵文字 127 個は作れ 128 個は作れない)。長すぎれば**基を末尾から削って**
///   言葉(`のエイリアス`)は残す。番号を付けるときは、言葉を足した名前の末尾を削って番号を足す(`…のエイリ 2`)。文字の途中では
///   切らない(絵文字 124 個 + `のエイリアス` = 254)。
/// - 言葉は Finder の言語(OS の言語。`finderLocalization`)。表は Finder.app の `LocalizableMerged.strings` の `N3_V1`
///   (macOS 27)を写したもの。英語は `photo.jpg alias`。
///
/// 番号の付け方を `FileNameValidation.nextAvailableName` に任せない: あちらは `.` の後ろを拡張子とみなし、`photo.jpgのエイリアス` を
/// `photo 2.jpgのエイリアス` にする(Finder は `photo.jpgのエイリアス 2`)。
nonisolated enum FinderAliasName {
    /// 名前の上限(UTF-16 の単位)。
    static let maximumLength = 255

    /// Finder の言語ごとの「〈名前〉のエイリアス」(`%@` が名前)。Finder の `N3_V1`(`^=1` を `%@` に)。
    static let templates: [String: String] = [
        "ar": "الاسم المستعار لـ %@", "ca": "%@ àlies", "cs": "%@ (zástupce)", "da": "%@-henvisning", "de": "%@ Alias",
        "el": "%@ συντόμευση", "en": "%@ alias", "en_AU": "%@ alias", "en_CA": "%@ alias", "en_GB": "%@ alias",
        "en_IN": "%@ alias", "en_PH": "%@ alias", "es": "%@ alias", "es_419": "Alias de %@", "es_US": "Alias de %@",
        "fi": "%@ alias", "fr": "%@ alias", "fr_CA": "%@ alias", "he": "הקיצור של %@", "hi": "%@ एलियस", "hr": "%@ alias",
        "hu": "%@ alias", "id": "Alias %@", "it": "%@ alias", "ja": "%@のエイリアス", "ko": "%@ 가상본", "ms": "%@ alias",
        "nl": "%@ alias", "no": "%@-alias", "pl": "%@-alias", "pt_BR": "atalho de %@", "pt_PT": "%@ alias", "ro": "Alias %@",
        "ru": "Псевдоним %@", "sk": "%@ - alias", "sl": "%@ sklic", "sv": "%@ alias", "th": "%@ นามแฝง", "tr": "%@ arması",
        "uk": "%@ псевдонім", "vi": "Biệt hiệu %@", "zh_CN": "%@的替身", "zh_HK": "%@替身", "zh_TW": "%@替身",
    ]

    /// Finder が使う言語(`templates` の鍵)。Finder と同じく、OS の言語の並びから Finder の持つ言語を選ぶ。
    /// - Parameter preferredLanguages: OS の言語の並び。既定は `systemPreferredLanguages`(**このアプリの表示言語ではない** ―― アプリは
    ///   自分の `AppleLanguages` を書き換える。`AppLanguage.applyAppleLanguagesOverride`)。
    static func finderLocalization(preferredLanguages: [String] = systemPreferredLanguages()) -> String {
        Bundle.preferredLocalizations(from: Array(templates.keys), forPreferences: preferredLanguages).first ?? "en"
    }

    /// OS の言語の並び(全体の設定 `AppleLanguages`。このアプリ自身の上書きは見ない)。
    static func systemPreferredLanguages() -> [String] {
        let value = CFPreferencesCopyValue(
            "AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        return value as? [String] ?? []
    }

    /// 番号の無い名前(ディスクに置く綴り)。
    /// - Parameter displayName: Finder に見えている名前(`URLResourceValues.localizedName`)。
    static func baseName(displayName: String, localization: String) -> String {
        let template = templates[localization] ?? templates["en"] ?? "%@ alias"
        let wording = template.replacingOccurrences(of: "%@", with: "")
        let room = max(maximumLength - wording.utf16.count, 0)
        let name = template.replacingOccurrences(of: "%@", with: truncated(displayName, toUTF16Length: room))
        // 見えている名前の `/` はディスクの `:`(Finder の表示の約束)。
        return name.replacingOccurrences(of: "/", with: ":")
    }

    /// `number` 番目の候補(1 なら `base` そのもの、2 以上なら末尾に ` 2` …)。
    static func candidate(base: String, number: Int) -> String {
        guard number >= 2 else { return truncated(base, toUTF16Length: maximumLength) }
        let suffix = " \(number)"
        return truncated(base, toUTF16Length: max(maximumLength - suffix.utf16.count, 0)) + suffix
    }

    /// 塞がっていない最初の候補(`isTaken` はディスクを見る。大文字小文字・正規化の違いはボリュームが判断する)。
    static func firstAvailable(base: String, isTaken: (String) -> Bool) -> String {
        var number = 1
        while true {
            let name = candidate(base: base, number: number)
            if !isTaken(name) { return name }
            number += 1
        }
    }

    /// 先頭から、UTF-16 で `length` に収まるだけの文字(書記素の単位。絵文字や濁点を途中で切らない)。
    static func truncated(_ text: String, toUTF16Length length: Int) -> String {
        guard text.utf16.count > length else { return text }
        var result = ""
        var count = 0
        for character in text {
            let width = character.utf16.count
            guard count + width <= length else { break }
            result.append(character)
            count += width
        }
        return result
    }
}

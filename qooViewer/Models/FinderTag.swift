import Foundation

/// Finder のタグ 1 つ(拡張属性 `com.apple.metadata:_kMDItemUserTags` の配列の 1 要素。2026-11-03)。
///
/// 要素の形は**色付きなら `名前\n色番号`、色無しなら `名前`**(Finder で付けたタグで実測)。`rawValue` をそのまま持ち、触っていない
/// タグは 1 バイトも変えずに書き戻す ―― `名前\n0` と `名前` のどちらで書かれていても、形を揃え直さない。
nonisolated struct FinderTag: Hashable, Sendable, Identifiable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// - Parameter color: 色(nil なら色無し)。
    init(name: String, color: FinderTagColor?) {
        rawValue = color.map { "\(name)\n\($0.rawValue)" } ?? name
    }

    var id: String { rawValue }

    /// 名前(最初の改行より前)。
    var name: String {
        rawValue.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawValue
    }

    /// 色(色番号として読めなければ nil)。
    var color: FinderTagColor? {
        let parts = rawValue.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let number = Int(parts[1]) else { return nil }
        return FinderTagColor(rawValue: number)
    }

    /// 同じタグか。大文字小文字の違いだけなら同じものとして扱う(同じ名前のチップを 2 つ作らない)。
    /// Swift の `==` は正準等価なので、NFC と NFD の違いもここで吸収される。
    func hasName(_ other: String) -> Bool {
        name.compare(other, options: .caseInsensitive) == .orderedSame
    }
}

/// タグの変更 1 回ぶん。**書く直前に読み直した一覧へ当てる**ので、インスペクタを開いている間に Finder で足したタグを消さない。
nonisolated enum FinderTagEdit: Hashable, Sendable {
    case add(name: String)
    case remove(name: String)

    /// `tags` へ当てた結果。変わらないなら nil。
    /// - Parameter localization: 標準の色の名前を引く言語(`FinderTagColor.finderLocalization`)。
    func applied(to tags: [FinderTag], localization: String) -> [FinderTag]? {
        switch self {
        case .add(let rawName):
            // 改行は色番号との区切りなので、名前に入れない(1 行の欄なので普通は来ないが、貼り付けはありうる)。
            let name = rawName.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !tags.contains(where: { $0.hasName(name) }) else { return nil }
            return tags + [FinderTag(name: name, color: FinderTagColor.color(forTagNamed: name, localization: localization))]
        case .remove(let name):
            let remaining = tags.filter { !$0.hasName(name) }
            return remaining.count == tags.count ? nil : remaining
        }
    }
}

/// Finder の標準の色。**値は Finder の色番号**(`NSWorkspace.fileLabels` / `fileLabelColors` の位置、`com.apple.FinderInfo` の
/// 色の 3 ビット、タグの `名前\n色番号` で共通。レッド = 6・ブルー = 4 は Finder で付けて実測)。
nonisolated enum FinderTagColor: Int, CaseIterable, Sendable {
    case gray = 1, green, purple, blue, yellow, red, orange

    /// Finder のメニューの並び。
    static let menuOrder: [FinderTagColor] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]

    /// 言語ごとの色の名前(色番号 1〜7 の順)。Finder.app の `LocalizableMerged.strings` の `TG_COLOR_1`〜`7`(macOS 27)を写したもの。
    /// 名前がタグの実体なので、**Finder の言語の名前で書く**(`FinderAliasName` と同じ考え)。アプリの表示言語で書くと、
    /// Finder の「レッド」とは別の「Red」というタグが増える。
    static let names: [String: [String]] = [
        "ar": ["رمادي", "أخضر", "أرجواني", "أزرق", "أصفر", "أحمر", "برتقالي"],
        "ca": ["Grisa", "Verda", "Morada", "Blava", "Groga", "Vermella", "Taronja"],
        "cs": ["Šedá", "Zelená", "Fialová", "Modrá", "Žlutá", "Červená", "Oranžová"],
        "da": ["Grå", "Grøn", "Lilla", "Blå", "Gul", "Rød", "Orange"],
        "de": ["Grau", "Grün", "Lila", "Blau", "Gelb", "Rot", "Orange"],
        "el": ["Γκρι", "Πράσινο", "Μοβ", "Μπλε", "Κίτρινο", "Κόκκινο", "Πορτοκαλί"],
        "en": ["Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"],
        "en_AU": ["Grey", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"],
        "en_CA": ["Grey", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"],
        "en_GB": ["Grey", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"],
        "en_IN": ["Grey", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"],
        "en_PH": ["Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"],
        "es": ["Gris", "Verde", "Morado", "Azul", "Amarillo", "Rojo", "Naranja"],
        "es_419": ["Gris", "Verde", "Morado", "Azul", "Amarillo", "Rojo", "Naranja"],
        "es_US": ["Gris", "Verde", "Morado", "Azul", "Amarillo", "Rojo", "Naranja"],
        "fi": ["Harmaa", "Vihreä", "Violetti", "Sininen", "Keltainen", "Punainen", "Oranssi"],
        "fr": ["Gris", "Vert", "Violet", "Bleu", "Jaune", "Rouge", "Orange"],
        "fr_CA": ["Gris", "Vert", "Violet", "Bleu", "Jaune", "Rouge", "Orange"],
        "he": ["אפור", "ירוק", "סגול", "כחול", "צהוב", "אדום", "כתום"],
        "hi": ["धूसर", "हरा", "जामुनी", "नीला", "पीला", "लाल", "नारंगी"],
        "hr": ["Siva", "Zelena", "Ljubičasta", "Plava", "Žuta", "Crvena", "Narančasta"],
        "hu": ["Szürke", "Zöld", "Bíbor", "Kék", "Sárga", "Piros", "Narancs"],
        "id": ["Abu-Abu", "Hijau", "Ungu", "Biru", "Kuning", "Merah", "Oranye"],
        "it": ["Grigio", "Verde", "Viola", "Blu", "Giallo", "Rosso", "Arancione"],
        "ja": ["グレイ", "グリーン", "パープル", "ブルー", "イエロー", "レッド", "オレンジ"],
        "ko": ["회색", "초록색", "보라색", "파란색", "노란색", "빨간색", "주황색"],
        "ms": ["Kelabu", "Hijau", "Ungu", "Biru", "Kuning", "Merah", "Jingga"],
        "nl": ["Grijs", "Groen", "Paars", "Blauw", "Geel", "Rood", "Oranje"],
        "no": ["Grå", "Grønn", "Lilla", "Blå", "Gul", "Rød", "Oransje"],
        "pl": ["Szary", "Zielony", "Purpurowy", "Niebieski", "Żółty", "Czerwony", "Pomarańczowy"],
        "pt_BR": ["Cinza", "Verde", "Roxo", "Azul", "Amarelo", "Vermelho", "Laranja"],
        "pt_PT": ["Cinzento", "Verde", "Roxo", "Azul", "Amarelo", "Vermelho", "Laranja"],
        "ro": ["Gri", "Verde", "Mov", "Albastru", "Galben", "Roșu", "Portocaliu"],
        "ru": ["Серый", "Зеленый", "Лиловый", "Синий", "Желтый", "Красный", "Оранжевый"],
        "sk": ["Sivá", "Zelená", "Fialová", "Modrá", "Žltá", "Červená", "Oranžová"],
        "sl": ["Siva", "Zelena", "Vijolična", "Modra", "Rumena", "Rdeča", "Oranžna"],
        "sv": ["Grå", "Grön", "Lila", "Blå", "Gul", "Röd", "Orange"],
        "th": ["สีเทา", "สีเขียว", "สีม่วง", "สีน้ำเงิน", "สีเหลือง", "สีแดง", "สีส้ม"],
        "tr": ["Gri", "Yeşil", "Mor", "Mavi", "Sarı", "Kırmızı", "Turuncu"],
        "uk": ["Сірий", "Зелений", "Бузковий", "Синій", "Жовтий", "Червоний", "Оранжевий"],
        "vi": ["Xám", "Lục", "Tía", "Lam", "Vàng", "Đỏ", "Cam"],
        "zh_CN": ["灰色", "绿色", "紫色", "蓝色", "黄色", "红色", "橙色"],
        "zh_HK": ["灰色", "綠色", "紫色", "藍色", "黃色", "紅色", "橙色"],
        "zh_TW": ["灰色", "綠色", "紫色", "藍色", "黃色", "紅色", "橙色"],
    ]

    /// Finder が使う言語(`names` の鍵)。OS の言語の並びから選ぶ(このアプリの表示言語ではない。`FinderAliasName.finderLocalization` と同じ)。
    static func finderLocalization(preferredLanguages: [String] = FinderAliasName.systemPreferredLanguages()) -> String {
        Bundle.preferredLocalizations(from: Array(names.keys), forPreferences: preferredLanguages).first ?? "en"
    }

    /// その言語での名前。
    func name(localization: String) -> String {
        (FinderTagColor.names[localization] ?? FinderTagColor.names["en"] ?? [])[safe: rawValue - 1] ?? ""
    }

    /// 打った名前が標準の色の名前なら、その色(Finder で「レッド」を打つと赤いタグになるのと同じ)。
    static func color(forTagNamed name: String, localization: String) -> FinderTagColor? {
        allCases.first { $0.name(localization: localization).compare(name, options: .caseInsensitive) == .orderedSame }
    }

    /// `com.apple.FinderInfo`(32 バイト)の色。Finder は 10 バイト目の 3 ビットに持つ(実測: ブルー = 4 で 0x08)。
    static func fromFinderInfo(_ bytes: [UInt8]) -> FinderTagColor? {
        guard bytes.count > finderInfoColorByte else { return nil }
        return FinderTagColor(rawValue: Int(bytes[finderInfoColorByte] >> 1) & 0x07)
    }

    /// `bytes` の色を差し替えた値(ほかのビットは触らない)。
    static func settingFinderInfo(_ bytes: [UInt8], to color: FinderTagColor?) -> [UInt8] {
        var bytes = bytes
        guard bytes.count > finderInfoColorByte else { return bytes }
        bytes[finderInfoColorByte] = (bytes[finderInfoColorByte] & ~UInt8(0x0E)) | (UInt8(color?.rawValue ?? 0) << 1)
        return bytes
    }

    private static let finderInfoColorByte = 9
}

private extension Array {
    nonisolated subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

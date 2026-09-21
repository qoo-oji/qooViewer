import Foundation

/// 規則の窓に出す言葉の**鍵**(英語)。規則の一覧(`RuleCatalog`)は ID と値だけを持ち、見出しは画面の側が持つ。
/// 訳は `Localizable.xcstrings`(`Text(key:)` と `String.ui` が引く)。
/// ここに無い ID(新しい版で足された規則、利用者が足した規則)は、ID をそのまま出す。
enum RuleLabels {
    struct Item {
        var title: String
        var help: String = ""
    }

    // MARK: - 方針

    static let policies: [String: Item] = [
        "editions": Item(title: "Editions (full colour, deluxe edition, complete edition, …)", help: "What to do with a book that carries an edition mark"),
        "sources": Item(title: "Publication forms (download edition, …)", help: "What to do with a book that carries a publication-form mark"),
        "compilations": Item(title: "Where compilations and side stories go", help: "Which series a book whose title holds a compilation word joins"),
        "compilationVolume": Item(title: "Volume number of a compilation in the main series", help: "Acts only when compilations join the main series"),
        "magazines": Item(title: "Magazines", help: "How names that carry a year and an issue are grouped"),
        "unnumberedFirst": Item(title: "A single book with no number", help: "Whether it counts as volume 1 of its series"),
        "differentRelation": Item(title: "Books with different source works", help: "When books that would be grouped carry different @source values"),
        "differentGenre": Item(title: "Books with different genres", help: "Whether books with different @genre values may share a series"),
        "subtitled": Item(title: "Books with a subtitle", help: "Whether “X, Part One” joins the “X” group built from volumes"),
    ]

    static let choices: [String: [String: String]] = [
        // 版違いも入手経路違いも、選ぶのは同じこと(同じ作品として扱うか)。**同じ言葉で書く** ―― 同じものを
        // 2 通りに言うと、違いがあるように見える(2026-09-20、利用者の指摘)。
        "editions": ["sameWork": "The same work (a duplicate)", "separateBooks": "Count them as separate books", "ignore": "Do not look for the mark"],
        "sources": ["sameWork": "The same work (a duplicate)", "separateBooks": "Count them as separate books", "ignore": "Do not look for the mark"],
        "compilations": ["ownSeries": "In a series of their own, “X Compilation”", "inMainSeries": "In the main series", "notInSeries": "In no series at all"],
        "compilationVolume": ["none": "Leave the number empty (the volume still shows what the name says)", "afterRange": "Right after the last volume they collect (1–4 becomes 4.5)"],
        "magazines": ["perYear": "One series per year", "whole": "One series for the whole magazine"],
        "unnumberedFirst": ["inferFirst": "Read it as volume 1", "leaveEmpty": "Leave the volume empty"],
        "differentRelation": ["split": "Put them in separate series", "keep": "Keep them together"],
        "differentGenre": ["split": "Put them in separate series", "keep": "Let them share a series"],
        "subtitled": ["attach": "Join the group", "separate": "Stay out of it"],
    ]

    // MARK: - 規則

    static let treatments: [String: Item] = [
        "keep": Item(title: "Left out of the extraction", help: "The word is not a mark of any kind: it stays in the title, and neither the rules below nor the ways of reading a volume touch it. Put such a rule above the one you want it to escape."),
        "edition": Item(title: "Edition mark", help: "Dropped from the title before books are compared. Books with the same title once it is dropped are the same work in another edition"),
        "source": Item(title: "Publication-form mark", help: "Dropped from the title before books are compared. The contents are the same; only the form it was published in differs"),
        "compilation": Item(title: "Compilation word", help: "Where such a book goes is set by the policy “Where compilations and side stories go”"),
        "standalone": Item(title: "Keep out of every series", help: "A book whose title holds this word joins no series"),
    ]

    static let rules: [String: Item] = [
        "plain": Item(title: "Words left out of the extraction", help: "Words such as “Full Colour Compilation” that are neither an edition mark nor a compilation"),
        "edition": Item(title: "Edition marks", help: "Full colour edition, deluxe edition, complete edition, English edition, …"),
        "source": Item(title: "Publication-form marks", help: "Download edition. The standard word list is empty; add your own"),
        "compilationMark": Item(title: "Compilation words", help: "Compilation, side story, …"),
        "standalone": Item(title: "Words that keep a book out of every series", help: "A book whose title holds one of these joins no series. The bundled list is empty"),
        "compilation": Item(title: "Compilation series", help: "Collects compilations into a series named “X Compilation”"),
        "volumeHead": Item(title: "Stage 1: title plus volume", help: "Groups books shaped like “X 3” by the head that is left once the volume is removed"),
        "mergeVolumeSubgroups": Item(title: "Take in a run that is itself a volume of the series",
                                     help: "“X 6 front half” and “X 6 back half” form their own run named “X 6”. When that name is the series name plus something that reads as a volume, the run joins the series instead of standing beside it"),
        "mergeSubseries": Item(title: "Take in a run with numbers of its own",
                               help: "“X eve A”, “X eve A 3” and “X eve A 4” form their own run named “X eve A”, because they carry numbers of their own. When this is on, such a run joins the series “X” too — but only when “X” is itself a run of numbered volumes — and each book keeps its subtitle in the volume (“eve A 3”) so it does not clash with the series’ own volume 3. Compilations are left to the compilation policy"),
        "attachAcrossScript": Item(title: "Take in a subtitle that follows with no separator",
                                   help: "“Her Hypnosis Revenge” joins the run of “Her Hypnosis 2, 3, 4”. It acts only where the script changes and what follows is not hiragana — hiragana carries on the same word — and only to join a run that volumes already built, never to start one"),
        "sharedPrefix": Item(title: "Stage 2: shared leading text", help: "Groups the remaining books by the text their titles share at the front"),
        "reject-hiragana-ending": Item(title: "Reject shared text that ends in hiragana", help: "When the shared text is cut mid-word and ends in a particle. Also when one whole title is the head of another and the longer goes on in hiragana (“…です!!” and “…ですか?”)"),
        "reject-single-script": Item(title: "Reject shared text written in one script", help: "When the shared text is cut mid-word and is all katakana or all kanji"),
        "reject-common-english": Item(title: "Reject titles made only of common English words", help: "When both titles are made only of words found in the dictionary"),
        "splitByRelation": Item(title: "Split a group by source work", help: "Whether it acts is set by the policy “Books with different source works”"),
        "rejectSameWork": Item(title: "Reject groups that differ only by edition", help: "Whether it acts is set by the policies “Editions” and “Publication forms”"),
        "includeClosingBrackets": Item(title: "Reach past an open bracket to its close", help: "So that a series name is not cut off in the middle of “【X】”"),
        "includeFollowing": Item(title: "Keep a following “!” or “?”", help: "Keeps the “!” of “Garden of the Moon!” in the series name"),
        "trimTrailing": Item(title: "Drop trailing separators", help: "The “-” or “~” left at the end of a series name"),
        "dropLastWord": Item(title: "Drop a trailing “side” or “part”", help: "The series name of “X side A” and “X side B” is “X”"),
        "ordinal": Item(title: "Enclosed numbers (①②③)"),
        "number": Item(title: "Digits (3, Volume 3, Vol.3, 36-37)"),
        "kanji": Item(title: "Kanji numerals (三, 第三巻)"),
        "kanjiAlone": Item(title: "Kanji numerals on their own (弐, 参, 四)",
                           help: "The numerals in the list (弐, 参, 四 …) are read as the volume with no word before and no unit after, as long as a space, the end of the name, or a separator follows. “X 四季” is not read"),
        "greek": Item(title: "Greek letters (α β γ)"),
        "roman": Item(title: "Roman numerals (II, III)"),
        "position": Item(title: "Words for a position (upper / middle / lower, first / second part)"),
        "sequel": Item(title: "Words for a book that comes after the numbering (after, epilogue)",
                       help: "A book that carries one of these words instead of a number is placed right after the last numbered volume of its series"),
        "wordNumber": Item(title: "Numbers written out in kana (に, さん, ふたつ)",
                           help: "Which word stands for which number is set by the list; the word is kept as the volume you see"),
        "particles": Item(title: "Leave a volume empty when what follows the series name starts with a particle",
                          help: "A book in the series “X” whose title goes on straight after “X” with no separator gets the rest of the title as its volume (“Xなつまつり”). When the rest starts with one of the particles in the list (“Xの安息”), it is the rest of a word, and the volume is left empty"),
        "followers": Item(title: "What may come right after a volume number",
                          help: "A number is read as the volume when a unit, a space, the end of the name, or one of these characters follows it (“X 4ー夜編ー”)"),
        "sharedLeadingKanji": Item(title: "Read a leading kanji numeral as the volume", help: "When the books of one series start with kanji numerals"),
        "firstVolume": Item(title: "Read a single unnumbered book as volume 1", help: "Whether it acts is set by the policy “A single book with no number”"),
    ]

    static let stages: [String: String] = [
        "grouping": "Building groups (in this order)",
        "grouping.sharedPrefix.conditions": "Stage 2: when not to build a group",
        "naming": "Tidying the series name (in this order)",
        "volume.inference": "Guessing the volume",
    ]

    static let parameters: [String: String] = [
        "treat": "What the words in it mean", "words": "Words", "patterns": "Regular expressions",
        "singleWhenMainExists": "Make a series of a single compilation when the main series exists",
        "minPrefix": "Fewest characters when the shared text is cut mid-word",
        "minWholeTitle": "Fewest characters when one whole title matches",
        "dictionary": "Dictionary",
        "unlessVolume": "Group them anyway when a volume follows",
        "pairs": "Bracket pairs", "characters": "Characters",
        "prefixes": "Words before the volume number", "counters": "Units after the volume number",
        "wholeOnlyCounters": "Units used only when asking whether the rest is a volume",
        "mergedSpan": "Largest gap between merged issue numbers",
        "first": "Words for the first part", "middle": "Words for a middle part", "last": "Words for the last part",
        "minBooks": "How many books it takes", "excludeMarkers": "A book with this word after the series name is not volume 1",
        "excludePrefixes": "A book with this word right after the series name is not volume 1",
    ]

    // MARK: - 一覧

    static let lists: [String: Item] = [
        "plainWords": Item(title: "Words left out of the extraction", help: "Words that become neither an edition mark, nor a compilation, nor a volume"),
        "standaloneWords": Item(title: "Words that keep a book out of every series", help: "A book whose title holds one of these joins no series. To leave out a single book, write its title"),
        "editionWords": Item(title: "Edition marks"),
        "sourceWords": Item(title: "Publication-form marks"),
        "compilationWords": Item(title: "Compilation words"),
        "volumePrefixes": Item(title: "Words before the volume number", help: "vol, 第, その … An English word may be followed by a full stop"),
        "volumeCounters": Item(title: "Units after the volume number", help: "巻, 話, 号 …"),
        "wholeOnlyCounters": Item(title: "Units used only when asking whether the rest is a volume",
                                  help: "A unit here settles a volume only when the whole of what is left is a number and this unit. It is never picked out of the middle of a title."),
        "numberWords": Item(title: "Words that stand for a number",
                            help: "に → 2, さん → 3, ふたつ → 2, みっかめ → 3 … Some names spell the number out in kana on purpose, either read aloud or counted. The word is kept as the volume you see; the number on the right is the one it sorts by. It is only read when the word stands on its own, so “にっこり” is left alone."),
        "volumeFollowers": Item(title: "Characters that may come right after a volume number",
                                help: "~ - ・ ! ? . ) ー … A number is read as the volume when one of these follows it. 〜 and ― are not in the list: add them if your names use them."),
        "kanjiAloneDigits": Item(title: "Kanji numerals that count on their own",
                                 help: "壱 to 玖 (the old way of writing 一 to 九, with both 漆 and 柒 for seven), the traditional forms 壹 貳 參, and the ordinary numerals 一 to 九. “X 弐” and “X 四” are volumes 2 and 4. Take out the ones your titles use as words."),
        "kanjiCounters": Item(title: "Units after a kanji numeral",
                              help: "Kept narrower than the list for ordinary digits on purpose: a kanji numeral with nothing in front of it cannot be told from an ordinary word (三人の夜, 十字架). Add 月 here and 三月 becomes volume 3."),
        "positionFirst": Item(title: "Words for the first part (上, 前編)",
                              help: "Keep the three lists in the same order (上/中/下, 上巻/中巻/下巻, 前編/中編/後編): a first volume that had no number is written with the word that matches the set — 後編 gives 前編."),
        "positionMiddle": Item(title: "Words for a middle part (中, 中編)"),
        "positionLast": Item(title: "Words for the last part (下, 後編)"),
        "sequelWords": Item(title: "Words for a book that comes after the numbering",
                            help: "アフター, 後日談, その後 … The wording in the name is kept as the volume you see. The number it sorts by is the last volume of that series plus one; compilations and side stories, which sit at the offset, are not counted as part of the numbering."),
        "notFirstMarkers": Item(title: "Words that rule out volume 1", help: "A book with this word after the series name"),
        "particles": Item(title: "Particles (hiragana that carry on the word before them)", help: "の, と, は, に. When what follows the series name with no separator starts with one of these, it is not shown as the volume"),
        "notFirstPrefixes": Item(title: "Words right after the series name that rule out volume 1", help: "“X ex”, “X SP”"),
        "labelIntroducers": Item(title: "Words dropped from the end of a series name", help: "side, part, episode …"),
        "ignoredInComparison": Item(title: "Characters ignored when books are compared", help: "Spaces, and the marks often used to decorate a title"),
        "boundaryCharacters": Item(title: "Characters counted as a word boundary", help: "Spaces and digits are always a boundary"),
        "trimTrailing": Item(title: "Characters dropped from the end of a series name"),
        "keepFollowing": Item(title: "Characters kept when they follow a series name", help: "! ? ♡ … “X♡2” becomes the series “X♡”, volume 2"),
        "variantKanji": Item(title: "Kanji treated as the same character", help: "The character on the left is compared as the one on the right"),
        "brackets": Item(title: "Bracket pairs", help: "Closing bracket → opening bracket"),
    ]

    /// 一覧を画面に並べる順(よく直すものを上に)と、**何のための語か**でのまとまり。
    /// 21 個が見出しも無く平らに並んでいて、目当ての一覧を探すのに全部を読む必要があった(2026-09-20、設計の見直し)。
    static let listGroups: [(title: String, ids: [String])] = [
        ("Words found in a title", ["plainWords", "standaloneWords", "editionWords", "sourceWords", "compilationWords"]),
        ("Words that make a volume number", ["volumePrefixes", "volumeCounters", "wholeOnlyCounters", "kanjiCounters",
                                             "kanjiAloneDigits", "volumeFollowers", "numberWords", "positionFirst", "positionMiddle",
                                             "positionLast", "sequelWords", "particles"]),
        ("Words that rule out volume 1", ["notFirstMarkers", "notFirstPrefixes"]),
        ("Characters that tidy a series name", ["labelIntroducers", "trimTrailing", "keepFollowing", "brackets"]),
        ("Characters used when two titles are compared", ["ignoredInComparison", "boundaryCharacters", "variantKanji"]),
    ]

    static let listOrder = listGroups.flatMap(\.ids)

    static func rule(_ id: String) -> Item { rules[id] ?? Item(title: id) }

    /// 規則の見出し。同梱の規則は訳し、**利用者が足した規則はその人が付けた名前のまま**
    /// (名前が鍵とたまたま同じでも訳さない)。
    static func title(ofRule id: String) -> String { rules[id].map { $0.title.ui } ?? id }
    static func list(_ id: String) -> Item { lists[id] ?? Item(title: id) }
    static func parameter(_ name: String) -> String { parameters[name] ?? name }
    static func treatment(_ id: String) -> Item { treatments[id] ?? Item(title: id) }

    /// 目に見えない文字(空白・タブ)を、見える形にする。
    static func visible(_ item: String) -> String {
        switch item {
        case " ": "␠ (space)".ui
        case "　": "□ (ideographic space)".ui
        case "\t": "⇥ (tab)".ui
        default: item
        }
    }
}

extension RuleLabels {
    /// 同梱のプリセットの見出しと説明の鍵。**同梱の JSON には書かない**(JSON に日本語を書くと、英語で使う
    /// 利用者にそのまま出てしまう)。利用者が付けた見出しは、その人の言葉のまま出す。
    static let presets: [String: Item] = [
        "doujinshi": Item(title: "Doujinshi (genre first)",
                          help: "The trailing parenthesis is the source work. A parenthesis inside the brackets holds the second author onwards."),
        "doujinshi-event": Item(title: "Doujinshi (event first)",
                                help: "Reads the leading parenthesis as the name of the event. The genre, which no name carries, is filled in by default."),
        "commercial": Item(title: "Commercial",
                           help: "The trailing parenthesis is the volume, when it is digits only. It also reads the shape “Series (volume) - author”."),
    ]

    static func preset(_ name: String) -> Item { presets[name] ?? Item(title: name) }
}

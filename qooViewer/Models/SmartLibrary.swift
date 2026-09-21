import Foundation

// スマートライブラリ(2026-09-21、利用者の指示。StackNest のスマートシェルフが土台)の値の型と、絞り込みの計算。
//
// すべて値の計算で、ディスクにも DB にも触れない(テストから直接確かめられる)。本の一覧を集めるのは
// `SmartLibraryCatalog`、保存するのは `SmartLibraryStore`、画面は Views/Welcome/SmartLibrary/。
// 設計は docs/plans/qoometa-smart-library-plan.md §3。

// MARK: - 本

/// スマートライブラリに並ぶ 1 冊。集めた時点の値を全部持ち、絞り込み・並べ替えの間はディスクに触れない
/// (ファイルブラウザの一覧の行と同じ考え方。FileBrowserEntry の型コメント)。
nonisolated struct SmartBook: Identifiable, Hashable, Sendable {
    /// bookID(フルパス)。
    let id: String
    /// ファイル名(拡張子つき。フォルダの本はフォルダ名)。
    let fileName: String
    let kind: SmartBookKind
    /// どこから来た本か(ライブラリ・よく使う項目・スマートライブラリの対象フォルダ)。
    var sources: SmartBookSources
    /// 入っているライブラリとコレクションの名前(ライブラリの本だけ)。
    var libraryNames: [String] = []
    var collectionNames: [String] = []
    /// 表紙に使うコレクションの行(ライブラリの本だけ)。
    var collectionItemID: UUID?
    /// メタデータ(登録済みなら DB の値、未登録なら qooMeta の提案)。
    var metadata: BookMetadataValues
    var isRegistered: Bool
    /// ファイル名がルールセットの型に合ったか(未登録の本の提案の確かさの目安)。
    var matchedFormat: Bool = true
    /// 追加日(ライブラリへ入れた日。ライブラリに無い本はファイルの作成日)。
    var dateAdded: Date?
    var creationDate: Date?
    var modificationDate: Date?
    var fileSize: Int64?
    /// 最後に読んだ日(読書位置の更新日)。一度も開いていなければ nil。
    var lastRead: Date?
    /// 読み進めた割合(0...1)。ページ数を記録していない本は nil。
    var progress: Double?
    var isFavorite = false

    var readState: SmartReadState {
        guard lastRead != nil else { return .unread }
        if let progress, progress >= SmartReadState.finishedThreshold { return .finished }
        return .reading
    }

    /// 表示の題(空ならファイル名から拡張子を除いたもの)。
    var displayTitle: String {
        metadata.title.isEmpty ? MetadataRulesStore.baseName(forBookID: id) : metadata.title
    }
}

nonisolated struct SmartBookSources: OptionSet, Hashable, Sendable, Codable {
    let rawValue: Int
    static let library = SmartBookSources(rawValue: 1 << 0)
    static let favoriteLocations = SmartBookSources(rawValue: 1 << 1)
    static let folders = SmartBookSources(rawValue: 1 << 2)
}

/// 本の種類。
nonisolated enum SmartBookKind: String, CaseIterable, Codable, Hashable, Sendable {
    case zip, rar, sevenZip, pdf, epub, folder

    init(fileName: String, isFolder: Bool) {
        if isFolder { self = .folder; return }
        switch archiveKind(forFileName: fileName) {
        case .rar?: self = .rar
        case .sevenZip?: self = .sevenZip
        default:
            if isPDFFile(fileName) { self = .pdf }
            else if isEpubFile(fileName) { self = .epub }
            else { self = .zip }
        }
    }

    var titleKey: String {
        switch self {
        case .zip: "ZIP"
        case .rar: "RAR"
        case .sevenZip: "7z"
        case .pdf: "PDF"
        case .epub: "EPUB"
        case .folder: "Folder"
        }
    }
}

/// 読んだかどうか。
nonisolated enum SmartReadState: String, CaseIterable, Codable, Hashable, Sendable {
    case unread, reading, finished

    /// ここまで読めば「読み終えた」(最後の見開きの 2 ページ目にいなくても読み終えたとみなす)。
    static let finishedThreshold = 0.95

    var titleKey: String {
        switch self {
        case .unread: "Unread"
        case .reading: "Reading"
        case .finished: "Finished"
        }
    }
}

// MARK: - 条件(スマートシェルフ)

/// 保存したスマートシェルフ: 名前と条件。StackNest のスマートシェルフと同じく**平らな条件の並び**に
/// 「すべて / いずれか」を 1 つ付けたもの(入れ子は無い)。
nonisolated struct SmartShelf: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var conditions: SmartShelfConditions
}

nonisolated struct SmartShelfConditions: Codable, Hashable, Sendable {
    enum Match: String, Codable, CaseIterable, Sendable {
        case all, any
    }
    var version = 1
    var match: Match = .all
    var rules: [SmartShelfRule] = []

    /// その本が条件に合うか。条件が 1 つも無ければ全部が合う(「すべての本」と同じ)。
    func matches(_ book: SmartBook, now: Date = Date()) -> Bool {
        let usable = rules.filter(\.isUsable)
        guard !usable.isEmpty else { return true }
        switch match {
        case .all: return usable.allSatisfy { $0.matches(book, now: now) }
        case .any: return usable.contains { $0.matches(book, now: now) }
        }
    }
}

/// 条件 1 つ。値は種類ごとに 1 つだけ使う(文字 / 数 / 選択肢)。
nonisolated struct SmartShelfRule: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var field: SmartField
    var op: SmartOperator
    var text: String = ""
    var number: Int = 30

    init(field: SmartField, op: SmartOperator? = nil, text: String = "", number: Int? = nil) {
        self.field = field
        self.op = op ?? field.valueType.operators[0]
        self.text = text
        self.number = number ?? field.valueType.defaultNumber
    }

    /// 保存・評価してよい条件か。**空の「含む」は全部に当たる**ので数えない(StackNest と同じ)。
    var isUsable: Bool {
        switch field.valueType {
        case .text:
            return op == .isEmpty || op == .isNotEmpty || !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .choice:
            return !text.isEmpty
        case .number, .days, .flag:
            return true
        }
    }

    func matches(_ book: SmartBook, now: Date) -> Bool {
        switch field.valueType {
        case .text:
            let values = field.textValues(of: book)
            let query = LibrarySearchQuery.normalized(text.trimmingCharacters(in: .whitespaces))
            let normalized = values.map(LibrarySearchQuery.normalized)
            switch op {
            case .contains: return normalized.contains { $0.contains(query) }
            case .notContains: return !normalized.contains { $0.contains(query) }
            case .equals: return normalized.contains(query)
            case .notEquals: return !normalized.contains(query)
            case .beginsWith: return normalized.contains { $0.hasPrefix(query) }
            case .endsWith: return normalized.contains { $0.hasSuffix(query) }
            case .isEmpty: return values.allSatisfy(\.isEmpty)
            case .isNotEmpty: return values.contains { !$0.isEmpty }
            default: return false
            }
        case .number:
            guard let value = field.numberValue(of: book) else { return false }
            let n = Double(number)
            switch op {
            case .atLeast: return value >= n
            case .atMost: return value <= n
            case .equalTo: return value == n
            default: return false
            }
        case .days:
            guard let date = field.dateValue(of: book) else { return op == .olderThan && field == .lastRead }
            let border = now.addingTimeInterval(-Double(max(0, number)) * 86_400)
            switch op {
            case .within: return date >= border
            case .olderThan: return date < border
            default: return false
            }
        case .choice:
            let current = field.choiceValue(of: book)
            switch op {
            case .is: return current == text
            case .isNot: return current != text
            default: return false
            }
        case .flag:
            let value = field.flagValue(of: book)
            switch op {
            case .is: return value
            case .isNot: return !value
            default: return false
            }
        }
    }
}

/// 条件に使える欄。
nonisolated enum SmartField: String, Codable, CaseIterable, Hashable, Sendable {
    case title, authors, genre, series, source, event, info, fileName, library, collection
    case volume, progress
    case dateAdded, lastRead
    case kind, readState
    case registered, favorite

    enum ValueType { case text, number, days, choice, flag
        var operators: [SmartOperator] {
            switch self {
            case .text: [.contains, .notContains, .equals, .notEquals, .beginsWith, .endsWith, .isEmpty, .isNotEmpty]
            case .number: [.atLeast, .atMost, .equalTo]
            case .days: [.within, .olderThan]
            case .choice, .flag: [.is, .isNot]
            }
        }
        var defaultNumber: Int {
            switch self {
            case .days: 30
            case .number: 1
            default: 0
            }
        }
    }

    var valueType: ValueType {
        switch self {
        case .title, .authors, .genre, .series, .source, .event, .info, .fileName, .library, .collection: .text
        case .volume, .progress: .number
        case .dateAdded, .lastRead: .days
        case .kind, .readState: .choice
        case .registered, .favorite: .flag
        }
    }

    var titleKey: String {
        switch self {
        case .title: "Title"
        case .authors: "Authors"
        case .genre: "Genre"
        case .series: "Series"
        case .source: "Source work"
        case .event: "Event"
        case .info: "Info"
        case .fileName: "File name"
        case .library: "Library"
        case .collection: "Collection"
        case .volume: "Volume"
        case .progress: "Progress (%)"
        case .dateAdded: "Date Added"
        case .lastRead: "Last Read"
        case .kind: "Kind"
        case .readState: "Reading Status"
        case .registered: "Metadata registered"
        case .favorite: "Favorite"
        }
    }

    /// 選択肢の欄の選択肢(値 → 見出しの鍵)。
    var choices: [(value: String, titleKey: String)] {
        switch self {
        case .kind: SmartBookKind.allCases.map { ($0.rawValue, $0.titleKey) }
        case .readState: SmartReadState.allCases.map { ($0.rawValue, $0.titleKey) }
        default: []
        }
    }

    func textValues(of book: SmartBook) -> [String] {
        let m = book.metadata
        switch self {
        case .title: return [book.displayTitle]
        case .authors: return m.authors
        case .genre: return [m.genre]
        case .series: return [m.series]
        case .source: return [m.source]
        case .event: return [m.event]
        case .info: return [m.info]
        case .fileName: return [book.fileName]
        case .library: return book.libraryNames
        case .collection: return book.collectionNames
        default: return []
        }
    }

    func numberValue(of book: SmartBook) -> Double? {
        switch self {
        case .volume: return book.metadata.volumeSort ?? Double(book.metadata.volume.trimmingCharacters(in: .whitespaces))
        case .progress: return book.progress.map { $0 * 100 }
        default: return nil
        }
    }

    func dateValue(of book: SmartBook) -> Date? {
        switch self {
        case .dateAdded: return book.dateAdded
        case .lastRead: return book.lastRead
        default: return nil
        }
    }

    func choiceValue(of book: SmartBook) -> String {
        switch self {
        case .kind: return book.kind.rawValue
        case .readState: return book.readState.rawValue
        default: return ""
        }
    }

    func flagValue(of book: SmartBook) -> Bool {
        switch self {
        case .registered: return book.isRegistered
        case .favorite: return book.isFavorite
        default: return false
        }
    }
}

nonisolated enum SmartOperator: String, Codable, CaseIterable, Hashable, Sendable {
    case contains, notContains, equals, notEquals, beginsWith, endsWith, isEmpty, isNotEmpty
    case atLeast, atMost, equalTo
    case within, olderThan
    case `is`, isNot

    var titleKey: String {
        switch self {
        case .contains: "contains"
        case .notContains: "does not contain"
        case .equals: "is"
        case .notEquals: "is not"
        case .beginsWith: "begins with"
        case .endsWith: "ends with"
        case .isEmpty: "is empty"
        case .isNotEmpty: "is not empty"
        case .atLeast: "is at least"
        case .atMost: "is at most"
        case .equalTo: "is equal to"
        case .within: "is in the last"
        case .olderThan: "is before the last"
        case .is: "is"
        case .isNot: "is not"
        }
    }

    /// 値の入力が要らない演算子。
    var takesNoValue: Bool { self == .isEmpty || self == .isNotEmpty }
}

// MARK: - 左ペインの絞り込み(保存しない)

/// 左ペインの「絞り込み」(StackNest のフィルタのポップオーバーに当たるもの)。スマートシェルフの上に AND で重なる。
nonisolated struct SmartQuickFilter: Codable, Hashable, Sendable {
    /// 空なら種類で絞らない。
    var kinds: Set<SmartBookKind> = []
    /// nil なら絞らない。
    var readState: SmartReadState?
    /// 追加日が N 日以内(nil なら絞らない)。
    var addedWithinDays: Int?
    /// 最後に読んだのが N 日以内。
    var readWithinDays: Int?
    /// メタデータを登録した本だけ / 登録していない本だけ。
    var registered: Bool?

    var isActive: Bool {
        !kinds.isEmpty || readState != nil || addedWithinDays != nil || readWithinDays != nil || registered != nil
    }

    func matches(_ book: SmartBook, now: Date = Date()) -> Bool {
        if !kinds.isEmpty, !kinds.contains(book.kind) { return false }
        if let readState, book.readState != readState { return false }
        if let days = addedWithinDays {
            guard let date = book.dateAdded, date >= now.addingTimeInterval(-Double(days) * 86_400) else { return false }
        }
        if let days = readWithinDays {
            guard let date = book.lastRead, date >= now.addingTimeInterval(-Double(days) * 86_400) else { return false }
        }
        if let registered, book.isRegistered != registered { return false }
        return true
    }
}

// MARK: - ブラウザ列(値と冊数で絞る)

/// 左ペインの「ブラウザ」の列に使える欄(StackNest の上ペインのブラウザ列)。
nonisolated enum SmartFacetField: String, Codable, CaseIterable, Hashable, Sendable {
    case genre, authors, series, source, event, library, collection, kind

    var titleKey: String {
        switch self {
        case .genre: "Genre"
        case .authors: "Authors"
        case .series: "Series"
        case .source: "Source work"
        case .event: "Event"
        case .library: "Library"
        case .collection: "Collection"
        case .kind: "Kind"
        }
    }

    /// 本の値(並びの欄は複数)。空の値は「(空)」として数える。
    func values(of book: SmartBook) -> [String] {
        let m = book.metadata
        switch self {
        case .genre: return m.genre.isEmpty ? [] : [m.genre]
        case .authors: return m.authors
        case .series: return m.series.isEmpty ? [] : [m.series]
        case .source: return m.source.isEmpty ? [] : [m.source]
        case .event: return m.event.isEmpty ? [] : [m.event]
        case .library: return Array(Set(book.libraryNames)).sorted()
        case .collection: return Array(Set(book.collectionNames)).sorted()
        case .kind: return [book.kind.rawValue]
        }
    }
}

/// ブラウザ列で選んだ値: 値か「(空)」。
nonisolated enum SmartFacetValue: Hashable, Codable, Sendable {
    case empty
    case value(String)
}

nonisolated enum SmartFacets {
    /// 列の値ごとの冊数(値の順。「(空)」は最後)。
    static func counts(_ books: [SmartBook], field: SmartFacetField) -> [(value: SmartFacetValue, count: Int)] {
        var counts: [String: Int] = [:]
        var empty = 0
        for book in books {
            let values = field.values(of: book)
            if values.isEmpty { empty += 1; continue }
            for value in Set(values) { counts[value, default: 0] += 1 }
        }
        var result = counts.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { (value: SmartFacetValue.value($0.key), count: $0.value) }
        if empty > 0 { result.append((.empty, empty)) }
        return result
    }

    static func matches(_ book: SmartBook, field: SmartFacetField, value: SmartFacetValue) -> Bool {
        let values = field.values(of: book)
        switch value {
        case .empty: return values.isEmpty
        case .value(let v): return values.contains(v)
        }
    }
}

// MARK: - 並べ替え

nonisolated enum SmartSortKey: String, Codable, CaseIterable, Hashable, Sendable {
    case title, fileName, authors, series, dateAdded, lastRead, dateModified

    var titleKey: String {
        switch self {
        case .title: "Title"
        case .fileName: "File name"
        case .authors: "Authors"
        case .series: "Series"
        case .dateAdded: "Date Added"
        case .lastRead: "Last Read"
        case .dateModified: "Date Modified"
        }
    }

    /// 既定の向き(日付は新しいものから)。
    var defaultAscending: Bool {
        switch self {
        case .dateAdded, .lastRead, .dateModified: false
        default: true
        }
    }
}

nonisolated enum SmartSort {
    /// 並べ替える。シリーズは シリーズ名 → 巻(StackNest と同じ 2 段)。同じ値はファイル名の順。
    static func sorted(_ books: [SmartBook], by key: SmartSortKey, ascending: Bool) -> [SmartBook] {
        func text(_ a: String, _ b: String) -> ComparisonResult { a.localizedStandardCompare(b) }
        func date(_ a: Date?, _ b: Date?) -> ComparisonResult {
            switch (a, b) {
            case let (a?, b?): return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
            case (nil, nil): return .orderedSame
            // 日付の無い本は、向きに関わらず後ろ(下の反転の前に向きを見て入れ替える)。
            case (nil, _): return ascending ? .orderedDescending : .orderedAscending
            case (_, nil): return ascending ? .orderedAscending : .orderedDescending
            }
        }
        func volume(_ book: SmartBook) -> Double {
            book.metadata.volumeSort ?? Double(book.metadata.volume) ?? .greatestFiniteMagnitude
        }
        return books.sorted { a, b in
            var result: ComparisonResult
            switch key {
            case .title: result = text(a.displayTitle, b.displayTitle)
            case .fileName: result = text(a.fileName, b.fileName)
            case .authors: result = text(a.metadata.authors.joined(separator: "、"), b.metadata.authors.joined(separator: "、"))
            case .series:
                let sa = a.metadata.series.isEmpty ? a.displayTitle : a.metadata.series
                let sb = b.metadata.series.isEmpty ? b.displayTitle : b.metadata.series
                result = text(sa, sb)
                if result == .orderedSame {
                    let va = volume(a), vb = volume(b)
                    result = va == vb ? .orderedSame : (va < vb ? .orderedAscending : .orderedDescending)
                }
            case .dateAdded: result = date(a.dateAdded, b.dateAdded)
            case .lastRead: result = date(a.lastRead, b.lastRead)
            case .dateModified: result = date(a.modificationDate, b.modificationDate)
            }
            if result == .orderedSame { return text(a.fileName, b.fileName) == .orderedAscending }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }
}

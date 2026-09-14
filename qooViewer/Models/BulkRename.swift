import Foundation
import UniformTypeIdentifiers

/// ファイルブラウザの一括リネーム(改善要望7 段階 5、2026-09-14)。Finder の「名称変更…」(複数選択)を写す。
/// **名前を計算するだけ**でファイルには触らない(実行は BulkRenameFileCommand)。
///
/// ■ 何を写したか(この機の macOS 26.6 の Finder で、使い捨てボリュームに合成名のファイルを置いて実測。2026-09-14)
/// 計画(§段階 5)と検討メモ §8 は Web と nib から推した仕様だったが、実物は次のとおりで、推測と違う点が多かった。
/// - **拡張子 = 名前の後ろから続く「登録済みの拡張子」全部**。`c.zip.cbz` → `ファイル 1.zip.cbz`、`g.tar.gz` →
///   `….tar.gz`、`p.q.txt` → `….txt`(q は未登録)、`1.2.3` / `o.1` → 拡張子なし、`h.x y` → なし。
///   「登録済み」は `UTType(filenameExtension:)` が動的な型でないこと(22 例すべてで Finder と一致)。フォルダも同じ規則。
/// - **テキストを置き換える**: 大文字小文字を区別せず、全部の出現を、拡張子を含む名前全体で置き換える。
///   **置き換えた結果の最後の拡張子が登録済みでなくなったら、元の最後の拡張子を付け直す**
///   (`c.txt` の txt→qq は `c.qq.txt`、`.txt`→空 は `d.txt` のまま、`jpeg`→`jpg` は `b.jpg`、`c.zip.cbz` の cbz→qq は `c.zip.qq.cbz`)。
/// - **テキストを追加**: 空白を入れない。「名前の後」は拡張子の前へ。
/// - **フォーマット**: カスタムフォーマットが空でなければ元の名前を捨ててそれにし、番号・日付との間に何も挟まない
///   (既定の「ファイル 」の末尾の空白がそのまま区切りに見える ―― 「ファイル 1」「1ファイル 」)。**空なら元の名前を使い、
///   間に空白を 1 つ挟む**(「a 1.txt」「1 a.txt」)。カウンタは 5 桁のゼロ埋め、インデックスは素の数。
///   日付は実行した時刻で、書式は Finder の文言表の `DATE_FORMATTER1`(日本語 `yyyy-MM-dd h.mm.ss a`、英語 `yyyy-MM-dd 'at' h.mm.ss a`)。
///   開始番号の欄は数字しか受け付けず、空なら 1。日付のときは開始番号の欄が淡色になる。
/// - **番号は表示順**に振る(フォルダを上にしていればフォルダから)。例の行は表示順で最初の項目。
/// - **衝突は止めずに避ける**(計画の「無効にして赤字」ではなかった)。比べる相手は**そのフォルダの元の名前全部**
///   (選んだ項目の元の名前も、この操作で名前が変わって空く予定のものも含む。自分自身は除く)と、この操作で先に決めた名前。
///   インデックス・カウンタは**番号を進めて**避け(`F 1`〜`F 3` を開始 2 で振ると `F 4`〜`F 6`)、それ以外は `name 2.ext`
///   (拡張子は上の規則。`c 2.zip.cbz`)。
///   新しい名前は元の名前のどれとも重ならないので、**入れ替え・ずらしのための一時名(2 パス)は要らない**。
/// - 使えない名前(先頭がドット など)が 1 つでもあると、Finder は何も変えずにアラートを出す。qooViewer は同じ判定を
///   シートの中で先に行い、理由を出して「名称変更」を押せなくする(`Problem`)。`/` は Finder だと `:` として保存されるが、
///   1 件の名前の変更と同じく使えない文字として断る(FileNameValidation の型コメント)。
/// - 「名称変更」を押せないのは、置き換えで検索文字列が空のとき・追加でテキストが空のときだけ(`canApply`)。
nonisolated enum BulkRename {
    enum Placement: String, CaseIterable, Codable, Sendable {
        case beforeName
        case afterName
    }

    enum FormatStyle: String, CaseIterable, Codable, Sendable {
        case nameAndIndex
        case nameAndCounter
        case nameAndDate
    }

    enum Mode: Equatable, Sendable {
        case replaceText(find: String, replaceWith: String)
        case addText(String, placement: Placement)
        case format(style: FormatStyle, customFormat: String, placement: Placement, startNumber: Int)
    }

    /// そのままでは付けられない名前。
    enum Problem: Equatable, Sendable {
        case invalid(FileNameValidation.Failure)
        /// 先頭がドット(不可視になる)。Finder の一括リネームも断る。
        case leadingDot
    }

    struct Rename: Equatable, Sendable {
        let originalName: String
        let newName: String
        let problem: Problem?

        var isChanged: Bool { originalName != newName }
    }

    /// カウンタの桁数(Finder は選べない)。
    static let counterDigits = 5

    /// 「名称変更」を押せるか(Finder と同じ判定)。
    static func canApply(_ mode: Mode) -> Bool {
        switch mode {
        case let .replaceText(find, _): !find.isEmpty
        case let .addText(text, _): !text.isEmpty
        case .format: true
        }
    }

    /// 新しい名前を決める。
    ///
    /// - Parameters:
    ///   - names: 対象の今の名前(**表示順**)。
    ///   - existingNames: そのフォルダにある全部の名前(対象と、隠しファイルを含む対象外)。
    ///   - limit: 先頭からこの件数だけ決める(シートの例の行)。後ろの項目は前の項目の結果に影響しないので、途中で打ち切っても先頭の結果は変わらない。
    ///   - isRegisteredExtension: 拡張子が登録済みか。テストは固定の表を渡す(登録はインストールされたアプリで変わる)。
    static func plan(
        names: [String],
        existingNames: Set<String>,
        mode: Mode,
        date: Date = Date(),
        locale: Locale = AppLanguage.currentLocale,
        limit: Int? = nil,
        isRegisteredExtension: (String) -> Bool = BulkRename.isRegisteredExtension
    ) -> [Rename] {
        var cache: [String: Bool] = [:]
        let isRegistered = { (ext: String) -> Bool in
            if let known = cache[ext] { return known }
            let known = !ext.isEmpty && isRegisteredExtension(ext)
            cache[ext] = known
            return known
        }
        let existing = Set(existingNames.map(FileNameValidation.foldedForComparison))
        var assigned = Set<String>()
        var counter: Int
        if case let .format(_, _, _, startNumber) = mode { counter = startNumber } else { counter = 0 }
        let dateText = dateString(date, locale: locale)

        var renames: [Rename] = []
        for name in names.prefix(limit ?? names.count) {
            let own = FileNameValidation.foldedForComparison(name)
            let isTaken = { (candidate: String) -> Bool in
                let folded = FileNameValidation.foldedForComparison(candidate)
                return assigned.contains(folded) || (folded != own && existing.contains(folded))
            }
            let (stem, ext) = splitExtension(name, isRegistered: isRegistered)
            let newName: String
            switch mode {
            case let .replaceText(find, replaceWith):
                let replaced = find.isEmpty ? name : name.replacingOccurrences(of: find, with: replaceWith, options: .caseInsensitive)
                let candidate = keepingRegisteredExtension(of: name, in: replaced, isRegistered: isRegistered)
                newName = avoiding(candidate, isTaken: isTaken, isRegistered: isRegistered)
            case let .addText(text, placement):
                let candidate = placement == .beforeName ? text + name : joined(stem + text, ext)
                newName = avoiding(candidate, isTaken: isTaken, isRegistered: isRegistered)
            case let .format(style, customFormat, placement, _):
                let base = customFormat.isEmpty ? stem : customFormat
                let separator = customFormat.isEmpty ? " " : ""
                let compose = { (value: String) -> String in
                    joined(placement == .beforeName ? value + separator + base : base + separator + value, ext)
                }
                switch style {
                case .nameAndIndex, .nameAndCounter:
                    // 番号を進めて避ける(Finder)。進めた分だけ後ろの項目の番号もずれる。
                    var number = counter
                    var candidate = compose(numberString(number, style: style))
                    while isTaken(candidate) {
                        number += 1
                        candidate = compose(numberString(number, style: style))
                    }
                    counter = number + 1
                    newName = candidate
                case .nameAndDate:
                    newName = avoiding(compose(dateText), isTaken: isTaken, isRegistered: isRegistered)
                }
            }
            assigned.insert(FileNameValidation.foldedForComparison(newName))
            renames.append(Rename(originalName: name, newName: newName, problem: newName == name ? nil : problem(with: newName)))
        }
        return renames
    }

    /// 最初の使えない名前(無ければ nil)。
    static func firstProblem(in renames: [Rename]) -> Rename? {
        renames.first { $0.problem != nil }
    }

    // MARK: - 拡張子

    /// 登録済みの拡張子か(`UTType` が動的な型を返さない)。
    static func isRegisteredExtension(_ ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext) else { return false }
        return !type.isDynamic
    }

    /// 名前を「基部」と「後ろから続く登録済みの拡張子」(先頭のドットを除く。無ければ空)に分ける。
    /// 基部が空になるところまでは剥がさない(`.txt` は拡張子なし)。
    static func splitExtension(_ name: String, isRegistered: (String) -> Bool) -> (stem: String, ext: String) {
        var parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var extensions: [String] = []
        while parts.count > 1, let last = parts.last, isRegistered(last) {
            let remaining = parts.dropLast().joined(separator: ".")
            guard !remaining.isEmpty else { break }
            extensions.insert(last, at: 0)
            parts.removeLast()
        }
        return (parts.joined(separator: "."), extensions.joined(separator: "."))
    }

    private static func joined(_ stem: String, _ ext: String) -> String {
        ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// 置き換えで最後の拡張子が登録済みでなくなったら、元の最後の拡張子を付け直す(型コメント)。
    private static func keepingRegisteredExtension(of original: String, in replaced: String, isRegistered: (String) -> Bool) -> String {
        let originalExt = (original as NSString).pathExtension
        guard isRegistered(originalExt) else { return replaced }
        return isRegistered((replaced as NSString).pathExtension) ? replaced : "\(replaced).\(originalExt)"
    }

    /// 塞がっていれば `name 2.ext` …(拡張子は登録済みの規則で分ける ―― `c 2.zip.cbz`)。
    private static func avoiding(_ candidate: String, isTaken: (String) -> Bool, isRegistered: (String) -> Bool) -> String {
        guard isTaken(candidate) else { return candidate }
        let (stem, ext) = splitExtension(candidate, isRegistered: isRegistered)
        var number = 2
        while true {
            let next = joined("\(stem) \(number)", ext)
            if !isTaken(next) { return next }
            number += 1
        }
    }

    private static func numberString(_ number: Int, style: FormatStyle) -> String {
        style == .nameAndCounter ? String(format: "%0\(counterDigits)ld", number) : String(number)
    }

    /// 日付の部分。書式は表示言語の文言表から引く(Finder の `DATE_FORMATTER1` と同じ中身)。暦はグレゴリオ暦に固定する
    /// (「yyyy」が和暦の年にならないように)。
    static func dateString(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        // 翻訳者へ: 一括リネームの「名前と日付」で名前に入る日時の書式(Unicode の日付パターン)。`/` と `:` は使わない。
        formatter.dateFormat = String(localized: "yyyy-MM-dd 'at' h.mm.ss a", language: locale)
        return formatter.string(from: date)
    }

    private static func problem(with name: String) -> Problem? {
        do {
            _ = try FileNameValidation.validatedExactly(name)
        } catch let failure as FileNameValidation.Failure {
            return .invalid(failure)
        } catch {
            return nil
        }
        return name.hasPrefix(".") ? .leadingDot : nil
    }
}

/// 一括リネームのシートの入力。前回の値を次に開いたときにも出す(Finder も `com.apple.finder` の `BulkRename*` に残す)。
/// 方式ごとの欄は別々に覚える(方式を切り替えて戻っても打った文字が残る ―― Finder と同じ)。
nonisolated struct BulkRenameSettings: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case replaceText
        case addText
        case format
    }

    var kind: Kind = .replaceText
    var find = ""
    var replaceWith = ""
    var addedText = ""
    var addPlacement: BulkRename.Placement = .afterName
    var formatStyle: BulkRename.FormatStyle = .nameAndIndex
    /// nil = まだ一度も保存していない(表示言語の既定「ファイル 」を出す)。
    var customFormat: String?
    var formatPlacement: BulkRename.Placement = .afterName
    /// 開始番号の欄の文字(空は 1)。
    var startNumberText = "1"

    /// Finder の既定のカスタムフォーマット(末尾に空白。Finder の nib の文言表と同じ)。
    static func defaultCustomFormat(locale: Locale) -> String {
        String(localized: "File ", language: locale)
    }

    func mode(locale: Locale) -> BulkRename.Mode {
        switch kind {
        case .replaceText:
            return .replaceText(find: find, replaceWith: replaceWith)
        case .addText:
            return .addText(addedText, placement: addPlacement)
        case .format:
            return .format(
                style: formatStyle, customFormat: customFormat ?? Self.defaultCustomFormat(locale: locale),
                placement: formatPlacement, startNumber: startNumber
            )
        }
    }

    /// 開始番号(数字以外は捨て、空なら 1。Finder の欄と同じ)。
    var startNumber: Int {
        let digits = startNumberText.filter { $0.isASCII && $0.isNumber }
        return Int(digits.prefix(9)) ?? 1
    }
}

extension BulkRename.Problem {
    nonisolated func message(for name: String, locale: Locale = AppLanguage.currentLocale) -> String {
        switch self {
        case let .invalid(failure):
            return String(
                format: String(localized: "“%1$@” can’t be renamed: %2$@", language: locale),
                name, failure.localizedDescription
            )
        case .leadingDot:
            return String(
                format: String(localized: "“%@” can’t be renamed: names that begin with a dot “.” are reserved for the system.", language: locale),
                name
            )
        }
    }
}

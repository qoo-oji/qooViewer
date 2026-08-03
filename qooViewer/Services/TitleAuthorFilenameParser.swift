import Foundation

/// Apple Books互換性(ユーザー要望): EPUB出力時に、ファイル名/フォルダ名からタイトルと
/// 著者名を推測するためのパーサー。想定するパターン(改善要望.mdおよび追加要望より):
///
///   1. (任意の文字列) [著者名] タイトル (任意の文字列).拡張子
///   2. (任意の文字列) [著者名] タイトル (任意の文字列) [任意の文字列].拡張子
///   3. (任意の文字列) [著者名 (任意の文字列)] タイトル (任意の文字列) [任意の文字列].拡張子
///   4. (任意の文字列) [著者名] タイトル [任意の文字列].拡張子
///   5. [著者名] タイトル.拡張子
///   6. タイトル - 著者名.拡張子
///
/// フォルダ名も拡張子以外は同じ想定で扱ってよい(拡張子を渡さなければそのまま使える)。
///
/// 実装方針: 丸括弧"(...)"と角括弧"[...]"のトークン(いずれも入れ子は無い前提)を先頭から
/// 順に拾い、最初に現れる角括弧トークンを「著者名」とみなす。著者名トークンより前の部分
/// (先頭の任意の文字列トークンや前置テキスト)は破棄し、著者名トークンの直後から次の
/// トークン(丸括弧・角括弧いずれか)が現れるまでの間のテキストを「タイトル」とみなす。
/// それ以降(末尾の任意の文字列トークン)も破棄する。これにより、末尾の任意の文字列が
/// 丸括弧・角括弧のどちらであっても(パターン1〜4のいずれでも)同じロジックで対応できる。
///
/// 角括弧が1つも見つからない場合は、"タイトル - 著者名"の形式(ハイフン区切り、パターン6)を
/// 試す。どちらにも当てはまらない場合は、文字列全体をタイトルとし、著者名は空文字にする
/// (この場合、EPUB出力ウインドウ側で著者名欄は空のまま、ユーザーが手動で入力する想定)。
enum TitleAuthorFilenameParser {
    struct Result: Equatable {
        var title: String
        var author: String
    }

    private struct Token {
        enum Kind { case paren, bracket }
        let kind: Kind
        let content: String
        let range: Range<String.Index>
    }

    /// - Parameter baseName: 拡張子を除いたファイル名、またはフォルダ名。
    static func parse(baseName: String) -> Result {
        let trimmedInput = baseName.trimmingCharacters(in: .whitespaces)
        guard !trimmedInput.isEmpty else { return Result(title: "", author: "") }

        let tokens = findTokens(in: trimmedInput)

        if let authorTokenIndex = tokens.firstIndex(where: { $0.kind == .bracket }) {
            let authorToken = tokens[authorTokenIndex]
            let author = authorToken.content.trimmingCharacters(in: .whitespaces)

            let titleStart = authorToken.range.upperBound
            let titleEnd = tokens[(authorTokenIndex + 1)...].first?.range.lowerBound ?? trimmedInput.endIndex
            let rawTitle = titleStart <= titleEnd ? String(trimmedInput[titleStart..<titleEnd]) : ""
            let title = sanitizeTitle(rawTitle)
            if !title.isEmpty {
                return Result(title: title, author: author)
            }
        }

        // 角括弧が無い、または角括弧の直後にタイトルが見当たらない場合は、
        // "タイトル - 著者名"の形式(パターン6)を試す。
        if let dashResult = parseDashSeparated(trimmedInput) {
            return dashResult
        }

        return Result(title: trimmedInput, author: "")
    }

    /// 丸括弧・角括弧のトークンを、入れ子は無い前提で先頭から順に拾う。
    private static func findTokens(in text: String) -> [Token] {
        guard let regex = try? NSRegularExpression(pattern: "\\([^()]*\\)|\\[[^\\[\\]]*\\]") else { return [] }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        var tokens: [Token] = []
        regex.enumerateMatches(in: text, range: nsrange) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            let matched = String(text[range])
            let kind: Token.Kind = matched.hasPrefix("[") ? .bracket : .paren
            let inner = String(matched.dropFirst().dropLast())
            tokens.append(Token(kind: kind, content: inner, range: range))
        }
        return tokens
    }

    /// タイトル候補の前後に残りがちな区切り記号(ハイフン・アンダースコア・空白)を除去する。
    private static func sanitizeTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespaces)
        let stripped = CharacterSet(charactersIn: "-_ 　")
        while let first = title.unicodeScalars.first, stripped.contains(first) {
            title.removeFirst()
        }
        while let last = title.unicodeScalars.last, stripped.contains(last) {
            title.removeLast()
        }
        return title
    }

    /// "タイトル - 著者名"形式(パターン6)。タイトル側は非貪欲にマッチさせ、
    /// 最初に現れる" - "区切りで分割する。
    private static func parseDashSeparated(_ text: String) -> Result? {
        guard let regex = try? NSRegularExpression(pattern: "^(.+?)\\s+-\\s+(.+)$") else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsrange),
              let titleRange = Range(match.range(at: 1), in: text),
              let authorRange = Range(match.range(at: 2), in: text)
        else { return nil }
        let title = String(text[titleRange]).trimmingCharacters(in: .whitespaces)
        let author = String(text[authorRange]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !author.isEmpty else { return nil }
        return Result(title: title, author: author)
    }
}

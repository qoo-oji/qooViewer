import Foundation

/// メタデータ推測用の3種類のルール(MetadataFilenameFormat / VolumeFormatRule /
/// MetadataExclusionRule)を、実際の照合に使うNSRegularExpressionへ変換する。
///
/// ルールはユーザーが編集ダイアログで自由に書き換えられる一方、実際の照合は
/// 「メタデータの編集」ウインドウの一覧(数百〜数千行になりうる)で全行に対して走る。
/// そのため、ルールの文字列を毎回コンパイルし直すのではなく、ルールが変わったときに一度だけ
/// CompiledMetadataRuleSetへまとめてコンパイルし、それを使い回す
/// (MetadataFormatStore.compiledRules参照)。
///
/// nonisolated: BookMetadataDeriverと同じくメインアクター外から呼ばれうるため、
/// Xcode 26既定のMainActor自動分離の対象外にしている(ArchiveReading.swift冒頭のコメント参照)。
nonisolated enum MetadataFormatCompiler {

    // MARK: - ファイル名フォーマット

    /// ファイル名フォーマットで使える予約語。`@`で始まる固定の3語のみで、ユーザーが増やすことは
    /// できない(増やせるようにすると、フォーマット中に素の`@`を書きたい場合のエスケープ規則を
    /// 決める必要が出てくるため。現状は「3語のいずれにも当てはまらない`@`はただの文字」という
    /// 単純な規則で済ませている)。
    private enum Keyword: String, CaseIterable {
        case author = "@author"
        case title = "@title"
        case ignore = "@ignore"
    }

    /// コンパイル済みのファイル名フォーマット1件。
    ///
    /// authorGroupIndex/titleGroupIndexは、生成した正規表現の中で何番目のキャプチャグループが
    /// 著者名/タイトルに対応するかを表す。名前付きキャプチャ`(?<author>…)`を使わないのは、
    /// ユーザーが同じ予約語を1つのフォーマット内に2回書いた場合に「同じ名前のグループが重複」で
    /// コンパイル自体が失敗してしまうため(番号で持てば、2回目以降を単に無視できる)。
    /// 予約語が1つも無いフォーマットではnilになり、その欄は空文字として扱われる。
    ///
    /// @unchecked Sendable: 保持しているNSRegularExpressionはコンパイル後に変更されず、
    /// Appleのドキュメント上もスレッドセーフ(複数スレッドから同時にマッチングを実行してよい)と
    /// 明記されているため。値型自身が持つ他のプロパティはIntのみ。
    struct CompiledFilenameFormat: @unchecked Sendable {
        let regex: NSRegularExpression
        let authorGroupIndex: Int?
        let titleGroupIndex: Int?
    }

    /// `(@ignore) [@author] @title`のようなフォーマットを、ファイル名全体と照合するための
    /// 正規表現へ変換する。変換規則は以下のとおり。
    ///
    /// - `@author` / `@title` → `(.+?)`(1文字以上、非貪欲。前後のリテラルが境界になる)
    /// - `@ignore` → `(?:.*?)`(0文字以上、非貪欲。キャプチャしない)
    /// - フォーマット中の連続する空白 → `\s*`(0文字以上の空白)
    /// - それ以外の文字 → 正規表現としてエスケープしたリテラル
    /// - 全体を`^\s*`…`\s*$`で挟み、ファイル名全体との完全一致とする
    ///
    /// 空白を`\s*`(0文字以上)にしているのは、除外文字列を削った跡に余分な空白が残ったり
    /// 逆に空白が消えたりしても照合できるようにするため(ユーザー選択: 「空白に寛容」)。
    /// これにより`(2023) [作者] タイトル`から`(2023)`を削った` [作者] タイトル`が、
    /// `[@author] @title`と問題なく一致する。
    ///
    /// 予約語を1つも含まないフォーマットや、正規表現としてコンパイルできない結果になった
    /// フォーマットはnilを返す(呼び出し側はそのフォーマットを単に使わない)。
    static func compile(filenameFormat pattern: String) -> CompiledFilenameFormat? {
        var regexSource = "^\\s*"
        var nextGroupIndex = 1
        var authorGroupIndex: Int?
        var titleGroupIndex: Int?
        var pendingLiteral = ""

        /// 直前まで溜めていたリテラルを、空白の連なりだけ`\s*`に置き換えつつ書き出す。
        func flushLiteral() {
            guard !pendingLiteral.isEmpty else { return }
            var run = ""
            var isWhitespaceRun = false
            /// 同じ種類(空白/非空白)の連なりを1つの単位として書き出す。
            func flushRun() {
                guard !run.isEmpty else { return }
                regexSource += isWhitespaceRun ? "\\s*" : NSRegularExpression.escapedPattern(for: run)
                run = ""
            }
            for character in pendingLiteral {
                let isWhitespace = character.isWhitespace
                if !run.isEmpty && isWhitespace != isWhitespaceRun { flushRun() }
                isWhitespaceRun = isWhitespace
                run.append(character)
            }
            flushRun()
            pendingLiteral = ""
        }

        var index = pattern.startIndex
        while index < pattern.endIndex {
            guard pattern[index] == "@",
                  let keyword = Keyword.allCases.first(where: { pattern[index...].hasPrefix($0.rawValue) })
            else {
                pendingLiteral.append(pattern[index])
                index = pattern.index(after: index)
                continue
            }
            flushLiteral()
            switch keyword {
            case .author:
                regexSource += "(.+?)"
                if authorGroupIndex == nil { authorGroupIndex = nextGroupIndex }
                nextGroupIndex += 1
            case .title:
                regexSource += "(.+?)"
                if titleGroupIndex == nil { titleGroupIndex = nextGroupIndex }
                nextGroupIndex += 1
            case .ignore:
                regexSource += "(?:.*?)"
            }
            index = pattern.index(index, offsetBy: keyword.rawValue.count)
        }
        flushLiteral()
        regexSource += "\\s*$"

        guard authorGroupIndex != nil || titleGroupIndex != nil,
              let regex = try? NSRegularExpression(pattern: regexSource)
        else { return nil }
        return CompiledFilenameFormat(
            regex: regex, authorGroupIndex: authorGroupIndex, titleGroupIndex: titleGroupIndex
        )
    }

    // MARK: - 巻数フォーマット

    /// コンパイル済みの巻数フォーマット1件。regexは「タイトルの末尾に一致するか」を判定する
    /// ための形(元のパターンを`(?:…)\s*$`で包んだもの)になっている。
    /// @unchecked Sendableの理由はCompiledFilenameFormatと同じ。
    struct CompiledVolumeRule: @unchecked Sendable {
        let regex: NSRegularExpression
        let kind: VolumeFormatRuleKind
    }

    /// 巻数フォーマットを、タイトルの末尾と照合するための正規表現へ変換する。
    ///
    /// 元のパターンを`(?:…)`で包んでから`\s*$`を付ける。包むのは、`上巻|下巻`のように
    /// 全体が選択肢になっているパターンを書かれた場合に、末尾アンカーが最後の選択肢だけに
    /// かかってしまうのを防ぐため(キャプチャしないグループなので、ユーザーが書いた
    /// キャプチャグループの番号はずれない)。
    static func compile(volumeRule rule: VolumeFormatRule) -> CompiledVolumeRule? {
        guard !rule.pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: "(?:\(rule.pattern))\\s*$")
        else { return nil }
        return CompiledVolumeRule(regex: regex, kind: rule.kind)
    }

    // MARK: - 除外文字列

    /// 除外文字列(正規表現)をそのままコンパイルする。空パターンは「すべての位置に一致する」
    /// という危険な挙動になるため除外する。
    /// 戻り値の@unchecked Sendableな包みが不要なのは、呼び出し側(CompiledMetadataRuleSet)が
    /// まとめて包んでいるため。
    static func compile(exclusionRule rule: MetadataExclusionRule) -> NSRegularExpression? {
        guard !rule.pattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: rule.pattern)
    }

    // MARK: - 妥当性チェック(編集ダイアログ用)

    /// 編集ダイアログが「この正規表現は無効です」という印を出すための判定。
    /// 空文字は「まだ書きかけ」として無効扱いにする。
    static func isValidRegularExpression(_ pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        return (try? NSRegularExpression(pattern: pattern)) != nil
    }

    /// ファイル名フォーマットが有効か(予約語を少なくとも1つ含み、正規表現へ変換できるか)。
    static func isValidFilenameFormat(_ pattern: String) -> Bool {
        compile(filenameFormat: pattern) != nil
    }
}

/// 3種類のルールをまとめてコンパイルした結果。BookMetadataDeriverはこれ1つを受け取って
/// 動く(個々のルール配列を持ち回らずに済み、コンパイル結果の使い回しも自然に効く)。
///
/// @unchecked Sendable: 保持しているのはコンパイル済みで不変な正規表現のみ
/// (詳細はCompiledFilenameFormatのコメント参照)。
nonisolated struct CompiledMetadataRuleSet: @unchecked Sendable {
    let filenameFormats: [MetadataFormatCompiler.CompiledFilenameFormat]
    let volumeRules: [MetadataFormatCompiler.CompiledVolumeRule]
    let exclusionRules: [NSRegularExpression]

    /// コンパイルに失敗したルール(正規表現として不正、予約語が無い等)は単純に取り除く。
    /// ユーザーが編集途中の不正なパターンを保存していても、他のルールによる推測は
    /// 動き続けるようにするため(編集ダイアログ側では別途、不正なパターンに印を出す)。
    init(
        filenameFormats: [MetadataFilenameFormat],
        volumeRules: [VolumeFormatRule],
        exclusionRules: [MetadataExclusionRule]
    ) {
        self.filenameFormats = filenameFormats.compactMap { MetadataFormatCompiler.compile(filenameFormat: $0.pattern) }
        self.volumeRules = volumeRules.compactMap { MetadataFormatCompiler.compile(volumeRule: $0) }
        self.exclusionRules = exclusionRules.compactMap { MetadataFormatCompiler.compile(exclusionRule: $0) }
    }
}

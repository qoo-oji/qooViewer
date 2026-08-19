import Foundation

/// ファイル名から機械的に推測した書誌メタデータ。DBに登録される前(未登録状態)の
/// 「メタデータの編集」ウインドウの各行に、初期値として表示される内容そのもの。
nonisolated struct DerivedBookMetadata: Equatable, Sendable {
    var author: String = ""
    var title: String = ""
    var series: String = ""
    var seriesIndex: String = ""
}

/// 拡張子を除いたファイル名(またはフォルダ名)から、著者・タイトル・シリーズ・巻数を
/// 機械的に推測する。ユーザー要望の手順をそのまま実装したもの:
///
///   1. 除外文字列(MetadataExclusionRule)に一致する部分をノイズとして削る
///   2. 残った文字列をファイル名フォーマット(MetadataFilenameFormat)と上から順に照合し、
///      最初に一致したもので著者とタイトルを決める
///   3. タイトルの末尾を巻数フォーマット(VolumeFormatRule)と照合し、
///      シリーズ名と巻数に分離する
///
/// どのフォーマットにも当てはまらなかった場合は、著者を空欄にし、ノイズを削った文字列
/// 全体をタイトルとして扱う(既存のTitleAuthorFilenameParserの最終フォールバックと同じ方針)。
///
/// nonisolated: 「メタデータの編集」ウインドウが数千件の行をまとめて処理する際、
/// メインアクター外へ逃がして実行できるようにするため
/// (ArchiveReading.swift冒頭のコメント参照)。
nonisolated enum BookMetadataDeriver {

    /// - Parameter baseName: 拡張子を除いたファイル名、またはフォルダ名。
    static func derive(baseName: String, rules: CompiledMetadataRuleSet) -> DerivedBookMetadata {
        let cleaned = removingExclusions(from: baseName, rules: rules)
        let (author, title) = extractAuthorAndTitle(from: cleaned, rules: rules)
        let (series, seriesIndex) = splitSeriesAndVolume(title: title, rules: rules)
        return DerivedBookMetadata(author: author, title: title, series: series, seriesIndex: seriesIndex)
    }

    // MARK: - 1. 除外文字列によるノイズ除去

    /// 除外文字列に一致する部分をすべて取り除く。取り除いた跡に余分な空白が残ることは
    /// 意図的に許容している(ファイル名フォーマット側が、空白を「0文字以上の空白」として
    /// 照合するようコンパイルされているため。MetadataFormatCompiler.compile(filenameFormat:)参照)。
    static func removingExclusions(from text: String, rules: CompiledMetadataRuleSet) -> String {
        var result = text
        for regex in rules.exclusionRules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result
    }

    // MARK: - 2. ファイル名フォーマットによる著者・タイトルの抽出

    /// フォーマットをリストの上から順に照合し、最初に一致したものを採用する
    /// (タイトルが空になる一致は「一致しなかった」ものとして次のフォーマットへ進む。
    /// タイトルの無いメタデータには意味が無く、より緩いフォーマットで拾い直す余地を
    /// 残したほうが結果が良くなるため)。
    private static func extractAuthorAndTitle(
        from text: String, rules: CompiledMetadataRuleSet
    ) -> (author: String, title: String) {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        for format in rules.filenameFormats {
            guard let match = format.regex.firstMatch(in: text, range: fullRange) else { continue }
            let author = capturedText(match, at: format.authorGroupIndex, in: nsText)
            let title = capturedText(match, at: format.titleGroupIndex, in: nsText)
            guard !title.isEmpty else { continue }
            return (author, title)
        }
        return ("", text.trimmingCharacters(in: .whitespaces))
    }

    /// キャプチャグループの中身を、前後の空白を落として取り出す。グループが存在しない
    /// (そのフォーマットにその予約語が書かれていない)場合や、一致しなかった場合は空文字。
    private static func capturedText(
        _ match: NSTextCheckingResult, at groupIndex: Int?, in nsText: NSString
    ) -> String {
        guard let groupIndex, groupIndex < match.numberOfRanges else { return "" }
        let range = match.range(at: groupIndex)
        guard range.location != NSNotFound else { return "" }
        return nsText.substring(with: range).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 3. 巻数フォーマットによるシリーズ名・巻数の分離

    /// タイトルの末尾が巻数フォーマットに一致する場合に、その手前までをシリーズ名、
    /// 一致部分から取り出した数字を巻数として返す。
    ///
    /// 末尾に一致するフォーマットが1件も無ければ、シリーズ名・巻数はどちらも空文字を返す
    /// (ユーザー要望: 「巻数に一致する文字列が末尾になかった場合、シリーズの欄は空欄となる」)。
    /// これは「1冊完結の本にはシリーズという概念が無い」という考え方に沿った挙動で、
    /// タイトルがそのままシリーズ名になることは無い。
    ///
    /// kindが.seriesSeparatorOnlyのフォーマットに一致した場合は、シリーズ名の分離だけを行い、
    /// 巻数欄は空文字のままにする(ユーザー選択。`総集編([0-9０-９]+)`のようにキャプチャ
    /// グループを持つフォーマットであっても、巻数としては扱わない)。
    static func splitSeriesAndVolume(
        title: String, rules: CompiledMetadataRuleSet
    ) -> (series: String, seriesIndex: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return ("", "") }

        let nsTitle = trimmedTitle as NSString
        let fullRange = NSRange(location: 0, length: nsTitle.length)

        for rule in rules.volumeRules {
            guard let match = rule.regex.firstMatch(in: trimmedTitle, range: fullRange) else { continue }
            let series = nsTitle.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
            guard rule.kind == .volumeNumber else { return (series, "") }
            return (series, volumeNumber(from: match, in: nsTitle))
        }
        return ("", "")
    }

    /// 一致部分の最初のキャプチャグループから巻数の数字を取り出し、全角数字を半角へ正規化する。
    /// キャプチャグループが書かれていないフォーマットでも動くよう、グループが無い場合は
    /// 一致部分全体から数字だけを拾うフォールバックを持たせている。
    private static func volumeNumber(from match: NSTextCheckingResult, in nsTitle: NSString) -> String {
        if match.numberOfRanges > 1 {
            let range = match.range(at: 1)
            if range.location != NSNotFound {
                return normalizingFullwidthDigits(nsTitle.substring(with: range))
            }
        }
        let matched = normalizingFullwidthDigits(nsTitle.substring(with: match.range))
        return String(matched.filter(\.isNumber))
    }

    /// 全角数字(U+FF10〜U+FF19)を半角数字へ変換する(ユーザー要望)。
    ///
    /// Foundationの`applyingTransform(.fullwidthToHalfwidth)`は数字以外(カタカナ・記号など)まで
    /// 一括で変換してしまい、巻数以外の文字が混ざった文字列では意図しない変換が起きるため、
    /// 数字だけを対象にした最小限の変換を自前で行う。
    static func normalizingFullwidthDigits(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value >= 0xFF10 && $0.value <= 0xFF19 }) else {
            return text
        }
        var result = ""
        result.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if scalar.value >= 0xFF10, scalar.value <= 0xFF19,
               let halfwidth = Unicode.Scalar(scalar.value - 0xFF10 + 0x30) {
                result.unicodeScalars.append(halfwidth)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

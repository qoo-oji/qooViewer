import Foundation

/// トースト(ビューア・ファイルブラウザ・ホーム・サイドパネル・メタデータの編集ウインドウに出る短い知らせ)を出しておく時間。
///
/// ■ 文の長さから決める(2026-10-18、利用者の指摘「文章の長さに対して表示時間が短すぎる」)
/// 以前は一律 2 秒で、日本語ならおよそ 6 字しか読めなかった(長い知らせは 86 字あった)。トーストは予告なしに出るので、
/// 気づいて目を向けるまでの `noticeLead` に、読む時間を足す。読む速さは、日本語の黙読の目安(毎分 400〜600 字)と映像字幕の
/// 慣例(1 秒 4 字)の間をとって 1 秒 6 字。英字・数字のような幅の狭い文字は 1 秒 15 字(英語の字幕の目安)で数える ――
/// 日本語の文に混じる「StackNest」も英語の文も、同じ式で数えられる。読み終える前に消えないよう長めに見積もり、それでも
/// 知らせが画面を長く塞がないよう `maximum` で止める(それを超える文は、文そのものを短くする)。
nonisolated enum ToastDuration {
    /// 気づいて目を向けるまで。
    static let noticeLead: Double = 1
    /// 漢字・かな・全角の記号などを 1 秒に読む字数。
    static let wideCharactersPerSecond: Double = 6
    /// 英字・数字・半角の記号を 1 秒に読む字数。
    static let narrowCharactersPerSecond: Double = 15
    static let minimum: Duration = .milliseconds(2500)
    static let maximum: Duration = .seconds(10)

    /// `message` を出しておく時間。空白は数えない。
    static func duration(for message: String) -> Duration {
        var seconds = noticeLead
        for character in message where !character.isWhitespace {
            seconds += 1 / (isNarrow(character) ? narrowCharactersPerSecond : wideCharactersPerSecond)
        }
        let duration = Duration.milliseconds(Int((seconds * 1000).rounded()))
        return min(max(duration, minimum), maximum)
    }

    /// 幅の狭い文字か(ラテン文字とその記号 ―― U+02FF まで)。
    private static func isNarrow(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { $0.value <= 0x02FF } ?? true
    }
}

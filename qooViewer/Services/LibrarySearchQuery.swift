import Foundation

/// ウェルカム画面の検索欄に打たれた文字列を、照合できる形にしたもの(ユーザー要望 2026-09-13)。
///
/// ■ 照合の規則
/// - **空白で区切った語をすべて含むもの**(AND)が一致する。語の順番は問わない。全角の空白も
///   区切りとして扱う(日本語入力のまま空白を打つと全角になる)
/// - 大文字小文字・全角半角(`ＡＢＣ`と`abc`、`ﾊﾟﾝ`と`パン`)は区別しない
/// - **濁点・半濁点は区別する。** `.diacriticInsensitive`を使うと「が」と「か」が同じになるうえ、
///   半角カナの`ﾊﾟ`が`ハﾟ`という壊れた文字列になる(実測 2026-09-13)。欧文のアクセント記号を
///   畳めない代わりに、日本語の本の名前で誤って一致しないほうを取った
/// - Unicodeの正規化(NFC)を揃える。フォルダの本の名前はAPFSからNFDで返ってくることがあり、
///   打ち込んだ文字列(NFC)と素の比較では一致しない(KnownBooks.matchKeyと同じ事情)
///
/// 照合する側の文字列(本の名前・メタデータ)も必ず`normalized(_:)`を通すこと ―― 片側だけ
/// 畳むと一致しなくなる。
///
/// nonisolated: 状態を持たない値で、どこから使ってもよい(テストもメインアクター外から呼べる)。
nonisolated struct LibrarySearchQuery: Equatable, Sendable {
    /// 正規化済みの語(空ではない)。
    let terms: [String]

    /// 空欄・空白だけならnil(= 絞り込まない)。
    init?(_ text: String) {
        let terms = Self.normalized(text)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return nil }
        self.terms = terms
    }

    /// 照合用に文字列を畳む(型コメントの規則)。
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    /// 正規化済みの文字列が、すべての語を含むか。
    func matches(normalized haystack: String) -> Bool {
        terms.allSatisfy { haystack.contains($0) }
    }
}

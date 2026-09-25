import Foundation

/// 読み方向。
/// - rightToLeft: 右開き(日本の漫画の標準。ページは右から左へ進む)
/// - leftToRight: 左開き(欧米コミックの標準)
enum ReadingDirection: String, CaseIterable, Identifiable {
    case rightToLeft = "Right-to-Left"
    case leftToRight = "Left-to-Right"

    var id: String { rawValue }
}

/// 環境設定「本を開く」の「読み方向の既定」。初めて開く本(と、本ごとの読み方向を持たない本の書き出し・
/// レイアウト編集)に使う読み方向を決める。
///
/// 以前は環境設定の画面に項目が無く、初回起動時にシステムの言語から一度だけ決めた値
/// (`AppPreferences.Keys.retiredDefaultReadingDirection`)を使い続けていた。表示言語を切り替えても既定が
/// 変わらず、項目も見当たらないと利用者に指摘されて(2026-09-25)、表示言語に合わせる選択肢を既定にして
/// 画面に出した。
enum DefaultReadingDirection: String, CaseIterable, Identifiable {
    /// 表示言語(`AppPreferences.displayLanguage`。「システムに従う」ならシステムの言語)が日本語なら右開き、
    /// それ以外なら左開き。表示言語を切り替えればその場で変わる。
    case followLanguage
    case rightToLeft
    case leftToRight

    var id: String { rawValue }

    /// この設定が、表示言語 `locale` のときに実際に使う読み方向。
    func resolved(for locale: Locale) -> ReadingDirection {
        switch self {
        case .followLanguage:
            return locale.language.languageCode?.identifier == "ja" ? .rightToLeft : .leftToRight
        case .rightToLeft:
            return .rightToLeft
        case .leftToRight:
            return .leftToRight
        }
    }
}

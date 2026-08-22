import SwiftUI

/// ページ一覧(サムネイルグリッド)で、サムネイルの下に何を書くか(ユーザー要望)。
///
/// 従来はページ番号を出す一択だった。ファイル名で管理している本では番号より
/// ファイル名のほうが手掛かりになる一方、サムネイルを小さくして一覧性を上げたい場合は
/// 文字そのものが邪魔になるため、3択にしてある。
///
/// rawValueはケース名(永続化用の安定した識別子)。
enum ThumbnailCaptionStyle: String, CaseIterable, Identifiable, Codable, Hashable {
    /// ページ番号(1始まり)。従来の唯一の表示で、既定値でもある。
    case pageNumber
    /// そのページの元のファイル名(PageRef.displayName)。
    case fileName
    /// 何も書かない。サムネイルだけが縦横に詰まって並ぶ。
    case none

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .pageNumber: return "Page Number"
        case .fileName: return "File Name"
        case .none: return "Nothing"
        }
    }
}

/// 「表示中のページを示す枠」の色(ユーザー要望: 自由に設定できるようにしてほしい)。
///
/// 背景色(`BackgroundColorOption`)とまったく同じ作りにしてある ―― よく使う色は
/// プリセットから選び、それ以外は`.custom`で指定し、実際のRGB値は
/// `AppPreferences.thumbnailGridCurrentPageBorderCustomColor`が別に持つ。
///
/// `.accent`だけは他と性質が違い、**固定の色を持たない**。macOSのシステム設定
/// 「強調表示の色」に追従する動的な色で、これが従来の(そして今も)既定値である。
enum PageBorderColorOption: String, CaseIterable, Identifiable, Codable, Hashable {
    /// システムのアクセントカラー(従来からの既定)。
    case accent
    case red
    case yellow
    case green
    case white
    case black
    case custom

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .accent: return "Accent Color"
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .white: return "White"
        case .black: return "Black"
        case .custom: return "Custom"
        }
    }

    /// プリセットが表す色。`.accent`(システム追従のため固定値を持たない)と
    /// `.custom`(実際のRGB値はAppPreferences側にある)だけはnilを返す。
    ///
    /// `BackgroundColorOption.presetColor`と同じく、呼び出し側がうっかり適当な色へ
    /// フォールバックしてしまわないようOptionalにしてある。実際に枠を描くときは、
    /// 3つとも解決済みの`AppPreferences.effectiveCurrentPageBorderColor`を使うこと。
    var presetColor: Color? {
        switch self {
        case .accent, .custom: return nil
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .white: return .white
        case .black: return .black
        }
    }
}

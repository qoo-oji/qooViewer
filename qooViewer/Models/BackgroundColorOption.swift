import SwiftUI

/// ビューワーの背景色。任意のRGBカラーピッカーではなく、実装をシンプルかつ安全に保つため
/// あらかじめ用意したプリセットから選ぶ形にしている。
/// rawValueはケース名(永続化用の安定した識別子)、titleKeyが画面表示用のローカライズされた名前。
enum BackgroundColorOption: String, CaseIterable, Identifiable, Codable, Hashable {
    case black
    case darkGray
    case white
    case sepia

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .black: return "Black"
        case .darkGray: return "Dark Gray"
        case .white: return "White"
        case .sepia: return "Sepia"
        }
    }

    var color: Color {
        switch self {
        case .black: return .black
        case .darkGray: return Color(white: 0.15)
        case .white: return .white
        case .sepia: return Color(red: 0.94, green: 0.90, blue: 0.82)
        }
    }
}

import SwiftUI

/// ビューワーの背景色。よく使う色はあらかじめ用意したプリセットから選び、それ以外の色は
/// `.custom`(実際のRGB値は`AppPreferences.customBackgroundColor`に別途保存され、環境設定
/// 「外観」の「ビューア」→「背景色」で「カスタム」を選び、専用のダイアログで指定する)で指定する。
/// rawValueはケース名(永続化用の安定した識別子)、titleKeyが画面表示用のローカライズされた名前。
enum BackgroundColorOption: String, CaseIterable, Identifiable, Codable, Hashable {
    case black
    case darkGray
    case white
    case sepia
    case custom

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .black: return "Black"
        case .darkGray: return "Dark Gray"
        case .white: return "White"
        case .sepia: return "Sepia"
        case .custom: return "Custom"
        }
    }

    /// プリセットが表す色。`.custom`だけは色の実体をこのenumが持っていない
    /// (ユーザーが指定したRGB値はAppPreferences側にある)ためnilを返す。
    ///
    /// 呼び出し側がうっかり`.custom`のときに適当な色へフォールバックしてしまわないよう、
    /// あえてOptionalにしてある。実際に背景を塗るときは、この2つを解決済みの
    /// `AppPreferences.effectiveBackgroundColor`を使うこと。
    var presetColor: Color? {
        switch self {
        case .black: return .black
        case .darkGray: return Color(white: 0.15)
        case .white: return .white
        case .sepia: return Color(red: 0.94, green: 0.90, blue: 0.82)
        case .custom: return nil
        }
    }
}

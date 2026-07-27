import SwiftUI

/// アプリの表示言語。「システムに従う」を選ぶと、macOS本体の言語設定に従う(既定)。
/// それ以外を選ぶと、macOS本体の言語設定にかかわらず常にその言語で表示する。
enum AppLanguage: String, CaseIterable, Identifiable, Codable, Hashable {
    case system
    case japanese
    case english

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .system: return "Follow System"
        case .japanese: return "Japanese"
        case .english: return "English"
        }
    }

    /// この設定が実際に対応する Locale。「システムに従う」の場合は nil を返す
    /// (呼び出し側は nil のとき Locale.autoupdatingCurrent 等、システムのロケールをそのまま使う)。
    var localeOverride: Locale? {
        switch self {
        case .system: return nil
        case .japanese: return Locale(identifier: "ja")
        case .english: return Locale(identifier: "en")
        }
    }
}

import Foundation

/// ページ表示モード
enum DisplayMode: String, CaseIterable, Identifiable {
    case single = "単ページ"
    case spread = "見開き"

    var id: String { rawValue }
}

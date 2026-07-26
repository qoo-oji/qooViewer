import Foundation

/// 読み方向。
/// - rightToLeft: 右開き(日本の漫画の標準。ページは右から左へ進む)
/// - leftToRight: 左開き(欧米コミックの標準)
enum ReadingDirection: String, CaseIterable, Identifiable {
    case rightToLeft = "Right-to-Left"
    case leftToRight = "Left-to-Right"

    var id: String { rawValue }
}

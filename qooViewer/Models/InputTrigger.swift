import SwiftUI

/// マウスで割り当てられる操作のトリガー(cooViewerの「マウス設定」に相当する部分を簡略化したもの)。
/// 画面のクリック位置(左半分/右半分)とホイールの上下方向をそれぞれ操作に割り当てられる。
enum InputTrigger: String, CaseIterable, Codable, Hashable {
    case clickLeftZone
    case clickRightZone
    case wheelUp
    case wheelDown

    var titleKey: LocalizedStringKey {
        switch self {
        case .clickLeftZone: return "Click Left Side of Screen"
        case .clickRightZone: return "Click Right Side of Screen"
        case .wheelUp: return "Scroll Wheel Up"
        case .wheelDown: return "Scroll Wheel Down"
        }
    }
}

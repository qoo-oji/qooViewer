import SwiftUI

/// ページ画像をウインドウに対してどう拡大縮小して表示するか
/// rawValueはケース名(永続化用の安定した識別子)、titleKeyが画面表示用のローカライズされた名前。
enum ScalingMode: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 画面内に収める(縦横とも画面に収まるように拡大縮小。cooViewerの「画面内に収める」相当)
    case fitToScreen
    /// 横幅に合わせる(横幅基準で拡大縮小し、縦が画面より長ければ縦スクロール)
    case fitWidth
    /// 拡大縮小しない(原寸のまま表示し、縦横ともスクロール)
    case noScale

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .fitToScreen: return "Fit to Screen"
        case .fitWidth: return "Fit Width"
        case .noScale: return "No Scaling"
        }
    }

    /// ツールバーのボタンでモードを一つずつ切り替えるための「次のモード」
    var next: ScalingMode {
        switch self {
        case .fitToScreen: return .fitWidth
        case .fitWidth: return .noScale
        case .noScale: return .fitToScreen
        }
    }
}

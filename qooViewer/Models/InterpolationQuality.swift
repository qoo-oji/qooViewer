import SwiftUI

/// 画像を拡大縮小して表示するときの補間(なめらかさ)の品質
/// rawValueはケース名(永続化用の安定した識別子)、titleKeyが画面表示用のローカライズされた名前。
enum InterpolationQuality: String, CaseIterable, Identifiable, Codable, Hashable {
    case high
    case defaultQuality
    case low

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .high: return "High Quality"
        case .defaultQuality: return "Standard"
        case .low: return "Low Quality (Lightweight)"
        }
    }

    var swiftUIInterpolation: Image.Interpolation {
        switch self {
        case .high: return .high
        case .defaultQuality: return .medium
        case .low: return .low
        }
    }
}

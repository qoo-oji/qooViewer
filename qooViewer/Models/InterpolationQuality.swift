import SwiftUI

/// 画像を拡大縮小して表示するときの補間(なめらかさ)の品質
/// rawValueはケース名(永続化用の安定した識別子)、titleKeyが画面表示用のローカライズされた名前。
///
/// 以前は「低画質(軽量)」(`low`、`Image.Interpolation.low`)もあったが廃止した。macOSでは
/// SwiftUIの`.medium`と`.low`はどちらもCALayerの`linear`(バイリニア)になり、描画が**完全に
/// 同じ**だった(NSHostingViewのレイヤーツリーを実測して確認。`.high`は`box`=面積平均、
/// `.none`は`nearest`)。同じ結果の選択肢を2つ並べる意味が無いので「標準」に統合した。
/// 保存済みの"low"は読み込み時に`defaultQuality`へ読み替える(init(storedRawValue:)参照)。
enum InterpolationQuality: String, CaseIterable, Identifiable, Codable, Hashable {
    case high
    case defaultQuality

    var id: String { rawValue }

    /// UserDefaultsに保存されたrawValueから復元する。廃止した"low"は、見た目が同一だった
    /// `defaultQuality`へ読み替える(以前その設定にしていた人の描画を変えないため)。
    /// それ以外の未知の値・未設定はnil(呼び出し側が既定値を入れる)。
    init?(storedRawValue: String?) {
        guard let storedRawValue else { return nil }
        if storedRawValue == "low" {
            self = .defaultQuality
            return
        }
        self.init(rawValue: storedRawValue)
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .high: return "High Quality"
        case .defaultQuality: return "Standard"
        }
    }

    var swiftUIInterpolation: Image.Interpolation {
        switch self {
        case .high: return .high
        case .defaultQuality: return .medium
        }
    }
}

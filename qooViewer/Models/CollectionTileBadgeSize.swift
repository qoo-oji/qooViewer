import SwiftUI

/// コレクションの札の右下に出す冊数バッジの大きさ(ユーザー要望 2026-09-13。環境設定「外観」→
/// 「ウェルカム画面」→「ライブラリ」)。
///
/// 無段階のスライダーではなく3段にしてあるのは、要望が「3段階程度でよい」だったのと、バッジは
/// 文字・余白・縁の太さを**一緒に**変えないと形が崩れるため(文字だけ大きくすると、余白の
/// 詰まった窮屈なカプセルになる)。段ごとの寸法はここ1箇所に置く。
///
/// **既定は`.small`** ―― 設定にする前の見た目(`.caption` = 10pt、余白 横6pt・縦2pt)そのもの。
/// 既定値のままなら、足した縁を除いて見た目は変わらない。
///
/// rawValueはケース名(永続化用の安定した識別子)。
enum CollectionTileBadgeSize: String, CaseIterable, Identifiable, Codable, Hashable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// 数字の大きさ(pt)。`.small`の10ptは、以前使っていた`.caption`の実寸。
    var fontSize: CGFloat {
        switch self {
        case .small: return 10
        case .medium: return 13
        case .large: return 16
        }
    }

    /// カプセルの内側の余白。文字の大きさに比例させる(小さい段の比率を保つ)。
    var horizontalPadding: CGFloat { (fontSize * 0.6).rounded() }
    var verticalPadding: CGFloat { (fontSize * 0.2).rounded() }

    /// 縁の太さ(pt)。大きい段で細いままだと、縁が見えなくなる。
    var borderWidth: CGFloat {
        switch self {
        case .small: return 1
        case .medium: return 1.25
        case .large: return 1.5
        }
    }
}

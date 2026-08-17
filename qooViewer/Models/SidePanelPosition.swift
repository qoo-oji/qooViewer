import SwiftUI

/// サイドパネルをウインドウのどちら側に表示するか(ユーザー要望: 左だけでなく右にも置けるように
/// する)。常時表示(「サイドパネルを隠す」OFF)・ホバーでの一時表示(同ON)のどちらにも同じ値が
/// 効く。アプリ全体で1つの設定として持つ(AppPreferences.sidePanelPosition参照)。
///
/// SwiftUIのleading/trailingはUIの言語(レイアウト方向)に応じて左右が入れ替わる相対的な指定だが、
/// 本アプリのUIは英語・日本語のみでどちらも左から右のため、leading == 物理的な左、
/// trailing == 物理的な右として扱ってよい。ホバー判定側はウインドウ座標系のX座標(常に左が原点)を
/// 直接見るため、両者の対応がずれる余地は無い。
enum SidePanelPosition: String, CaseIterable, Identifiable, Codable, Hashable {
    case left
    case right

    var id: String { rawValue }

    /// パネル本体を寄せる側。ホバー表示中のZStackオーバーレイの`alignment`に使う。
    var alignment: Alignment {
        switch self {
        case .left: return .leading
        case .right: return .trailing
        }
    }

    /// ホバー表示の出現アニメーション(`.move(edge:)`)で、パネルが滑り出してくる側。
    var edge: Edge {
        switch self {
        case .left: return .leading
        case .right: return .trailing
        }
    }

    /// パネルの、ビューア(ページ表示エリア)側を向いた端。幅調整ハンドルの位置や、
    /// ページモードの拡大プレビューをどちら側へ出すか(popoverの`arrowEdge`)に使う。
    var innerEdge: Edge {
        switch self {
        case .left: return .trailing
        case .right: return .leading
        }
    }
}

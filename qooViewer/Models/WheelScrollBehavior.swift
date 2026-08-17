import SwiftUI

/// スクロールできる表示モード(横幅に合わせる/同(単ページ)/拡大縮小しない)で、マウスホイールを
/// 回したときに何をするか。cooViewerの環境設定「マウスホイール」→「スクロールできるとき:」
/// (`CanScrollMode`、選択肢はMainMenu.xibのid=1862)をそのまま移植したもの。
///
/// 「画面内に収める」モードには、そもそもスクロールする余地が無い。そのため、このモードでは
/// この設定に関わらず、従来どおりホイールにはキー・マウス設定で割り当てた操作
/// (既定ではページ送り)が実行される。
///
/// rawValueはケース名(永続化用の安定した識別子)。cooViewerは0〜3の整数で保存しているが、
/// qooViewerは他の設定と同じく文字列で保存する。
enum WheelScrollBehavior: String, CaseIterable, Identifiable, Codable, Hashable {
    /// スクロールするだけ。ページは決してめくらない(cooViewerの既定値「ノーマルスクロール」)。
    case scrollOnly
    /// スクロールし、端まで来たら1画面分だけ横へ回り込む。ページはめくらない
    /// (cooViewerの「スクロール」)。見開き分割で、片側を読み終えたらもう片側へ移りたいが、
    /// ページ送りはキー操作で明示的に行いたい、という使い方向け。
    case scrollAndWrap
    /// スクロールし、横にも余地が無くなったらページを送る(cooViewerの「スクロール+ページめくり」)。
    /// ホイールだけで最後まで読み進められる。
    case scrollAndTurnPage
    /// スクロールには使わず、常にキー・マウス設定で割り当てた操作(既定ではページ送り)を行う
    /// (cooViewerの「ページめくり」)。スクロールはドラッグやスクロールバーで行う。
    case turnPage

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .scrollOnly: return "Scroll Only"
        case .scrollAndWrap: return "Scroll, Then Move Sideways"
        case .scrollAndTurnPage: return "Scroll, Then Turn Page"
        case .turnPage: return "Turn Page Only"
        }
    }
}

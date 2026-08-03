import SwiftUI

/// アプリ内DB(`PageLayoutOverride`)にユーザーが手動設定、またはJSONインポートで取り込んだ、
/// ページ単位のレイアウト状態。
///
/// EPUBの`PageSpreadPosition`(left/right/center。package documentのspine itemref propertiesに
/// 対応する、著者が埋め込んだ権威的な指定)とは別物として扱う。こちらはqooViewer自身が
/// フォルダ/zip・cbz/rar・cbr/7z・cb7/PDFに対して独自に保持する、ユーザー由来のヒントであり、
/// 「除外(非表示)」というEPUBには存在しない状態も持つ。
///
/// 「レイアウトなし」(何も設定されていない状態)は、この enum の値としては表現しない。
/// `PageLayoutOverride`の行自体が存在しない、という形でDB上表現する(値を追加すると
/// 「未設定」と「明示的にレイアウトなしを選んだ」を区別できなくなり、優先順位判定
/// (2.4節: EPUB由来 > DB > 横長画像ヒューリスティック)が複雑になるため)。
///
/// rawValueはケース名(永続化・JSON書き出し用の安定した識別子)、titleKeyが画面表示用の
/// ローカライズされた名前。
enum PageLayoutState: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 単独ページとして固定表示する(見開き表示中でも前後のページとは組まない)。
    /// EPUBの`rendition:page-spread-center`に相当する。
    case single
    /// 見開きの右側として、常に直前のページと組む(自身は見開きの起点にならない)。
    /// EPUBの`page-spread-right`に相当する。
    case spreadRight
    /// 見開きの起点として、常に次のページと組む。
    /// EPUBの`page-spread-left`に相当する。
    case spreadLeft
    /// 通常の読書フロー(ページ送り・進捗バー・ページ数・サムネイル一覧)から完全にスキップする。
    /// EPUBには対応する概念が無い、qooViewer独自の状態。
    case excluded

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .single: return "Single Page"
        case .spreadRight: return "Spread Right"
        case .spreadLeft: return "Spread Left"
        case .excluded: return "Excluded (Hidden)"
        }
    }

    /// PageRef.epubSpreadPosition(EPUB由来、権威的)と同じ意味体系へ変換する。
    /// 「単一ページ」→center、「見開き右」→right、「見開き左」→left、
    /// 「除外」はEPUBの語彙に無いためnil(ExcludedはBookLoader側でページ自体を除去する形で
    /// 扱うため、ここでのマッピングは不要。詳細はEffectiveLayoutHintのコメント参照)。
    var asEpubEquivalentSpreadPosition: PageSpreadPosition? {
        switch self {
        case .single: return .center
        case .spreadRight: return .right
        case .spreadLeft: return .left
        case .excluded: return nil
        }
    }
}

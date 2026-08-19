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
///
/// バグ修正(ビルド時のエラー): EffectivePageOrder.swiftと同じ理由で`nonisolated`にしている。
/// この型自体はcase判定と変換だけの純粋な値型で、UIやアクター束縛の状態を持たないため、
/// `nonisolated enum EpubExporter`からasEpubEquivalentSpreadPositionを同期的に参照できる
/// 必要がある(以前はメインアクター隔離のプロパティをアクターの外から参照できないという
/// エラーになっていた)。SwiftUI側(titleKeyなど)からの利用は、nonisolatedな値型を
/// メインアクターのコードから使うことに何の問題も無いため、影響は無い。
nonisolated enum PageLayoutState: String, CaseIterable, Identifiable, Codable, Hashable {
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

    /// `NSMenuItem.title`のように、`LocalizedStringKey`を受け取れない(=SwiftUIが解決して
    /// くれない)AppKit側の場所向けの、解決済みの表示名。titleKeyと同じ文字列を返す。
    ///
    /// localeには必ずアプリ内表示言語(AppPreferences.displayLanguage由来)を反映したものを渡す。
    /// この設定はOSのロケールとは独立しているため(QooViewerApp側が各Sceneへ
    /// `.environment(\.locale, ...)`で注入している)、SwiftUIのView内からは
    /// `@Environment(\.locale)`で受け取ったものをそのまま渡せばよい。
    func title(locale: Locale) -> String {
        switch self {
        case .single: return String(localized: "Single Page", locale: locale)
        case .spreadRight: return String(localized: "Spread Right", locale: locale)
        case .spreadLeft: return String(localized: "Spread Left", locale: locale)
        case .excluded: return String(localized: "Excluded (Hidden)", locale: locale)
        }
    }

    /// EPUBのPageSpreadPositionから、対応するレイアウト状態を作る。
    /// asEpubEquivalentSpreadPositionの逆変換で、EPUBのページ単位の見開き配置を
    /// DB(PageLayoutOverride)へ取り込むために使う(LayoutStore.importSourceLayoutIfNeeded参照)。
    init(epubSpreadPosition: PageSpreadPosition) {
        switch epubSpreadPosition {
        case .center: self = .single
        case .right: self = .spreadRight
        case .left: self = .spreadLeft
        }
    }

    /// PageRef.epubSpreadPosition(EPUB由来)と同じ意味体系へ変換する。
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

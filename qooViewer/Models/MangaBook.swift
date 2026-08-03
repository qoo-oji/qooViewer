import Foundation

/// EPUBのpackage documentから読み取った、本全体に関わる表示上のヒント。
/// 値が存在する項目は、qooViewer側のユーザー設定(読み方向・見開き/単ページ)より
/// 優先して適用され、かつユーザーによる切り替え操作自体を無効化する
/// (詳細はViewerViewModel.isReadingDirectionLocked/isDisplayModeLockedとViewerView/
/// QooViewerAppでの`.disabled()`参照)。
/// EPUB以外(フォルダ・cbz/cbr/cb7・PDF)ではMangaBook.epubLayoutHint自体がnilになる。
struct EpubLayoutHint: Equatable {
    /// package document の spine要素の`page-progression-direction`属性から得た読み方向。
    /// 未指定のEPUBではnil(その場合は強制せず、これまで通りユーザー設定/既定値に従う)。
    var pageProgressionDirection: ReadingDirection?
    /// package document の`rendition:spread`メタデータから得た、本全体での見開き/単ページの強制。
    /// `none`は.single、`both`は.spread に対応する。`landscape`/`portrait`/`auto`/未指定は、
    /// macOSのウインドウ表示には向きの概念がないため強制しない(nil)。
    var forcedDisplayMode: DisplayMode?
}

/// 開いている1冊の漫画(画像フォルダ、zip/rar/7z アーカイブ、PDF、またはEPUB)
struct MangaBook: Identifiable, Hashable {
    /// 一意なID。フォルダ/アーカイブのファイルパスをそのまま使う
    let id: String
    /// ビューワーに表示するタイトル
    let title: String
    /// 元になったフォルダ、またはアーカイブファイルの場所
    let sourceURL: URL
    /// 自然順(数字を考慮した順序)に並んだページ一覧。
    /// varなのは、ViewerViewModelが除外(非表示)・並べ替えの変更を画像ビューアの表示へ
    /// 即座に反映できるよう、本を開き直さずにこの配列を丸ごと差し替え直すことがあるため
    /// (詳細はViewerViewModel.reloadLayoutDataのコメント参照)。
    var pages: [PageRef]
    /// EPUBを開いた場合のみ値を持つ、本全体の表示ヒント。詳細はEpubLayoutHint参照。
    var epubLayoutHint: EpubLayoutHint? = nil

    static func == (lhs: MangaBook, rhs: MangaBook) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

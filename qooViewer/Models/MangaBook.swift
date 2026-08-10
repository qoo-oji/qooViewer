import Foundation

/// 本のソースファイル自身が持つ、本全体に関わる表示上のヒント。
/// EPUB(package documentのspine)、およびPDF(Document Catalogの`/ViewerPreferences/Direction`・
/// `/PageLayout`)の両方から読み取る(詳細はEpubStructureResolver.resolve/
/// PDFStructureResolver.resolveLayoutHint参照)。値が存在する項目は、qooViewer側のユーザー設定
/// (読み方向・見開き/単ページ)より優先して適用され、かつユーザーによる切り替え操作自体を
/// 無効化する(詳細はViewerViewModel.isReadingDirectionLocked/isDisplayModeLockedとViewerView/
/// QooViewerAppでの`.disabled()`参照)。
/// フォルダ・cbz/cbr/cb7ではMangaBook.sourceLayoutHint自体がnilになる。EPUBは常に非nil
/// (中の2項目自体は未指定ならnilになりうる。「EPUBである」という判定にsourceLayoutHint != nilを
/// 使っている箇所があるため、BookLoader.loadEpubは値の有無に関わらず必ずこの構造体を作る)。
/// PDFは、カタログにどちらの項目も見つからなければ構造体自体がnilになる(EPUBと異なり、
/// PDFであること自体はsourceLayoutHintの有無で判定しない。ViewerViewModelの自動インポート
/// 判定はisEpubFile/isPDFFileで直接ファイル形式を見る)。
struct SourceLayoutHint: Equatable {
    /// EPUB: spine要素の`page-progression-direction`属性。PDF: Document Catalogの
    /// `/ViewerPreferences/Direction`(`L2R`/`R2L`)。どちらも未指定/未対応の値ならnil
    /// (その場合は強制せず、これまで通りユーザー設定/既定値に従う)。
    var pageProgressionDirection: ReadingDirection?
    /// EPUB: package documentの`rendition:spread`メタデータ。`none`は.single、`both`は.spread
    /// に対応する。`landscape`/`portrait`/`auto`/未指定は、macOSのウインドウ表示には向きの概念が
    /// 無いため強制しない(nil)。
    /// PDF: Document Catalogの`/PageLayout`。`TwoPageLeft`/`TwoPageRight`のときのみ.spreadとして
    /// 扱う(詳細はPDFStructureResolver.forcedDisplayModeのコメント参照。`SinglePage`等を
    /// .singleとして強制しないのは、多くのPDF生成ツールがこの項目自体を意図せず省略しており、
    /// EPUBのrendition:spread=noneほどの信頼度が無いため)。
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
    /// 本のソースファイル自身が持つ、本全体の表示ヒント。詳細はSourceLayoutHint参照。
    var sourceLayoutHint: SourceLayoutHint? = nil

    static func == (lhs: MangaBook, rhs: MangaBook) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

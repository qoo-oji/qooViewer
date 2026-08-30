import SwiftUI

/// 本を1冊まるごと書き出せる形式(EPUB / PDF / CBZ)。
///
/// この3つは元々「EPUBの書き出し」「PDFの書き出し」「CBZの書き出し」という3つのウインドウ
/// としてだけ存在し、形式ごとの違いは各ウインドウが自前の定数(`ExportWindowConfiguration`)
/// として持っていた。そこへ
///   ・ビューアの右クリックから、いま開いている本をそのまま書き出す導線
///   ・環境設定「レイアウト」の、形式ごとの保存先/保存データ/履歴の設定
/// が加わり、「3つの形式のどれか1つを選ぶ」という同じ形の分岐が3か所に増えたため、
/// 形式そのものを型にした。
///
/// 【メンテナンス】形式を1つ増やすときに触るのは、原則このファイルのswitchだけでよい
/// (コンテキストメニューの項目も、環境設定の形式ごとのセクションも`allCases`から導出される)。
enum BookExportFormat: String, CaseIterable, Identifiable, Codable, Hashable {
    case epub
    case pdf
    case cbz

    var id: String { rawValue }

    /// 出力ファイルの拡張子。
    var fileExtension: String { rawValue }

    /// 画像ファイルの連番リネームという概念を持つか。
    /// PDFはページごとの画像ファイル名という概念自体を持たない(PDFExportOptions参照)。
    ///
    /// 環境設定「レイアウト」の既定値の行と、書き出しウインドウ/シートのオプションの
    /// 両方がこれを見る ―― 片方にだけ項目が出る、という食い違いを作らないため。
    var supportsImageRenumbering: Bool { self != .pdf }

    /// ComicInfo.xmlの`Volume`要素という概念を持つか(CBZだけ)。
    var supportsComicInfoVolumeElement: Bool { self == .cbz }

    /// 画面に出す形式名。固有名詞で翻訳の対象にならないため、文字列カタログには載せずに
    /// `Text(verbatim:)`で出す(環境設定の形式ごとのセクション見出しなど)。
    var displayName: String { rawValue.uppercased() }

    /// コンテキストメニュー「本の書き出し」のサブメニューに並べる項目名。
    ///
    /// 末尾に「…」を付けていない。「…」は「押すと必ず何か尋ねられる」ことを表す記号だが、
    /// この項目は環境設定で固定の保存先を決めてあれば**何も尋ねずにその場で書き出す**
    /// (ユーザー要望の中心。新しい本を開く→書き出す、を操作なしで繰り返せるようにするため)。
    var menuTitleKey: LocalizedStringKey {
        switch self {
        // ウインドウ名の"Export as EPUB"(「EPUBの書き出し」)とは**別のキー**にしてある。
        // あちらは一覧から選んでまとめて書き出すウインドウの名前、こちらはいま開いている本に
        // 対する操作で、日本語では語形自体が違う(「EPUBの書き出し」/「EPUBとして書き出す」)。
        case .epub: "Export This Book as EPUB"
        case .pdf: "Export This Book as PDF"
        case .cbz: "Export This Book as CBZ"
        }
    }

    /// 書き出しウインドウ下部の実行ボタンの名前。保存先を尋ねるパネルが出る場合。
    var startExportTitleKey: LocalizedStringKey {
        switch self {
        case .epub: "Start EPUB Export…"
        case .pdf: "Start PDF Export…"
        case .cbz: "Start CBZ Export…"
        }
    }

    /// 同じボタンの、パネルが出ない場合(環境設定「レイアウト」で保存先を決めてある場合)の名前。
    /// 「…」が付かないだけの違い(ExportWindowContentのボタンのコメント参照)。
    var startExportWithoutPanelTitleKey: LocalizedStringKey {
        switch self {
        case .epub: "Start EPUB Export"
        case .pdf: "Start PDF Export"
        case .cbz: "Start CBZ Export"
        }
    }

    /// 書き出しウインドウの保存先パネルが最後に開いたフォルダ(次に開くときの初期位置)。
    var lastUsedFolder: LastUsedFolderMemory {
        switch self {
        case .epub: .epubExport
        case .pdf: .pdfExport
        case .cbz: .cbzExport
        }
    }

    /// 環境設定「レイアウト」で「既定の保存先を設定」を選んだときの保存先フォルダ。
    /// パネルの初期位置(`lastUsedFolder`)とは別に持つ理由はそちらのコメント参照。
    var fixedFolder: LastUsedFolderMemory { .fixedExportFolder(self) }

    /// この形式の書き出しを行うViewModel。
    ///
    /// - Parameter loadsEligibleRows: 書き出しウインドウの対象一覧を組み立てるか。
    ///   ビューアから1冊だけ書き出す場合はfalse(理由は`BookExportViewModel.init`参照)。
    @MainActor
    func makeExportViewModel(
        bookmarkStore: BookmarkStore, layoutStore: LayoutStore, metadataStore: BookMetadataStore,
        preferences: AppPreferences, loadsEligibleRows: Bool
    ) -> BookExportViewModel {
        switch self {
        case .epub:
            EpubExportViewModel(
                bookmarkStore: bookmarkStore, layoutStore: layoutStore, metadataStore: metadataStore,
                preferences: preferences, loadsEligibleRows: loadsEligibleRows
            )
        case .pdf:
            PDFExportViewModel(
                bookmarkStore: bookmarkStore, layoutStore: layoutStore, metadataStore: metadataStore,
                preferences: preferences, loadsEligibleRows: loadsEligibleRows
            )
        case .cbz:
            CbzExportViewModel(
                bookmarkStore: bookmarkStore, layoutStore: layoutStore, metadataStore: metadataStore,
                preferences: preferences, loadsEligibleRows: loadsEligibleRows
            )
        }
    }
}

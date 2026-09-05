import SwiftUI

/// 書き出しウインドウ(EPUB / PDF / CBZ)の対象一覧を、元のファイル形式で絞り込むための選択肢。
///
/// 対象一覧に載るのはフォルダ・zip/cbz・rar/cbr・7z/cb7・PDF・EPUBの6種類
/// (BookExportViewModel.reload()参照)。判定は`bookID`(拡張子を含むフルパス)の拡張子だけで
/// 行う ―― 一覧の行が持っているのがそれだけであり、FormatBadgeViewが行末に出しているバッジも
/// 同じ拡張子から導いているため、「バッジがZIPの行だけが残る」という見た目どおりの結果になる。
///
/// zip/cbzのように**同じ中身で拡張子だけが違う**ものは1つの選択肢にまとめてある(ユーザーが
/// 区別したいのは形式であって拡張子ではないため)。
enum BookExportSourceFormat: String, CaseIterable, Identifiable {
    case all
    case zip
    case rar
    case sevenZip
    case pdf
    case epub
    case folder

    var id: String { rawValue }

    /// この選択肢に含まれる拡張子(小文字)。フォルダは拡張子を持たないため空
    /// (判定はmatches(bookID:)側で行う)。
    private var fileExtensions: Set<String> {
        switch self {
        case .all, .folder: []
        case .zip: ["zip", "cbz"]
        case .rar: ["rar", "cbr"]
        case .sevenZip: ["7z", "cb7"]
        case .pdf: ["pdf"]
        case .epub: ["epub"]
        }
    }

    /// ドロップダウンに出す名前。
    ///
    /// 拡張子そのもの(ZIP/CBZなど)は表示言語で変わらないため文字列カタログには載せず、
    /// `Text(verbatim:)`で出す(FormatBadgeViewのバッジと同じ考え方)。翻訳が要るのは
    /// 「すべて」と「フォルダ」の2つだけ。
    var titleText: Text {
        switch self {
        case .all: Text("All")
        case .zip: Text(verbatim: "ZIP / CBZ")
        case .rar: Text(verbatim: "RAR / CBR")
        case .sevenZip: Text(verbatim: "7Z / CB7")
        case .pdf: Text(verbatim: "PDF")
        case .epub: Text(verbatim: "EPUB")
        case .folder: Text("Folder")
        }
    }

    func matches(bookID: String) -> Bool {
        guard self != .all else { return true }
        let fileExtension = URL(fileURLWithPath: bookID).pathExtension.lowercased()
        guard self != .folder else { return fileExtension.isEmpty }
        return fileExtensions.contains(fileExtension)
    }
}

/// 書き出しウインドウの対象一覧の絞り込み条件(ユーザー要望: 保存データの登録状態と元の
/// ファイル形式で一覧を絞り込みたい)。
///
/// ■ 2つの軸で組み合わせ方が違う理由(ユーザーの指示)
/// - 保存データ(レイアウト/ブックマーク/メタデータ)は**チェックボックスのAND**。
///   1冊が3種類すべてを同時に持てるため、「レイアウトとメタデータの両方がある本」という
///   絞り込みに意味がある。
/// - ファイル形式は**ドロップダウンの単一選択**。1冊は必ず1形式なのでANDにはできず、
///   かといって複数選択(OR)にすると、隣のチェックボックス群とは逆の組み合わせ方が
///   1つの画面に並ぶことになり、どちらがどちらか分からなくなる。
///
/// 絞り込みは一覧の**見え方**だけを変えるもので、チェックボックス(選択)には触れない
/// (BookExportViewModel.selectedBookIDsのコメント参照)。
struct BookExportRowFilter: Equatable {
    var requiresLayout = false
    var requiresBookmarks = false
    var requiresMetadata = false
    var format: BookExportSourceFormat = .all

    /// 1つでも条件が設定されているか(ツールバーのボタンの見た目と「絞り込みを解除」ボタンの
    /// 有効/無効に使う)。
    var isActive: Bool {
        requiresLayout || requiresBookmarks || requiresMetadata || format != .all
    }

    /// 3つのチェックボックスはANDで、チェックの無い種類は条件にしない(=その有無を問わない)。
    func matches(bookID: String, hasLayout: Bool, hasBookmarks: Bool, hasMetadata: Bool) -> Bool {
        if requiresLayout && !hasLayout { return false }
        if requiresBookmarks && !hasBookmarks { return false }
        if requiresMetadata && !hasMetadata { return false }
        return format.matches(bookID: bookID)
    }
}

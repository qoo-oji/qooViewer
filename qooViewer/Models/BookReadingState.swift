import Foundation
import SwiftData

/// 本ごとの「最後に読んだページ」「表示モード」「読み方向」をSwiftDataで永続化するモデル。
/// bookID には MangaBook.id (フォルダ/アーカイブファイルのパス) を使う。
///
/// bookID(パス)が同じでも、そのファイル/フォルダの中身が実際には別のものに差し替わっている
/// ことがある(例: 同じ名前で別の本をダウンロードし直した、フォルダの中身を丸ごと入れ替えた等)。
/// これを大まかに検知するため、前回この本を開いたときの「軽量な指紋」として
/// recordedPageCount(ページ数)・recordedSourceModificationDate(更新日時)・
/// recordedSourceFileSize(ファイルサイズ。フォルダの場合は取得できないためnil)を
/// あわせて保存しておく(ViewerViewModel.init参照。実際の比較・古いデータの削除はそちらで行う)。
/// 以前はbookIDに`@Attribute(.unique)`の一意制約を付けていたが、外した。Bookmark.id/
/// PageLayoutOverride.compositeKey/BookLayoutSettings.bookIDと同じ理由(詳細はBookmark.swiftの
/// コメント参照)。一意性自体はViewerViewModel.init側で、insertする前に必ず
/// (allReadingStatesをbookIDでfilterして)既存行の有無を確認してから分岐しているため
/// アプリ側で保証されており、SwiftData側の一意制約に頼る必要は無い。
@Model
final class BookReadingState {
    var bookID: String
    /// 最後に読んでいたページの位置。**権威は下のlastPageKey**で、こちらは導出値。
    var lastPageIndex: Int
    /// 最後に読んでいたページの鍵(PageRef.sortKey)。nilは1.36以前に保存された行で、
    /// その場合lastPageIndexは従来順(`.numeric`)の並びでの位置を指す
    /// (Bookmark.pageKeyのコメント参照)。
    var lastPageKey: String?
    var displayModeRaw: String
    var readingDirectionRaw: String
    var scalingModeRaw: String = ScalingMode.fitToScreen.rawValue
    var updatedAt: Date
    /// 前回この本を開いたときのページ数。中身が差し替わっていないかを大まかに判定する
    /// 「指紋」の一部として使う。この仕組みを導入する前に保存された古いデータではnil。
    var recordedPageCount: Int?
    /// 前回この本を開いたときの、元のファイル/フォルダの更新日時。
    var recordedSourceModificationDate: Date?
    /// 前回この本を開いたときの、元のファイルのサイズ(バイト)。フォルダの場合はnil。
    var recordedSourceFileSize: Int64?

    init(
        bookID: String,
        lastPageIndex: Int = 0,
        displayMode: DisplayMode = .spread,
        readingDirection: ReadingDirection = .rightToLeft,
        scalingMode: ScalingMode = .fitToScreen
    ) {
        self.bookID = bookID
        self.lastPageIndex = lastPageIndex
        self.displayModeRaw = displayMode.rawValue
        self.readingDirectionRaw = readingDirection.rawValue
        self.scalingModeRaw = scalingMode.rawValue
        self.updatedAt = Date()
    }

    var displayMode: DisplayMode {
        get { DisplayMode(rawValue: displayModeRaw) ?? .spread }
        set { displayModeRaw = newValue.rawValue }
    }

    var readingDirection: ReadingDirection {
        get { ReadingDirection(rawValue: readingDirectionRaw) ?? .rightToLeft }
        set { readingDirectionRaw = newValue.rawValue }
    }

    var scalingMode: ScalingMode {
        get { ScalingMode(rawValue: scalingModeRaw) ?? .fitToScreen }
        set { scalingModeRaw = newValue.rawValue }
    }
}

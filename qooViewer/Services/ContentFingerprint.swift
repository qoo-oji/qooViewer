import Foundation

/// 同じbookID(パス)のまま、フォルダ/アーカイブファイルの中身が実際には別物に差し替わっている
/// ケースを大まかに検知するための「軽量な指紋」。
///
/// フルハッシュ計算は行わない。ページ数・元ファイル/フォルダの更新日時・ファイルサイズという
/// 3点が偶然すべて一致してしまう差し替えは検知できないという理論上のブラインドスポットを
/// 許容する(既存の`BookReadingState`が採用していた方式をそのまま踏襲する)。
///
/// 元々は`ViewerViewModel.init`にベタ書きされていたロジックで、`BookLayoutSettings`
/// (アプリ内DBのページレイアウト設定)にも同じ仕組みが必要になったため、
/// `BookReadingState`・`BookLayoutSettings`のどちらからも使える形に切り出した。
enum ContentFingerprint {
    /// ある時点でのMangaBookの状態を表す指紋。
    struct Snapshot: Equatable {
        var pageCount: Int
        var modificationDate: Date?
        var fileSize: Int64?
    }

    /// 記録済みの指紋(SwiftDataモデルに保存されている3属性)。3つとも揃っていない
    /// (この仕組みを導入する前に保存された古いデータ等)場合はnilのまま扱う。
    struct Recorded: Equatable {
        var pageCount: Int?
        var modificationDate: Date?
        var fileSize: Int64?
    }

    /// 今開こうとしているMangaBookから、現在の指紋を計算する。
    static func current(for book: MangaBook) -> Snapshot {
        let sourceResourceValues = try? book.sourceURL.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        return Snapshot(
            pageCount: book.pages.count,
            modificationDate: sourceResourceValues?.contentModificationDate,
            fileSize: sourceResourceValues?.fileSize.map(Int64.init)
        )
    }

    /// 記録済みの指紋と現在の指紋を比較し、「中身が差し替わっていそうか」を判定する。
    ///
    /// - recordedがnil、またはrecorded.pageCountがnil(指紋の仕組みを導入する前に保存された
    ///   古いデータで、そもそも比較のしようがない)の場合は、「差し替えなし」として扱う
    ///   (既存のBookReadingStateの挙動をそのまま踏襲)。
    static func looksReplaced(recorded: Recorded?, current: Snapshot) -> Bool {
        guard let recorded, let recordedPageCount = recorded.pageCount else { return false }
        return recordedPageCount != current.pageCount
            || recorded.modificationDate != current.modificationDate
            || recorded.fileSize != current.fileSize
    }
}

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
        /// 本がフォルダか。**フォルダの更新日時は比べない**(looksReplaced)。フォルダの更新日時は中の項目が増減・改名される
        /// たびに変わり、Finder が表示の設定を書く `.DS_Store`、ネットワークや FAT の `._` ファイルでも変わる ―― 中身の
        /// 目印にならない。比べていたため、Finder でフォルダを表示しただけで「差し替えられた」と判断され、読書位置・
        /// 読み方向・ブックマークが消えていた(1.71 の「読み方向が記憶されない」の報告。2026-09-25 に再現)。
        /// フォルダの本はページ数だけで判定する(同じ枚数の別の本へ丸ごと入れ替えた場合は検知できない)。
        var isDirectory: Bool = false
        /// ページ数だけで比べるか(StackNest の参照ファイルの本)。参照ファイルは StackNest が開くたびに書き直す(鍵・
        /// 期限が変わる)ので、その更新日時・大きさは中身の目印にならない。本は参照ファイルのパス(書庫と本の ID を含む)で
        /// 決まり、保存される指紋に本の URL を入れる列は無い(足すと @Model の変更になる)。
        var comparesPageCountOnly: Bool = false
    }

    /// 記録済みの指紋(SwiftDataモデルに保存されている3属性)。3つとも揃っていない
    /// (この仕組みを導入する前に保存された古いデータ等)場合はnilのまま扱う。
    struct Recorded: Equatable {
        var pageCount: Int?
        var modificationDate: Date?
        var fileSize: Int64?
    }

    /// 今開こうとしているMangaBookから、現在の指紋を計算する。
    ///
    /// 更新日時・大きさは、本を開いたときにメインの外で求めたもの(`MangaBook.sourceFacts`)を使う(2026-10-11 の規約監査 ――
    /// 以前は本を開くたびにここでメインで stat し、ネットワークボリュームでは最初の見開きを読む前に往復を待った)。
    /// 事実を持たない本(テストが直接組んだ本)だけ、その場で問い合わせる。
    static func current(for book: MangaBook) -> Snapshot {
        // 参照ファイルの本は stat もしない・開いたときの事実(sourceFacts)も使わない: 参照ファイルは開くたびに書き直される
        // (Snapshot.comparesPageCountOnly のコメント)。
        if book.stackNestReference != nil {
            return Snapshot(pageCount: book.pages.count, modificationDate: nil, fileSize: nil, comparesPageCountOnly: true)
        }
        if let facts = book.sourceFacts {
            return Snapshot(
                pageCount: book.pages.count,
                modificationDate: facts.modificationDate,
                fileSize: facts.fileSize,
                isDirectory: facts.isDirectory
            )
        }
        BookSourceFacts.noteMissingFacts(book, "ContentFingerprint.current")
        let sourceResourceValues = try? book.sourceURL.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        )
        return Snapshot(
            pageCount: book.pages.count,
            modificationDate: sourceResourceValues?.contentModificationDate,
            fileSize: sourceResourceValues?.fileSize.map(Int64.init),
            isDirectory: sourceResourceValues?.isDirectory ?? false
        )
    }

    /// 記録済みの指紋と現在の指紋を比較し、「中身が差し替わっていそうか」を判定する。
    ///
    /// - recordedがnil、またはrecorded.pageCountがnil(指紋の仕組みを導入する前に保存された
    ///   古いデータで、そもそも比較のしようがない)の場合は、「差し替えなし」として扱う
    ///   (既存のBookReadingStateの挙動をそのまま踏襲)。
    static func looksReplaced(recorded: Recorded?, current: Snapshot) -> Bool {
        guard let recorded, let recordedPageCount = recorded.pageCount else { return false }
        if recordedPageCount != current.pageCount { return true }
        // フォルダの本は更新日時(とサイズ。フォルダでは取れない)を比べない(Snapshot.isDirectory のコメント)。
        if current.isDirectory || current.comparesPageCountOnly { return false }
        return recorded.modificationDate != current.modificationDate
            || recorded.fileSize != current.fileSize
    }
}

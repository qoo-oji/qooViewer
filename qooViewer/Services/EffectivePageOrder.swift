import Foundation

/// PageOrderOverride(設計コンセプト2.3節)の反映と、除外(excluded、2.2節)ページの除去を行う、
/// ViewerViewModel.applyLayoutDataと同じロジックの独立実装。
///
/// JSON入出力(6節)で、Bookmark.pageIndex(実際の読書順に並んだ配列のインデックス)と
/// PageLayoutOverride.pageKey(ファイル名/アーカイブ内エントリパス相当の文字列)を相互変換する
/// ために使う。ViewerViewModel.applyLayoutDataは`private static`のため直接は再利用できず、
/// また独立したJSON入出力サービス(LibraryImportExportService)にViewerViewModelそのものへの
/// 依存(book/pageLayoutStatesなどインスタンス状態)を持たせたくないため、あえて別実装にしている。
/// ロジック自体は意図的に同一に保っているため、一方を変更した場合はもう一方にも反映すること。
///
/// バグ修正(ビルド時のエラー): このプロジェクトは既定でメインアクターに隔離される設定に
/// なっているため、明示的な注釈が無いこの型は本来メインアクター隔離になる。しかし中身は
/// MangaBook/PageRefという純粋な値を変換するだけの同期処理で、UIやアクター束縛の状態には
/// 一切触れないため、ImageExporter/EpubExporterと同じく`nonisolated`にしておく方が実態に
/// 合っている。これにより、`nonisolated enum EpubExporter`(非メインアクターの文脈)から
/// 同期的に呼び出せるようにする(以前はここが原因で「メインアクター隔離のメソッドをアクターの
/// 外から呼べない」というエラーになっていた)。
nonisolated enum EffectivePageOrder {
    /// 実際の読書順に並んだPageRefの一覧(除外ページは含まない)。EPUB書き出し(EpubExporter、
    /// 7節)が、画像の複製・見開き配置の書き出しのために実際のPageRef(source)を必要とするため、
    /// pageKeyだけを返すpageKeys(for:pageOrderOverride:excludedKeys:)とは別にこちらも公開する。
    static func orderedPages(
        for book: MangaBook, pageOrderOverride: [String]?, excludedKeys: Set<String>
    ) -> [PageRef] {
        var ordered = book.pages
        if let pageOrderOverride {
            var pageByKey: [String: PageRef] = [:]
            for page in book.pages { pageByKey[page.sortKey] = page }
            var seenKeys: Set<String> = []
            var reordered: [PageRef] = []
            for key in pageOrderOverride {
                if let page = pageByKey[key] {
                    reordered.append(page)
                    seenKeys.insert(key)
                }
            }
            for page in book.pages where !seenKeys.contains(page.sortKey) {
                reordered.append(page)
            }
            ordered = reordered
        }
        return ordered.filter { !excludedKeys.contains($0.sortKey) }
    }

    /// 実際の読書順に並んだpageKeyの一覧(除外ページは含まない)。
    /// この配列のインデックスが、そのままBookmark.pageIndexの値と対応する
    /// (ViewerViewModelがbook.pagesとして保持する配列のインデックスと同じ空間)。
    static func pageKeys(
        for book: MangaBook, pageOrderOverride: [String]?, excludedKeys: Set<String>
    ) -> [String] {
        orderedPages(for: book, pageOrderOverride: pageOrderOverride, excludedKeys: excludedKeys).map(\.sortKey)
    }
}

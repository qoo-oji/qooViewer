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
/// 並べ替え・除外の対象になれるページ。sortKeyさえ持っていればよい。
///
/// PageRef(本体を読み込んで得られるもの)と BookPageListCache.Entry.Page(ディスクキャッシュ
/// から得られるもの)の両方を、同じ1つの実装で扱えるようにするためのもの。以前はこの2つに
/// 対して同じアルゴリズムを2本書き、「一方を変更した場合はもう一方にも反映すること」という
/// 注意書きで運用していたが、この並べ替え・除外はBookmark.pageIndexが指す位置そのものを
/// 決めるため、片方だけがずれると気付きにくい形で壊れる。
nonisolated protocol PageOrderSortable {
    var sortKey: String { get }
}

// このプロジェクトの既定のアクター隔離はMainActorのため、extension自体にも`nonisolated`を
// 付けないと「メインアクター隔離の準拠」になり、nonisolatedな文脈(EpubExporterなど)から
// 使えない(Services/ArchiveReading.swift冒頭のコメント参照)。
nonisolated extension PageRef: PageOrderSortable {}
nonisolated extension BookPageListCache.Entry.Page: PageOrderSortable {}

nonisolated enum EffectivePageOrder {
    /// 実際の読書順に並んだページの一覧(除外ページは含まない)。
    ///
    /// pageOrderOverrideに書かれている順に並べ、そこに含まれないページ(保存後に増えたページ)は
    /// 元の並びのまま末尾へ回す。pageOrderOverrideにあって実際には存在しないページは無視する。
    ///
    /// PageRefとBookPageListCache.Entry.Pageの両方をこの1つの実装で扱う(PageOrderSortable
    /// のコメント参照)。前者はEPUB書き出しが画像の複製・見開き配置のために実際のPageRef
    /// (source)を必要とする経路で、後者は本体を読み込まずに「実質的な先頭ページのファイル名」
    /// だけを知りたい経路(EPUB出力ウインドウのカバー名列)で使う。
    static func orderedPages<Page: PageOrderSortable>(
        for pages: [Page], pageOrderOverride: [String]?, excludedKeys: Set<String>
    ) -> [Page] {
        var ordered = pages
        if let pageOrderOverride {
            var pageByKey: [String: Page] = [:]
            for page in pages { pageByKey[page.sortKey] = page }
            var seenKeys: Set<String> = []
            var reordered: [Page] = []
            for key in pageOrderOverride {
                if let page = pageByKey[key] {
                    reordered.append(page)
                    seenKeys.insert(key)
                }
            }
            for page in pages where !seenKeys.contains(page.sortKey) {
                reordered.append(page)
            }
            ordered = reordered
        }
        return ordered.filter { !excludedKeys.contains($0.sortKey) }
    }

    /// MangaBookを受け取る版(呼び出し側の大半はこちら)。
    static func orderedPages(
        for book: MangaBook, pageOrderOverride: [String]?, excludedKeys: Set<String>
    ) -> [PageRef] {
        orderedPages(for: book.pages, pageOrderOverride: pageOrderOverride, excludedKeys: excludedKeys)
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

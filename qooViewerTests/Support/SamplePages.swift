import Foundation

@testable import qooViewer

/// ファイル I/O を伴わない、純粋ロジックのテスト用に組み立てるページと本。
///
/// 読み込み経路(`FixtureBook.load`)を通さずに `sortKey` の列だけを与えたいテスト
/// (`EffectivePageOrder` など)のためのもの。**本物の本の代わりに使わないこと** ――
/// 読み込みの回帰は台帳付きのフィクスチャ(`Fixtures`)で見る。
nonisolated enum SamplePages {
    /// 与えた `sortKey` の列を、そのままの並びの `PageRef` にする。
    /// `source` は使わないので、`sortKey` から作った適当なファイル URL を持たせておく。
    static func pages(_ sortKeys: [String]) -> [PageRef] {
        sortKeys.map { key in
            PageRef(
                id: "sample#\(key)", sortKey: key,
                source: .file(URL(fileURLWithPath: "/sample/\(key)"))
            )
        }
    }

    /// `EffectivePageOrder.orderedPages(for book:)` に渡すための本。
    /// ディスク上には何も無いので、読み込みを伴う経路へ渡してはいけない。
    static func book(
        sortKeys: [String], pageOrderSource: PageOrderSource = .fileName
    ) -> MangaBook {
        MangaBook(
            id: "/sample/book", title: "book",
            sourceURL: URL(fileURLWithPath: "/sample/book"),
            pages: pages(sortKeys), pageOrderSource: pageOrderSource
        )
    }
}

import Foundation
import Testing

@testable import qooViewer

/// 実効ページ順(Services/EffectivePageOrder.swift)。
///
/// ここが決めるのは「本を開いたときに実際に並ぶページ」そのもので、その配列の添字が
/// `Bookmark.pageIndex` の値になる。つまり並べ替え・除外の扱いが1つ変わるだけで、
/// 保存済みのブックマークが別のページを指す。`ViewerViewModel.applyLayoutData` に同じ
/// ロジックの写しがあり、「一方を変えたら他方にも反映する」運用になっている(型コメント参照)。
///
/// 並び順の設定(`PageOrder.usesFinderOrder` = UserDefaults)はテストから触らない約束なので、
/// 名前順が絡む呼び出しでは必ず `usesFinderOrderOverride` を明示する。
struct EffectivePageOrderTests {
    // MARK: - 並べ替え(override 無し)

    @Test("override が無ければ、渡した順ではなく名前順に並ぶ")
    func sortsByNameWithoutOverride() {
        let pages = SamplePages.pages(["010.jpg", "002.jpg", "001.jpg"])
        let ordered = EffectivePageOrder.orderedPages(
            for: pages, pageOrderOverride: nil, excludedKeys: [], usesFinderOrderOverride: true
        )
        #expect(ordered.map(\.sortKey) == ["001.jpg", "002.jpg", "010.jpg"])
    }

    @Test("名前順は「並び順を Finder に揃える」の唯一の適用点")
    func theFinderOrderSettingAppliesHere() {
        // 1.37 の報告そのもの(PageOrderTests 参照)。ここが唯一の適用点なので、
        // 設定の効き目もここで固定しておく。
        let pages = SamplePages.pages(["Com-title-cover.JPG", "_Com-title.JPG", "Com_title_0001.JPG"])
        let canonical = EffectivePageOrder.orderedPages(
            for: pages, pageOrderOverride: nil, excludedKeys: [], usesFinderOrderOverride: true
        )
        let legacy = EffectivePageOrder.orderedPages(
            for: pages, pageOrderOverride: nil, excludedKeys: [], usesFinderOrderOverride: false
        )
        #expect(canonical.map(\.sortKey) == ["_Com-title.JPG", "Com_title_0001.JPG", "Com-title-cover.JPG"])
        #expect(legacy.map(\.sortKey) == ["Com-title-cover.JPG", "Com_title_0001.JPG", "_Com-title.JPG"])
    }

    @Test(".document(PDF・EPUB)は並べ替えない")
    func documentOrderIsNeverSorted() {
        // ファイル自身が持つページ順。名前順に直すとページが入れ替わる。
        let pages = SamplePages.pages(["010.jpg", "002.jpg", "001.jpg"])
        let ordered = EffectivePageOrder.orderedPages(
            for: pages, pageOrderSource: .document,
            pageOrderOverride: nil, excludedKeys: [], usesFinderOrderOverride: true
        )
        #expect(ordered.map(\.sortKey) == ["010.jpg", "002.jpg", "001.jpg"])
    }

    @Test(".document でもユーザーの並べ替えは効く")
    func documentOrderStillHonorsOverride() {
        let pages = SamplePages.pages(["001.jpg", "002.jpg", "003.jpg"])
        let ordered = EffectivePageOrder.orderedPages(
            for: pages, pageOrderSource: .document,
            pageOrderOverride: ["003.jpg", "001.jpg", "002.jpg"], excludedKeys: [],
            usesFinderOrderOverride: true
        )
        #expect(ordered.map(\.sortKey) == ["003.jpg", "001.jpg", "002.jpg"])
    }

    // MARK: - override(ユーザーの並べ替え)

    @Test("override に書かれた順に並ぶ")
    func overrideDecidesTheOrder() {
        let pages = SamplePages.pages(["001.jpg", "002.jpg", "003.jpg"])
        let ordered = EffectivePageOrder.orderedPages(
            for: pages, pageOrderOverride: ["002.jpg", "003.jpg", "001.jpg"], excludedKeys: [],
            usesFinderOrderOverride: true
        )
        #expect(ordered.map(\.sortKey) == ["002.jpg", "003.jpg", "001.jpg"])
    }

    @Test("override に無いページ(保存後に増えたページ)は、名前順のまま末尾へ回る")
    func pagesMissingFromOverrideGoToTheEnd() {
        let pages = SamplePages.pages(["001.jpg", "002.jpg", "003.jpg", "004.jpg"])
        let ordered = EffectivePageOrder.orderedPages(
            for: pages, pageOrderOverride: ["003.jpg", "001.jpg"], excludedKeys: [],
            usesFinderOrderOverride: true
        )
        // 末尾の 2 件は元の並び(名前順)を保つ。
        #expect(ordered.map(\.sortKey) == ["003.jpg", "001.jpg", "002.jpg", "004.jpg"])
    }

    @Test("override にあって実在しないページは無視する")
    func overrideEntriesForMissingPagesAreIgnored() {
        let pages = SamplePages.pages(["001.jpg", "002.jpg"])
        let ordered = EffectivePageOrder.orderedPages(
            for: pages, pageOrderOverride: ["ghost.jpg", "002.jpg", "001.jpg"], excludedKeys: [],
            usesFinderOrderOverride: true
        )
        #expect(ordered.map(\.sortKey) == ["002.jpg", "001.jpg"])
    }

    @Test("空の override はページを1枚も消さない")
    func emptyOverrideKeepsEveryPage() {
        let pages = SamplePages.pages(["002.jpg", "001.jpg"])
        let ordered = EffectivePageOrder.orderedPages(
            for: pages, pageOrderOverride: [], excludedKeys: [], usesFinderOrderOverride: true
        )
        #expect(ordered.map(\.sortKey) == ["001.jpg", "002.jpg"])
    }

    // MARK: - 除外

    @Test("除外したページは結果に含まれない")
    func excludedPagesAreRemoved() {
        let pages = SamplePages.pages(["001.jpg", "002.jpg", "003.jpg"])
        let ordered = EffectivePageOrder.orderedPages(
            for: pages, pageOrderOverride: nil, excludedKeys: ["002.jpg"],
            usesFinderOrderOverride: true
        )
        #expect(ordered.map(\.sortKey) == ["001.jpg", "003.jpg"])
    }

    @Test("override に載っているページでも、除外なら消える")
    func exclusionWinsOverTheOverride() {
        let pages = SamplePages.pages(["001.jpg", "002.jpg", "003.jpg"])
        let ordered = EffectivePageOrder.orderedPages(
            for: pages, pageOrderOverride: ["002.jpg", "001.jpg", "003.jpg"],
            excludedKeys: ["001.jpg", "003.jpg"], usesFinderOrderOverride: true
        )
        #expect(ordered.map(\.sortKey) == ["002.jpg"])
    }

    @Test("実在しないキーを除外に入れても何も起きない")
    func exclusionOfMissingKeysIsHarmless() {
        let pages = SamplePages.pages(["001.jpg"])
        let ordered = EffectivePageOrder.orderedPages(
            for: pages, pageOrderOverride: nil, excludedKeys: ["ghost.jpg"],
            usesFinderOrderOverride: true
        )
        #expect(ordered.map(\.sortKey) == ["001.jpg"])
    }

    @Test("ページが1枚も無い本でも落ちない")
    func emptyBookIsFine() {
        let ordered = EffectivePageOrder.orderedPages(
            for: [PageRef](), pageOrderOverride: ["001.jpg"], excludedKeys: ["002.jpg"],
            usesFinderOrderOverride: true
        )
        #expect(ordered.isEmpty)
    }

    // MARK: - 本を受け取る版 / pageKeys

    @Test("本を受け取る版は、本の pageOrderSource に従う")
    func bookOverloadFollowsThePageOrderSource() {
        let keys = ["010.jpg", "002.jpg", "001.jpg"]
        let byName = EffectivePageOrder.orderedPages(
            for: SamplePages.book(sortKeys: keys), pageOrderOverride: nil, excludedKeys: []
        )
        let byDocument = EffectivePageOrder.orderedPages(
            for: SamplePages.book(sortKeys: keys, pageOrderSource: .document),
            pageOrderOverride: nil, excludedKeys: []
        )
        // 名前順のときの並びは環境設定次第なので、ここでは「並べ替えた/並べ替えない」だけを見る。
        #expect(byName.map(\.sortKey) != keys)
        #expect(byDocument.map(\.sortKey) == keys)
    }

    @Test("pageKeys は orderedPages の sortKey の列(ブックマークの添字空間)")
    func pageKeysMatchOrderedPages() {
        let book = SamplePages.book(sortKeys: ["001.jpg", "002.jpg", "003.jpg"])
        let override = ["003.jpg", "002.jpg", "001.jpg"]
        let keys = EffectivePageOrder.pageKeys(
            for: book, pageOrderOverride: override, excludedKeys: ["002.jpg"]
        )
        let pages = EffectivePageOrder.orderedPages(
            for: book, pageOrderOverride: override, excludedKeys: ["002.jpg"]
        )
        #expect(keys == pages.map(\.sortKey))
        #expect(keys == ["003.jpg", "001.jpg"])
    }

    @Test("legacyOrderedPageKeys は、設定に関わらず必ず 1.36 以前の並び")
    func legacyKeysAlwaysUseTheOldOrder() {
        // 鍵を持たない古い pageIndex を鍵へ直す唯一の用途。今の設定で引くと別のページを指す。
        let book = SamplePages.book(sortKeys: ["Com-title.JPG", "_Com-title.JPG", "Com_title.JPG"])
        let legacy = EffectivePageOrder.legacyOrderedPageKeys(
            for: book, pageOrderOverride: nil, excludedKeys: []
        )
        #expect(legacy == ["Com-title.JPG", "Com_title.JPG", "_Com-title.JPG"])
        #expect(legacy == EffectivePageOrder.orderedPages(
            for: book.pages, pageOrderOverride: nil, excludedKeys: [], usesFinderOrderOverride: false
        ).map(\.sortKey))
    }
}

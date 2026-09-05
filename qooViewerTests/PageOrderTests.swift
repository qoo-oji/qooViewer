import Foundation
import Testing

@testable import qooViewer

/// ページの並び順(Services/PageOrder.swift)の比較関数。
///
/// ここを守りたい理由は 1.37 のユーザー報告(`_Com-title-cover.JPG` /
/// `Com_title_name_size_0001.JPG` の並びが Finder と食い違う)で、
/// 「正準順(Finder と同じ)」と「従来順(`.numeric`)」の2つを別物として
/// 保つことがそのまま仕様になっている。片方だけ直すと保存物の並びが崩れる。
struct PageOrderTests {
    // MARK: - 正準順(Finder と同じ)

    @Test("数字は数値として比べる")
    func canonicalComparesNumbersNumerically() {
        #expect(compareCanonicalPageOrder("page2.jpg", "page10.jpg") == .orderedAscending)
        #expect(compareCanonicalPageOrder("page10.jpg", "page9.jpg") == .orderedDescending)
        // 数値として同じなら、0 埋めの少ない方が先(Finder と同じ)。
        #expect(compareCanonicalPageOrder("1.jpg", "001.jpg") == .orderedAscending)
    }

    @Test("大文字小文字だけが違う名前も、必ず同じ順に決着する")
    func canonicalIsATotalOrder() {
        // localizedStandardCompare は "A.jpg" と "a.jpg" に orderedSame を返す。
        // そのままだと sorted の結果が実行のたびに揺れるため、素の比較で決着させている。
        #expect(compareCanonicalPageOrder("A.jpg", "a.jpg") != .orderedSame)
        #expect(compareCanonicalPageOrder("A.jpg", "a.jpg")
            == compareCanonicalPageOrder("A.jpg", "a.jpg"))
        #expect(compareCanonicalPageOrder("a.jpg", "a.jpg") == .orderedSame)
    }

    @Test("先頭のアンダースコアは Finder と同じ位置に入る")
    func canonicalPlacesUnderscoreLikeFinder() {
        // 従来順では "_" (U+005F) が大文字より後・小文字より前に来るため、
        // 大文字始まりの名前と混ざると並びが丸ごと変わる。
        let names = ["Com-title-cover-clean.JPG", "_Com-title-cover.JPG", "Com_title_0001.JPG"]
        let canonical = names.sorted { compareCanonicalPageOrder($0, $1) == .orderedAscending }
        let legacy = names.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        #expect(canonical == [
            "_Com-title-cover.JPG", "Com_title_0001.JPG", "Com-title-cover-clean.JPG",
        ])
        // 従来順ではアンダースコア始まりが最後に回る ―― これが 1.37 の報告そのもの。
        #expect(legacy == [
            "Com-title-cover-clean.JPG", "Com_title_0001.JPG", "_Com-title-cover.JPG",
        ])
    }

    @Test("フルパスを渡してもフォルダごとにまとまる")
    func canonicalGroupsByFolder() {
        let paths = [
            "vol2/001.jpg",
            "vol1/002.jpg",
            "vol1/010.jpg",
            "vol1/009.jpg",
        ]
        #expect(paths.sorted { compareCanonicalPageOrder($0, $1) == .orderedAscending } == [
            "vol1/002.jpg",
            "vol1/009.jpg",
            "vol1/010.jpg",
            "vol2/001.jpg",
        ])
    }

    // MARK: - 表示順の切り替え

    @Test("usesFinderOrder が偽なら従来順(.numeric)になる")
    func effectiveOrderFollowsTheSetting() {
        #expect(comparePageOrder("A.jpg", "a.jpg", usesFinderOrder: false)
            == "A.jpg".compare("a.jpg", options: .numeric))
        #expect(comparePageOrder("A.jpg", "a.jpg", usesFinderOrder: true)
            == compareCanonicalPageOrder("A.jpg", "a.jpg"))
    }

    // MARK: - 設定で並びが変わる本の判定

    @Test("並びが変わらない本には印を付けない")
    func differsByOrderSettingIsFalseForOrdinaryBooks() {
        #expect(PageOrder.differsByOrderSetting(keys: []) == false)
        #expect(PageOrder.differsByOrderSetting(keys: ["001.jpg"]) == false)
        #expect(PageOrder.differsByOrderSetting(
            keys: ["001.jpg", "002.jpg", "010.jpg"]) == false)
    }

    @Test("大文字小文字が混ざった本は真になる")
    func differsByOrderSettingIsTrueForMixedCase() {
        #expect(PageOrder.differsByOrderSetting(
            keys: ["_Com-title-cover.JPG", "Com-title-cover-clean.JPG", "Com_title_0001.JPG"]))
    }
}

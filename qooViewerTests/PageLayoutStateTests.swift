import Foundation
import Testing

@testable import qooViewer

/// ページ単位のレイアウト状態(Models/PageLayoutState.swift)と、EPUB の見開き配置との対応。
///
/// `rawValue` は DB(`PageLayoutOverride`)と書き出した JSON に**そのまま入る識別子**なので、
/// 変えると既存の保存データが読めなくなる。EPUB との相互変換は
/// `LayoutStore.importSourceLayoutIfNeeded`(取り込み)と `EpubExporter`(書き出し)の
/// 両方向で使われるため、往復して元へ戻ることを固定しておく。
struct PageLayoutStateTests {
    @Test("rawValue は保存済みデータの識別子なので変えられない")
    func rawValuesAreFrozen() {
        #expect(PageLayoutState.single.rawValue == "single")
        #expect(PageLayoutState.spreadRight.rawValue == "spreadRight")
        #expect(PageLayoutState.spreadLeft.rawValue == "spreadLeft")
        #expect(PageLayoutState.excluded.rawValue == "excluded")
        // 「レイアウトなし」は値として存在しない(行が無いことで表す)。
        #expect(PageLayoutState.allCases.count == 4)
        #expect(PageLayoutState.allCases.map(\.id) == PageLayoutState.allCases.map(\.rawValue))
    }

    @Test("EPUB の配置からの変換と、EPUB 相当への変換は往復する",
          arguments: [PageSpreadPosition.left, .right, .center])
    func epubSpreadPositionRoundTrips(position: PageSpreadPosition) {
        let state = PageLayoutState(epubSpreadPosition: position)
        #expect(state.asEpubEquivalentSpreadPosition == position)
    }

    @Test("center は単一ページ、left は見開き左、right は見開き右")
    func epubMappingIsExplicit() {
        #expect(PageLayoutState(epubSpreadPosition: .center) == .single)
        #expect(PageLayoutState(epubSpreadPosition: .left) == .spreadLeft)
        #expect(PageLayoutState(epubSpreadPosition: .right) == .spreadRight)
    }

    @Test("除外は EPUB の語彙に無いので nil")
    func exclusionHasNoEpubEquivalent() {
        #expect(PageLayoutState.excluded.asEpubEquivalentSpreadPosition == nil)
    }

    @Test("Codable は rawValue のまま")
    func codableUsesTheRawValue() throws {
        for state in PageLayoutState.allCases {
            let data = try JSONEncoder().encode(state)
            #expect(String(data: data, encoding: .utf8) == "\"\(state.rawValue)\"")
            #expect(try JSONDecoder().decode(PageLayoutState.self, from: data) == state)
        }
    }

    @Test("PageSpreadPosition の rawValue も保存済みデータの識別子")
    func spreadPositionRawValues() {
        #expect(PageSpreadPosition.left.rawValue == "left")
        #expect(PageSpreadPosition.right.rawValue == "right")
        #expect(PageSpreadPosition.center.rawValue == "center")
    }
}

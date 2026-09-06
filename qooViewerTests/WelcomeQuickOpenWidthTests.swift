import Foundation
import SwiftUI
import Testing

@testable import qooViewer

/// ウェルカム画面の一覧の列幅(Views/WelcomeView.swift の `WelcomeQuickOpenWidth`)。
///
/// ユーザー要望から生まれた計算 ―― 「列が狭くてファイル名が『…』で省略され、何の本か
/// 分からない」。実際に表示する名前の長さと、行末の形式バッジの幅を実測して決める。
/// ここで固定するのは寸法そのものではなく、**どんな入力でも守られるべき性質**:
/// 列の数、上限と下限、収まらないときの按分、そして「窓がどれだけ狭くても下限は割らない」。
@MainActor
struct WelcomeQuickOpenWidthTests {
    private func item(_ title: String, bookID: String = "/books/a.cbz") -> WelcomeQuickOpenItem {
        WelcomeQuickOpenItem(id: title, title: title, bookID: bookID, action: {})
    }

    private func column(_ title: String, _ titles: [String],
                        bookID: String = "/books/a.cbz") -> WelcomeQuickOpenColumn {
        WelcomeQuickOpenColumn(title: title, items: titles.map { item($0, bookID: bookID) })
    }

    private func resolved(_ columns: [WelcomeQuickOpenColumn], width: CGFloat) -> [CGFloat] {
        WelcomeQuickOpenWidth.resolved(for: columns, availableWidth: width, locale: Locale(identifier: "en_US"))
    }

    private let shortNames = ["a", "b", "c"]
    private let longNames = [String(repeating: "とても長いファイル名", count: 8)]

    @Test("列が無ければ幅も無い")
    func noColumnsYieldNoWidths() {
        #expect(resolved([], width: 800).isEmpty)
    }

    @Test("返る幅の数は列の数と同じ")
    func oneWidthPerColumn() {
        #expect(resolved([column("履歴", shortNames)], width: 800).count == 1)
        #expect(resolved([column("履歴", shortNames), column("お気に入り", shortNames)], width: 800).count == 2)
    }

    @Test("短い名前でも下限を割らない")
    func shortNamesStillGetTheMinimumWidth() {
        let widths = resolved([column("履歴", ["a"])], width: 2000)
        #expect(widths[0] >= WelcomeQuickOpenWidth.minColumn)
    }

    @Test("名前が極端に長くても上限で頭を押さえる(中央の塊が横に伸びすぎない)")
    func veryLongNamesAreCappedAtTheMaximum() {
        let widths = resolved([column("履歴", longNames)], width: 5000)
        #expect(widths[0] <= WelcomeQuickOpenWidth.maxColumn)
    }

    @Test("長い名前が並ぶ列のほうが広くなる")
    func theColumnWithLongerNamesGetsMoreRoom() {
        let widths = resolved([column("履歴", longNames), column("お気に入り", shortNames)], width: 2000)
        #expect(widths[0] > widths[1])
    }

    @Test("収まるなら希望幅そのまま(窓を広げても縮まない)")
    func aFittingLayoutKeepsTheIdealWidths() {
        let columns = [column("履歴", shortNames), column("お気に入り", shortNames)]
        let atWide = resolved(columns, width: 3000)
        let atWider = resolved(columns, width: 5000)
        #expect(atWide == atWider)
    }

    @Test("収まらないときは希望幅の比で按分し、ウインドウの内側に収める")
    func anOverflowingLayoutIsScaledDownToFit() {
        let columns = [column("履歴", longNames), column("お気に入り", longNames)]
        let available: CGFloat = 700
        let widths = resolved(columns, width: available)

        let spacing = WelcomeQuickOpenWidth.columnSpacing * CGFloat(columns.count - 1)
        let budget = available - WelcomeQuickOpenWidth.windowMargin * 2
        #expect(widths.reduce(0, +) + spacing <= budget)
        // 同じ長さの名前なので、按分の結果もほぼ同じ幅になる。
        #expect(abs(widths[0] - widths[1]) <= 1)
    }

    @Test("窓がどれだけ狭くても下限は割らない(そのときだけ横へはみ出すのを許す)")
    func theMinimumWinsOverAVeryNarrowWindow() {
        let columns = [column("履歴", longNames), column("お気に入り", longNames)]
        let widths = resolved(columns, width: 120)
        #expect(widths.allSatisfy { $0 >= WelcomeQuickOpenWidth.minColumn })
        // 下限 × 2 + 間隔 は 120 より広い ―― つまり意図的にはみ出している。
        let spacing = WelcomeQuickOpenWidth.columnSpacing
        #expect(widths.reduce(0, +) + spacing > 120)
    }

    @Test("片方だけが下限に張り付いたら、余りはもう片方へ配り直す")
    func aPinnedColumnGivesItsSlackToTheOther() {
        // 片方は極端に長く、もう片方は 1 文字。按分だけだと短い側が下限を割る。
        let columns = [column("履歴", longNames), column("お気に入り", ["a"])]
        let available: CGFloat = 460
        let widths = resolved(columns, width: available)

        #expect(widths.allSatisfy { $0 >= WelcomeQuickOpenWidth.minColumn })
        let budget = available - WelcomeQuickOpenWidth.windowMargin * 2
        #expect(widths.reduce(0, +) + WelcomeQuickOpenWidth.columnSpacing <= budget)
    }

    @Test("幅の実測が届く前(0 以下)は、従来の固定幅 520 で見積もる")
    func anUnknownWindowWidthFallsBackToTheAssumedWidth() {
        let columns = [column("履歴", longNames), column("お気に入り", longNames)]
        let atZero = resolved(columns, width: 0)
        let atAssumed = resolved(columns, width: WelcomeQuickOpenWidth.assumedWidth
                                 + WelcomeQuickOpenWidth.windowMargin * 2)
        #expect(atZero == atAssumed)
        #expect(WelcomeQuickOpenWidth.assumedWidth == 520)
    }

    @Test("形式バッジのぶんも見込む(同じ名前でも、バッジが広い形式の列は広くなる)")
    func theFormatBadgeIsIncludedInTheEstimate() {
        // バッジの文字数が違う 2 つ ―― 「7Z」と「フォルダ」(拡張子なし)。
        let narrowBadge = column("履歴", ["同じ長さのファイル名"], bookID: "/books/a.7z")
        let wideBadge = column("履歴", ["同じ長さのファイル名"], bookID: "/books/no-extension")
        let narrow = resolved([narrowBadge], width: 2000)[0]
        let wide = resolved([wideBadge], width: 2000)[0]
        #expect(wide >= narrow)
    }
}

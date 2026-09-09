import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// Lazy コンテナのセルが抱えた画像の帳簿(Views/LazyCellImageBudget.swift)。
///
/// 押さえるのは**作り直しがループしない**こと。帳簿は予算を超えるとコンテナごと作り直す
/// (`epoch` を進める)が、作り直した直後は画面内のセルが読み直されて再び帳簿に乗る。
/// 画面内ぶんだけで予算に達するなら、作り直しが終わらない ―― 下限セル数
/// (`minimumCellCount`)はそれを防ぐためのもので、必ず画面内ぶんより十分大きくなければならない。
/// コレクションの一覧は当初この下限を定数 48 で渡していて、27 インチ 5K で札を最大にすると
/// 画面内の 168 セルだけで 64MB を超えてループする計算だった(監査で指摘 2026-09-09)。
@MainActor
struct LazyCellImageBudgetTests {
    /// 27 インチ 5K の標準解像度(2560×1440pt)にウインドウを広げ、札を最大(320pt)にした
    /// コレクションの一覧。札 1 枚に 2:3 のカバーが 6 枚。
    private static let fiveK = CGSize(width: 2560, height: 1440)
    private static let tile: CGFloat = 320
    private static let spacing: CGFloat = 24
    private static let padding: CGFloat = 24
    private static let cellsPerTile = CoverAspectRatio.portrait.tileCellCount
    /// 横長の画像(1.42)を 2:3 の枠へ入れるときの復号サイズ(約 414×292px、4 バイト/画素)。
    private static let landscapeCoverBytes = 414 * 4 * 292
    private static let budget = 64 * 1024 * 1024

    private var fiveKMinimum: Int {
        LazyCellImageBudget.minimumCellCount(
            visibleSize: Self.fiveK, cellWidth: Self.tile, cellHeight: Self.tile + 24,
            spacing: Self.spacing, padding: Self.padding, cellsPerItem: Self.cellsPerTile
        )
    }

    /// その画面に実際に並ぶセルの数(7 列 × 4 行 × 6 冊)。
    private var fiveKVisibleCells: Int { 7 * 4 * Self.cellsPerTile }

    @Test("下限セル数は、画面内に並びうるセル数(先読み込み)の 3 倍")
    func theMinimumIsThreeScreensWorthOfCells() {
        // 7 列 × (4 行 + 先読み 2 行) × 6 冊 × 3。
        #expect(fiveKMinimum == 7 * 6 * Self.cellsPerTile * 3)
        #expect(fiveKMinimum > fiveKVisibleCells * 3)
        // 大きさがまだ分からない(0×0)うちは、床の 64 に落ちる。
        #expect(
            LazyCellImageBudget.minimumCellCount(
                visibleSize: .zero, cellWidth: 300, cellHeight: 450, spacing: 16, padding: 24
            ) == 64
        )
        // 1 項目 1 セルの一覧(コレクションの中)。3200×1800pt に 300pt の 1:1 のカバー。
        // 10 列 × (6 行 + 2) × 3。
        #expect(
            LazyCellImageBudget.minimumCellCount(
                visibleSize: CGSize(width: 3200, height: 1800), cellWidth: 300, cellHeight: 300,
                spacing: 16, padding: 24
            ) == 10 * 8 * 3
        )
    }

    @Test("画面内ぶんの画像だけでは作り直さない(作り直しがループしない)")
    func aScreenfulAloneNeverTriggersARebuild() {
        var budget = LazyCellImageBudget(byteBudget: Self.budget)
        // 画面内の 168 セルが横長のカバーを抱えると、合計は予算の 64MB を超える(約 81MB)。
        #expect(fiveKVisibleCells * Self.landscapeCoverBytes > Self.budget)
        for _ in 0..<fiveKVisibleCells {
            budget.note(retainedBytes: Self.landscapeCoverBytes, minimumCellCount: fiveKMinimum)
        }
        // それでも作り直さない ―― 下限に届いていないため。作り直した直後の読み直しがまた
        // ここへ来るので、ここで進むと終わらない。
        #expect(budget.epoch == 0)

        // 画面外へ流したぶんが下限まで積もって、初めて 1 回だけ作り直す。
        for _ in fiveKVisibleCells..<fiveKMinimum {
            budget.note(retainedBytes: Self.landscapeCoverBytes, minimumCellCount: fiveKMinimum)
        }
        #expect(budget.epoch == 1)
    }

    @Test("下限が画面内より小さいと、画面内ぶんだけで作り直してしまう(以前の定数 48 の回帰)")
    func aMinimumBelowTheScreenfulRebuildsOnTheScreenfulAlone() {
        var budget = LazyCellImageBudget(byteBudget: Self.budget)
        for _ in 0..<fiveKVisibleCells {
            budget.note(retainedBytes: Self.landscapeCoverBytes, minimumCellCount: 48)
        }
        // これが「ループする」状態。作り直した直後の読み直しで同じことが繰り返される。
        #expect(budget.epoch == 1)
    }

    @Test("予算に届かなければ、いくらセルを数えても作り直さない")
    func theByteBudgetStillGates() {
        var budget = LazyCellImageBudget(byteBudget: Self.budget)
        for _ in 0..<(fiveKMinimum * 2) {
            budget.note(retainedBytes: 1024, minimumCellCount: fiveKMinimum)
        }
        #expect(budget.epoch == 0)
    }
}

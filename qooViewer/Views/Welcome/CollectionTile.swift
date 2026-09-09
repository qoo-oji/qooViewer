import CoreGraphics
import SwiftUI

/// コレクション1つ分のタイル(改善要望5)。中身のカバーを最大6冊ぶん3×2で敷き詰めた
/// 角丸の札で、クリックするとその中へ入る。
///
/// ■ なぜ3×2なのか
/// セルの縦横比は2:3(CollectionCoverThumbnail)なので、3列2行にすると
/// 「幅 = 3w + 2s」「高さ = 2 × 1.5w + s = 3w + s」となり、**札全体がほぼ正方形になる**。
/// 縦横比の指定を別に書かなくても正方形に落ち着くので、タイルの大きさはスライダーの値
/// (LazyVGridの`.adaptive(minimum:)`)にそのまま従わせられる。
///
/// ■ 編集モードでは「選ぶ」
/// 編集モード中はクリックが**中へ入る**から**選ぶ/選び直す**に変わり、左上に選択の印
/// (SelectionCheckmarkBadge)が出る。選んだコレクションは右上のゴミ箱でまとめて削除できる。
/// 編集モード中に中へ入りたいときは右クリックの「開く」から(CollectionGridView)。
///
/// ■ 輪郭(すりガラス面の決まりごと)
/// - カバー画像・自前の地を持つ冊数バッジ・選択の印 → 何も付けない
/// - 札の下に置く名前 → `.panelOutlinedContent()`
/// - 選択中を示すアクセント色の枠 → `.panelOutlinedAccent(in:)`(面をアクセント色で
///   塗られると、枠だけが頼りの「選んである」が地に溶けるため)
struct CollectionTile: View {
    let collection: BookCollection
    /// 表示する本(並び替え済み)。先頭6冊だけを描く。
    let items: [CollectionItem]
    /// この本の実体が見つかっているか。
    let exists: (CollectionItem) -> Bool
    /// いま抽出中か。
    let isExtracting: (CollectionItem) -> Bool
    let coverStore: CollectionCoverStore
    /// タイルの一辺の目安(スライダーの値)。角丸とセルの復号サイズの見積もりに使う。
    let size: CGFloat
    var onImageRetained: ((CGImage) -> Void)?
    /// 編集モードか。クリックの意味(開く/選ぶ)がこれで変わる。
    var isEditing: Bool = false
    var isSelected: Bool = false
    let onOpen: () -> Void
    /// 編集モード中のクリック。
    var onToggleSelection: () -> Void = {}

    /// 3×2のセルの間隔。
    private static let cellSpacing: CGFloat = 3
    /// 札の内側の余白。
    private static let padding: CGFloat = 6

    /// セル1つの実寸の見積もり(復号サイズの上限にだけ使う。実際の割り付けはGridが決める)。
    private var cellWidth: CGFloat {
        (size - Self.padding * 2 - Self.cellSpacing * 2) / 3
    }

    /// 札の角丸。選択の枠も同じ形で描く。
    private var cornerRadius: CGFloat { size * 0.08 }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                if isEditing {
                    onToggleSelection()
                } else {
                    onOpen()
                }
            } label: {
                artwork
            }
            .buttonStyle(.plain)

            Text(collection.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .panelOutlinedContent()
        }
        .help(collection.name)
    }

    private var artwork: some View {
        Grid(horizontalSpacing: Self.cellSpacing, verticalSpacing: Self.cellSpacing) {
            GridRow {
                cell(0); cell(1); cell(2)
            }
            GridRow {
                cell(3); cell(4); cell(5)
            }
        }
        .padding(Self.padding)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        // 冊数バッジ。自前の塗り地を持つので輪郭は付けない(すりガラス面の決まりごとの例外側)。
        .overlay(alignment: .bottomTrailing) {
            Text("\(collection.items.count)")
                .font(.caption)
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.55))
                .foregroundStyle(Color.white)
                .clipShape(Capsule())
                .padding(6)
        }
        // 選択中の枠。印だけだと、札が小さいときにどれを選んだのか一目で分からない。
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(isSelected ? 1 : 0)
        }
        .panelOutlinedAccent(
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            isEnabled: isSelected
        )
        // 選択の印。編集モードのときだけ出す。
        .overlay(alignment: .topLeading) {
            if isEditing {
                SelectionCheckmarkBadge(isSelected: isSelected, size: size)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func cell(_ index: Int) -> some View {
        if index < items.count {
            let item = items[index]
            CollectionCoverThumbnail(
                item: item,
                coverStore: coverStore,
                displayWidth: cellWidth,
                exists: exists(item),
                isExtracting: isExtracting(item),
                onImageRetained: onImageRetained
            )
        } else {
            // 6冊に満たないぶんは、同じ大きさの空きとして残す(詰めて並べると、冊数によって
            // 札の中の割り付けが変わり、一覧が揃って見えない)。
            Color.clear
                .aspectRatio(CollectionCoverThumbnail.aspectRatio, contentMode: .fit)
        }
    }
}

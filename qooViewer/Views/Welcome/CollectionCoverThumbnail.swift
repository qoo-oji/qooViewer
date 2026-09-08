import CoreGraphics
import SwiftUI

/// コレクションのカバー画像1枚分のセル(改善要望5)。コレクションのタイル(3×2の小さな枠)と
/// コレクションの中(スライダーで大きさを変えられる一覧)の**両方**が同じこの部品を使う。
///
/// ■ 縦横比は2:3で固定
/// 横長のカバーは**保存の時点で**2:3へトリミング済み(CoverImageResolver.croppedForGrid)なので、
/// ここで縦横比を仮定してよい。縦長のカバーは元の比のままなので、`.scaledToFill()`で枠を
/// 埋めて余った上下を切る ―― 一覧としては、比の違う画像が背の高さをばらつかせるより、
/// 同じ大きさの札が整然と並ぶほうが目的(どの本かを見分ける)に適う。
///
/// ■ 状態の描き分け
/// - `.pending`(まだ抽出していない): 薄い地だけ。抽出中(`isExtracting`)ならスピナーを重ねる
/// - `.failed`(壊れている・実体が見つからない): 灰色の地 + 形式バッジ。何の本かは分かる
/// - `.ready`: カバー画像
/// 実体が見つからない本(`exists == false`)は、状態に関わらず全体を淡く描く。
///
/// ■ 輪郭(すりガラス面の決まりごと)
/// 画像・自前の地を持つ形式バッジのどちらも輪郭を付けない側なので、この部品自体には
/// `.panelOutlinedContent()`を掛けない(CLAUDE.mdの表参照)。
struct CollectionCoverThumbnail: View {
    /// セルの縦横比(幅 ÷ 高さ)。タイルの中の3×2の割り付けもこの値から決まる。
    static let aspectRatio: CGFloat = CoverImageResolver.gridAspectRatio

    let item: CollectionItem
    let coverStore: CollectionCoverStore
    /// 表示上の幅(pt)。復号する画素数の上限を決めるためだけに使う(枠の大きさはレイアウトが
    /// 決める)。CollectionCoverStore.image(for:maxPixelSize:)のコメント参照。
    let displayWidth: CGFloat
    /// 本の実体が見つかっているか(CollectionStore.cachedFileExists)。
    var exists: Bool = true
    /// いまカバーを抽出中か(CollectionCoverExtractor.inFlightItemIDs)。
    var isExtracting: Bool = false
    /// 保持した画像の大きさを呼び出し側の帳簿(LazyCellImageBudget)へ伝える。
    var onImageRetained: ((CGImage) -> Void)?

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            switch item.coverState {
            case .ready:
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder(Color.primary.opacity(0.06))
                }
            case .pending:
                placeholder(Color.primary.opacity(0.06))
                if isExtracting {
                    ProgressView()
                        .controlSize(.small)
                }
            case .failed:
                placeholder(Color.primary.opacity(0.12))
                FormatBadgeView(bookID: item.bookID)
                    // 小さいセルではバッジがはみ出すので、収まらないときは黙って消す。
                    .fixedSize()
                    .scaleEffect(min(1, displayWidth / 60))
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: max(2, displayWidth * 0.03), style: .continuous))
        .opacity(exists ? 1 : 0.35)
        // 抽出のやり直し(カバーの変更・読み方向の変更)はcoverStatusをいったん.pendingへ戻して
        // から.readyにするため、状態を鍵に含めておけば読み直しの契機になる。
        .task(id: "\(item.id.uuidString)-\(item.coverStatus)") {
            await loadImage()
        }
    }

    private func placeholder(_ color: Color) -> some View {
        Rectangle().fill(color)
    }

    private func loadImage() async {
        guard item.coverState == .ready else {
            if image != nil { image = nil }
            return
        }
        // Retinaぶんを見込んで実寸の2倍まで。保存してあるのが512pxなので、それを超える指定を
        // しても元より大きくはならない。
        let loaded = await coverStore.image(
            for: item.id, maxPixelSize: max(1, displayWidth * 2)
        )
        guard !Task.isCancelled else { return }
        image = loaded
        if let loaded { onImageRetained?(loaded) }
    }
}

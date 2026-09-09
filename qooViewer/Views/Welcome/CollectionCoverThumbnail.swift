import CoreGraphics
import SwiftUI

/// コレクションのカバー画像1枚分のセル(改善要望5)。コレクションのタイル(札の中の小さな枠)と
/// コレクションの中(スライダーで大きさを変えられる一覧)、そしてメタデータ編集シートの
/// プレビューが、すべて同じこの部品を使う。
///
/// ■ 縦横比とトリミング
/// 枠の比は**ライブラリごと**に 2:3 か 1:1 を選べる(CoverAspectRatio)。保存してあるカバーは
/// **切っていない**ので、比が合わないぶんは表示のたびにここで切る
/// (CoverImageResolver.cropped(_:to:anchor:)。なぜ保存時ではなく表示時なのかもそちらのコメント)。
/// どこを残すかは呼び出し側が解決済みの`anchor`で渡す(本ごとの上書き → ライブラリの既定)。
///
/// 切ったうえでなお端数が出るぶんは`.scaledToFill()`で埋める ―― 一覧としては、比の違う画像が
/// 背の高さをばらつかせるより、同じ大きさの札が整然と並ぶほうが目的(どの本かを見分ける)に適う。
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
    /// セルの角丸。選択中の枠(CollectionDetailView)も同じ形で描くため、ここを正典にする。
    static func cornerRadius(forWidth width: CGFloat) -> CGFloat {
        max(2, width * 0.03)
    }

    let item: CollectionItem
    let coverStore: CollectionCoverStore
    /// 枠の縦横比(このカバーが属するライブラリの設定)。
    let aspectRatio: CoverAspectRatio
    /// 比が合わないときに残す位置。呼び出し側が「本ごとの上書き ?? ライブラリの既定」を
    /// 解決して渡す(この部品はDBを見ない)。
    var anchor: CoverCropAnchor = .center
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
        .aspectRatio(aspectRatio.value, contentMode: .fit)
        .clipShape(
            RoundedRectangle(
                cornerRadius: Self.cornerRadius(forWidth: displayWidth), style: .continuous
            )
        )
        .opacity(exists ? 1 : 0.35)
        // 読み直しの契機は3つ。抽出のやり直し(カバーの変更)はcoverStatusをいったん.pendingへ
        // 戻してから.readyにするので状態を鍵に含め、比と位置は**切り直し**が要るので含める
        // (歯車で比を変えた瞬間に、抽出を待たずに一覧が変わるのはこのため)。
        .task(id: "\(item.id.uuidString)-\(item.coverStatus)-\(aspectRatio.rawValue)-\(anchor.rawValue)") {
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
        let loaded = await coverStore.image(for: item.id, maxPixelSize: decodeMaxPixelSize)
        guard !Task.isCancelled else { return }
        guard let loaded else {
            image = nil
            return
        }
        // 帳簿へは**切る前**の画像を渡す。CGImage.cropping(to:)が返すのは元画像を参照する
        // 部分画像で、実際に確保されている画素は切る前のぶんだから(LazyCellImageBudget)。
        onImageRetained?(loaded)
        image = CoverImageResolver.cropped(loaded, to: aspectRatio.value, anchor: anchor)
    }

    /// 復号する画素数の上限。Retinaぶんを見込んで実寸の2倍を要求するが、**切って捨てるぶんを
    /// 見込んで大きめに**求める ―― 幅を半分に切る画像を実寸の2倍で復号すると、切った後は
    /// 実寸ちょうどになってしまう。元の比はDBに控えてある(CollectionItem.coverAspect)ので、
    /// 復号する前に必要な大きさが分かる。
    ///
    /// 保存してあるのは長辺768px(CollectionCoverStore.maxPixelSize)までなので、それを超える
    /// 指定をしても元より大きくはならない(ImageIOは引き伸ばさない)。
    private var decodeMaxPixelSize: CGFloat {
        let neededWidth = max(1, displayWidth * 2)
        let target = aspectRatio.value
        let imageAspect = item.coverAspect > 0 ? CGFloat(item.coverAspect) : target
        if imageAspect > target {
            // 左右を切る。切った後の幅がneededWidthになるように、元の幅を逆算する。
            return neededWidth / target * max(imageAspect, 1)
        } else {
            // 上下を切る。幅はそのまま残るので、長辺(高さ)のぶんだけ見込む。
            return neededWidth * max(1, 1 / max(imageAspect, 0.01))
        }
    }
}

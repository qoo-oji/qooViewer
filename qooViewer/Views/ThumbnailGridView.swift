import SwiftUI
import CoreGraphics
import Combine

/// ページのサムネイル一覧画面(cooViewerの「一覧表示画面」に相当)。
/// クリックでそのページへジャンプする。
///
/// 以前は独立したシート(.sheet)として表示し、「閉じる」ボタンか並び順を反転するボタンを
/// ツールバーに持っていたが、ユーザー要望により「閉じる」ボタンと並び替え機能を廃止し、
/// 代わりにビューア画面(このパネルの外側)をクリックすると閉じるようにした。そのため
/// シートではなくViewerView.mainZStack内の1レイヤーとして重ねて表示する形に変更し
/// (ViewerView.applySheets/mainZStackのコメント参照)、閉じる操作は`@Environment(\.dismiss)`
/// ではなく`isPresented`(呼び出し元のshowThumbnailGrid)を直接falseにする形にしている。
///
/// パネル自体の大きさは、以前は5列表示に必要な幅だけに留めていた(ユーザー要望)が、その後の
/// 要望(サムネイルのサイズを変えたい・パネルまでの余白を設定したい)により、画像表示領域から
/// 環境設定の余白(上下・左右の%)を引いた大きさになった(bodyのコメント参照)。ビューア画面
/// いっぱいを覆う透明な背景レイヤーは、このビュー自身ではなくViewerView.mainZStack側
/// (ThumbnailGridBackdropView)が担当し、「パネルの外側=ビューア画面のどこをクリックしても
/// 閉じる」を実現している。
struct ThumbnailGridView: View {
    @ObservedObject var viewModel: ViewerViewModel
    @Binding var isPresented: Bool

    /// パネル本体(背景のマテリアルを持つ矩形)のスクリーン座標系でのフレームを報告する。
    /// ViewerViewが「パネルの外側をクリックしたら閉じる」判定に使う。以前はViewerView側で
    /// このビュー全体の.backgroundとして取っていたが、パネルが余白を含む領域いっぱいに
    /// 広がる構成(bodyのGeometryReader参照)になったため、パネル本体に直接付ける必要がある。
    var onPanelScreenFrameChange: (CGRect) -> Void = { _ in }
    @EnvironmentObject private var preferences: AppPreferences

    private static let contentPadding: CGFloat = 16

    /// 利用できる幅に何列入るか。サムネイルのサイズと横の間隔(どちらも環境設定)から決める。
    ///
    /// 経緯: 最初は`GridItem(.adaptive(minimum: 120))`で幅に応じた自動列数、次にユーザー要望で
    /// 「リサイズのたびに折り返し位置が変わって迷う」ため5列×120pt固定(パネル幅もそこから逆算)
    /// になり、その後さらに「サムネイルのサイズをスライダーで変えたい。段数はそれに合わせて
    /// 自動で変わってほしい」という要望で現在の形になった。列数はサイズ・間隔・パネル幅
    /// (=画像表示領域から環境設定の余白を引いたもの)から決まるので、ウインドウをリサイズ
    /// すれば変わりうる点は、2番目の要望と相反するが、3番目の要望を優先した。
    /// サムネイル1枚の一辺(pt)。環境設定の値を、スライダーが許す範囲へ収めてから使う。
    ///
    /// スライダー経由では範囲外になりようがないが、UserDefaultsを直接書き換えられていた場合に
    /// 0が入ると、下のcolumnCountの割り算が0除算になり`Int(nan)`で**実行時トラップする**
    /// (レイアウトが崩れるだけでは済まない)。RecentFilesStore.maxCountが保存件数を
    /// 同じように読み出し時にクランプしているのと同じ考え方。
    private var cellSize: CGFloat {
        let range = AppPreferences.thumbnailGridCellSizeRange
        return CGFloat(min(max(preferences.thumbnailGridCellSize, range.lowerBound), range.upperBound))
    }

    /// サムネイル同士の横の間隔(pt)。負の値を弾くためにクランプする(理由はcellSizeと同じ)。
    private var horizontalSpacing: CGFloat {
        let range = AppPreferences.thumbnailGridSpacingRange
        return CGFloat(
            min(max(preferences.thumbnailGridHorizontalSpacing, range.lowerBound), range.upperBound)
        )
    }

    private func columnCount(forPanelWidth width: CGFloat) -> Int {
        let available = width - Self.contentPadding * 2
        return max(1, Int(((available + horizontalSpacing) / (cellSize + horizontalSpacing)).rounded(.down)))
    }

    var body: some View {
        // パネルの大きさは「画像表示領域から、環境設定の余白(上下・左右それぞれ片側の%)を
        // 引いた残り」。列数はその幅から自動で決まる(columnCount(forPanelWidth:))。
        // このビュー自身は画像表示領域いっぱいに広がり、パネル本体をその中央に置く。
        GeometryReader { geometry in
            let hMargin = geometry.size.width * CGFloat(preferences.thumbnailGridHorizontalMarginPercent) / 100
            let vMargin = geometry.size.height * CGFloat(preferences.thumbnailGridVerticalMarginPercent) / 100
            let panelWidth = max(geometry.size.width - hMargin * 2, 120)
            let panelHeight = max(geometry.size.height - vMargin * 2, 120)
            let cell = cellSize
            let hSpacing = horizontalSpacing
            let count = columnCount(forPanelWidth: panelWidth)
            let columns = Array(repeating: GridItem(.fixed(cell), spacing: hSpacing), count: count)
            // 固定幅の列はLazyVGridの先頭(左)から詰められるので、グリッド自体の幅を列数ぶんに
            // 絞ってから中央に置く(そうしないと右側だけ余る)。
            let gridWidth = CGFloat(count) * cell + CGFloat(max(count - 1, 0)) * hSpacing

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    (Text("Page List (Total ") + Text("\(viewModel.pageCount)") + Text(" pages)"))
                        .font(.headline)
                    Spacer(minLength: 8)
                    // サムネイルのサイズをその場で変えるスライダー(ユーザー要望)。値は環境設定と
                    // 共通(AppPreferences.thumbnailGridCellSize)なので、次回以降も引き継がれる。
                    Image(systemName: "photo")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $preferences.thumbnailGridCellSize,
                        in: AppPreferences.thumbnailGridCellSizeRange
                    )
                    .frame(width: 140)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Thumbnail Size"))
                    Image(systemName: "photo")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .padding()

                ScrollView {
                    LazyVGrid(columns: columns, spacing: CGFloat(preferences.thumbnailGridVerticalSpacing)) {
                        ForEach(0..<viewModel.pageCount, id: \.self) { index in
                            Button {
                                viewModel.jump(toPageIndex: index)
                                isPresented = false
                            } label: {
                                ThumbnailCell(
                                    viewModel: viewModel, index: index, isCurrent: index == viewModel.currentIndex,
                                    cellSize: cell
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: gridWidth)
                    .frame(maxWidth: .infinity)
                    .padding(Self.contentPadding)
                }
            }
            .frame(width: panelWidth, height: panelHeight)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
            .contentShape(Rectangle())
            .onTapGesture {
                isPresented = false
            }
            .background(PanelScreenFrameAccessor(onChange: onPanelScreenFrameChange))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// ThumbnailGridViewの背後に敷く、ビューア画面いっぱいの透明な背景レイヤー。
/// ユーザー要望: ページ一覧パネルの外側(＝ビューア画面)をクリックしたら閉じるようにしたい。
/// パネル自体は5列表示に必要な幅だけに留めているため(ThumbnailGridView.panelWidth参照)、
/// パネルの外側は依然としてビューア画面のクリックとして扱われる必要があり、この透明な
/// レイヤーがビューア画面全体を覆ってそのクリックを受け止める。
struct ThumbnailGridBackdropView: View {
    @Binding var isPresented: Bool

    var body: some View {
        Color.black.opacity(0.001)
            .contentShape(Rectangle())
            .onTapGesture {
                isPresented = false
            }
    }
}

/// グリッドの1セル。あえて `@ObservedObject` にせず素の参照として `viewModel` を持つ。
/// ページ一覧は数十〜数百セル並ぶことがあり、`@ObservedObject` で ViewerViewModel 全体を
/// 購読してしまうと、どこか1セルのサムネイル読み込みが完了するたびに
/// (@Publishedプロパティの更新経由で)画面内の全セルが再描画対象になってしまう。
/// ここでは各セルが自分専用の `@State` で結果を保持し、`.task(id:)` で1回だけ非同期取得することで、
/// 再描画がそのセル自身に閉じるようにしている。
private struct ThumbnailCell: View {
    let viewModel: ViewerViewModel
    let index: Int
    let isCurrent: Bool
    /// サムネイル枠の一辺(pt)。AppPreferences.thumbnailGridCellSize(以前は120固定)。
    let cellSize: CGFloat
    @EnvironmentObject private var preferences: AppPreferences
    @State private var image: CGImage?

    /// カーソルが小さいサムネイルの上にあるかどうか。拡大プレビュー用のpopoverの表示制御に使う
    /// (BookmarkListView.PageRowView.thumbnailPreviewContentと同じ考え方・同じ操作性を、
    /// この「ページ一覧」グリッドにも移植してほしいというユーザー要望)。
    @State private var isHoveringThumbnail = false
    /// 拡大プレビュー用のフル解像度画像。一度読み込めば、同じセルを何度ホバーしても読み込み直さない
    /// よう@Stateにキャッシュしておく(素早くホバーを出し入れしたときのちらつき防止)。
    @State private var previewImage: CGImage?
    /// ホバー開始から実際にpopoverを出すまでの遅延用タスク。
    @State private var hoverPreviewTask: Task<Void, Never>?
    /// ホバー開始から実際にpopoverを出すまでの遅延(ナノ秒)。BookmarkListView.PageRowViewの
    /// hoverPreviewDelayNanosecondsと同じ値(350ms)を使う。

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.15))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(2)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: cellSize, height: cellSize)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            // カーソルをホバーしている間、大きなプレビューとファイル名を表示する(ユーザー要望)。
            // BookmarkListView.PageRowViewと同じく、ホバーした瞬間に即座にpopoverを出さず、
            // 一定時間(hoverPreviewDelayNanoseconds)ホバーし続けた場合にだけ表示する。
            .onHover { hovering in
                hoverPreviewTask?.cancel()
                // ON/OFF(showThumbnailHoverPreview)はページ一覧だけに効く設定。遅延
                // (thumbnailHoverPreviewDelay)はサイドパネル等の同種のプレビューと共通。
                if hovering, preferences.showThumbnailHoverPreview {
                    hoverPreviewTask = Task {
                        try? await Task.sleep(nanoseconds: preferences.thumbnailHoverPreviewDelayNanoseconds)
                        guard !Task.isCancelled else { return }
                        isHoveringThumbnail = true
                    }
                } else {
                    hoverPreviewTask = nil
                    isHoveringThumbnail = false
                }
            }
            .popover(isPresented: $isHoveringThumbnail, arrowEdge: .trailing) {
                thumbnailPreviewContent
            }
            Text("\(index + 1)")
                .font(.caption2)
                // ユーザー報告: .secondary(グレー)だと、サムネイル一覧パネルの背景
                // (.regularMaterial)上では視認性が悪い。白固定にして見やすくする。
                .foregroundStyle(.white)
        }
        .task(id: index) {
            image = await viewModel.loadThumbnail(at: index)
            // 環境設定「表示中のサムネイルの拡大画像を先読み」: 見えているセルの原寸画像を
            // 先にデコードしておく(PageLoaderのメモリキャッシュに載るので、プレビューが即座に
            // 出る)。LazyVGridは画面内のセルしか作らないため「表示中」に自然と限定される。
            if preferences.preloadThumbnailGridPreviews, preferences.showThumbnailHoverPreview,
               previewImage == nil, !Task.isCancelled {
                previewImage = await viewModel.pageImage(at: index)
            }
        }
    }

    /// サムネイルをホバーしたときのpopoverの中身。フル解像度画像(previewImage)とファイル名を
    /// 縦に並べる。BookmarkListView.PageRowView.thumbnailPreviewContentと同じ構成・同じサイズ
    /// (440x440)にしている。popoverが実際に画面へ表示されるたびに.taskが実行される
    /// (SwiftUIのpopoverは表示のたびにコンテンツビューを作り直すため)ので、まだ読み込んでいなければ
    /// そこで読み込む。previewImageは@Stateとして親(ThumbnailCell)側に持たせているため、閉じて
    /// 再度ホバーしても読み込み直さない。
    private var thumbnailPreviewContent: some View {
        VStack(spacing: 8) {
            Group {
                if let previewImage {
                    Image(decorative: previewImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 440, height: 440)

            Text(displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(12)
        .task {
            guard previewImage == nil else { return }
            previewImage = await viewModel.pageImage(at: index)
        }
    }

    /// プレビュー下に表示するファイル名。範囲外(理論上は起こらないはずだが、念のため)の場合は
    /// 空文字にしておく。
    private var displayName: String {
        guard viewModel.book.pages.indices.contains(index) else { return "" }
        return viewModel.book.pages[index].displayName
    }
}

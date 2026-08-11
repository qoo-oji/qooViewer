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
/// パネル自体の大きさは、以前のシートと同じく5列表示に必要な幅(gridWidth)だけに留め、
/// ビューア画面いっぱいには広げない(ユーザー要望: 以前のシートのように、5列表示に必要な
/// 幅だけのオーバーレイにしたい)。ビューア画面いっぱいを覆う透明な背景レイヤーは、この
/// ビュー自身ではなくViewerView.mainZStack側(ThumbnailGridBackdropView)が担当し、
/// 「パネルの外側=ビューア画面のどこをクリックしても閉じる」を実現している。
struct ThumbnailGridView: View {
    @ObservedObject var viewModel: ViewerViewModel
    @Binding var isPresented: Bool

    /// ユーザー要望: 列数がウインドウ幅に応じて変わる(.adaptive)と、リサイズのたびに
    /// 折り返し位置が変わって「さっきまであったページがどこに行ったか分からなくなる」ため、
    /// 常に5列で固定表示してほしいとのこと。以前は`GridItem(.adaptive(minimum: 120), spacing: 10)`
    /// (1要素だけをLazyVGridのcolumns:に渡し、幅に応じて列数が自動計算される書き方)だった。
    /// セル自体のサイズ・間隔(120x120、spacing 10)はそのまま維持し、列数だけを5に固定する。
    private static let columnCount = 5
    private static let cellSize: CGFloat = 120
    private static let cellSpacing: CGFloat = 10
    private static let contentPadding: CGFloat = 16
    /// パネル全体の幅。5列ぶんのセル・列間隔・左右の余白から算出する(ユーザー要望:
    /// 5列表示に必要な幅だけのオーバーレイにしたい。この幅を超えて広がらないようにする)。
    private static let panelWidth: CGFloat =
        CGFloat(columnCount) * cellSize + CGFloat(columnCount - 1) * cellSpacing + contentPadding * 2

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: cellSpacing), count: columnCount
    )

    var body: some View {
        VStack(spacing: 0) {
            (Text("Page List (Total ") + Text("\(viewModel.pageCount)") + Text(" pages)"))
                .font(.headline)
                .padding()

            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.cellSpacing) {
                    ForEach(0..<viewModel.pageCount, id: \.self) { index in
                        Button {
                            viewModel.jump(toPageIndex: index)
                            isPresented = false
                        } label: {
                            ThumbnailCell(viewModel: viewModel, index: index, isCurrent: index == viewModel.currentIndex)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Self.contentPadding)
            }
        }
        // ユーザー要望: 横方向は5列表示に必要な幅だけに留めつつ、縦方向はウインドウいっぱいを
        // 使いたい。幅は固定(panelWidth)、高さはmaxHeight: .infinityで親(ThumbnailGridBackdropView
        // と同じZStack)の高さいっぱいまで伸ばす。
        .frame(width: Self.panelWidth)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        // パネル自身の背景(タイトル部分やサムネイル間の余白)をクリックしても閉じるようにする。
        // 各サムネイルは独立したButtonのため、そちらのタップは(SwiftUIの通常のヒットテスト
        // 優先順位により)このジェスチャーより優先され、意図せず同時に閉じてしまうことはない。
        // .contentShape(Rectangle())で、余白部分(何も描画されていない領域)も含めた
        // フレーム全体をタップ判定の対象にする。パネルの外側(ビューア画面)のクリックは
        // ThumbnailGridBackdropView側が別途処理する。
        .contentShape(Rectangle())
        .onTapGesture {
            isPresented = false
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
    private static let hoverPreviewDelayNanoseconds: UInt64 = 350_000_000

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
            .frame(width: 120, height: 120)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            // カーソルをホバーしている間、大きなプレビューとファイル名を表示する(ユーザー要望)。
            // BookmarkListView.PageRowViewと同じく、ホバーした瞬間に即座にpopoverを出さず、
            // 一定時間(hoverPreviewDelayNanoseconds)ホバーし続けた場合にだけ表示する。
            .onHover { hovering in
                hoverPreviewTask?.cancel()
                if hovering {
                    hoverPreviewTask = Task {
                        try? await Task.sleep(nanoseconds: Self.hoverPreviewDelayNanoseconds)
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

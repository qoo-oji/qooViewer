import SwiftUI
import AppKit
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
    /// サムネイルの右クリック →「画像をエクスポート」で呼ぶ処理(ユーザー要望)。
    /// 書き出しの実装はViewerViewが持っているため、ページ番号を渡すクロージャとして受け取る。
    var onExportPage: ((Int) -> Void)?
    /// サムネイルの右クリック →「このページをブックマークに追加/削除」(ユーザー要望)。
    /// onExportPageと同じ理由で、実装を持つViewerViewからクロージャとして受け取る。
    var onToggleBookmark: ((Int) -> Void)?

    /// パネル本体(背景のマテリアルを持つ矩形)のスクリーン座標系でのフレームを報告する。
    /// ViewerViewが「パネルの外側をクリックしたら閉じる」判定に使う。以前はViewerView側で
    /// このビュー全体の.backgroundとして取っていたが、パネルが余白を含む領域いっぱいに
    /// 広がる構成(bodyのGeometryReader参照)になったため、パネル本体に直接付ける必要がある。
    var onPanelScreenFrameChange: (CGRect) -> Void = { _ in }
    /// ホイールのスクロール量を自前で決めるNSEventローカルモニタの預かり先。
    ///
    /// 取り付け・取り外しはこのビューが行うが、**持ち主はViewerView**である。
    /// ページ一覧を出したままウインドウごと閉じられると、このビューの`.onDisappear`は
    /// 呼ばれないことがあり(このリポジトリで確認済みの挙動)、ここで持つとモニタが
    /// 残ってしまう。ViewerViewの`@State`にしておけば、あちらの`handleOnDisappear`からも
    /// 確実に外せる ―― 各モニタの解除を二重に置く、既存のやり方に揃えたもの
    /// (ViewerView.thumbnailGridWheelMonitor参照)。
    @Binding var wheelMonitor: Any?
    @EnvironmentObject private var preferences: AppPreferences

    private static let contentPadding: CGFloat = 16

    /// このセル高さ(pt)のサムネイルを、ぼやけずに描くのに要するデコード解像度(px)。
    /// セルの高さ×画面倍率を、120px刻みのバケットへ量子化する(スライダーを少し動かすたびに
    /// 別解像度で再デコード・キャッシュが断片化するのを防ぐ)。下限240px(進捗バーと同等)、
    /// 上限720px(最大セル320pt×2倍=640pxを1段上へ丸めた値)。
    private static func gridThumbnailPixelSize(forCellHeight height: CGFloat) -> CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let bucketed = (height * scale / 120).rounded(.up) * 120
        return min(max(bucketed, 240), 720)
    }
    /// セル枠の縦横比(幅/高さ)。以前は正方形(120×120)だったが、漫画のページはほぼ縦長なので
    /// 正方形の枠だと左右に常にプレースホルダーの余白が残り、「横の間隔を0にしても間隔が空いた
    /// まま」に見えた(ユーザー報告)。サイドパネルのページモード(SidePanelPageCell、高さ×0.75)と
    /// 同じ縦長の枠にして、枠とページの余白をほぼ無くす。見開き合成などの横長ページは上下に
    /// 余白が出るが、そちらは少数派。環境設定「サムネイルのサイズ」は枠の高さを指す。
    /// セル枠の縦横比(幅/高さ)の初期値。実際のページのサムネイルが1枚でも読めたら、その実寸から
    /// 測った縦横比(measuredPageAspect)へ差し替える。以前は0.75固定だったが、多くの漫画はもっと
    /// 縦長(≒0.66)で、固定値だとページより枠が広く、サムネイルの左右にプレースホルダの余白が
    /// 残ってしまった(ユーザー報告)。実測に合わせることで、ページが均一な本ではレターボックスが
    /// 出ず、枠がページにぴったり収まる。
    private static let defaultCellAspectRatio: CGFloat = 0.66

    /// ホイールでのスクロール量を自前で決めるために掴んでおく、裏のNSScrollView
    /// (ScrollViewAccessor参照)。参照型の入れ物にしてあるのは、NSEventモニタの
    /// クロージャから常に最新の値を読む必要があるため(ViewerViewの同名の入れ物と同じ)。
    @State private var scrollGeometryBox = ScrollGeometryBox()

    /// セルが@Stateに保持したサムネイル・プレビューの合計量の帳簿。LazyVGridは画面外へ
    /// 出たセルの保持物を解放しないため、予算(256MB)を超えたらグリッドを`.id(epoch)`で
    /// 作り直してまとめて解放する(仕組みと実測の詳細はLazyCellImageBudgetの型コメント参照)。
    /// 作り直してもScrollViewは残るのでスクロール位置は保たれ、画面内のセルだけが
    /// 読み直される(多くはgridThumbnailCacheから即座に復元される)。
    @State private var cellImageBudget = LazyCellImageBudget(byteBudget: 256 * 1024 * 1024)

    /// 実際に読み込めたサムネイルから測った縦横比(幅/高さ)のサンプル。列幅は「最初の1枚」では
    /// なく、ここに溜めた**複数ページの中央値**から決める。先頭だけ横長のカバーがある本
    /// (ユーザー報告)で、その1枚に列全体の幅が引きずられないようにするため。中央値なら
    /// 少数の外れ値(横長カバーや見開き)は無視され、多数派の通常ページに枠が合う。
    @State private var aspectSamples: [CGFloat] = []
    /// 中央値を確定したら以降は動かさない(サンプルが増えるたびに列幅がぶれてちらつくのを防ぐ)。
    @State private var measuredPageAspect: CGFloat?
    /// 中央値を確定するのに必要なサンプル数。短い本では総ページ数で頭打ちにする。
    private var aspectSampleTarget: Int { min(viewModel.pageCount, 9) }

    /// 実際に使う縦横比。確定前は既定値。極端な値でレイアウトが破綻しないよう安全域へ収める。
    private var effectiveCellAspect: CGFloat {
        let raw = measuredPageAspect ?? Self.defaultCellAspectRatio
        return min(max(raw, 0.35), 2.0)
    }

    /// サンプルを1つ受け取り、目標数に達したら中央値を確定する。
    private func recordAspectSample(_ aspect: CGFloat) {
        guard measuredPageAspect == nil, aspect.isFinite, aspect > 0 else { return }
        aspectSamples.append(aspect)
        guard aspectSamples.count >= aspectSampleTarget else { return }
        let sorted = aspectSamples.sorted()
        measuredPageAspect = sorted[sorted.count / 2]
    }

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
        Self.cellSize(from: preferences)
    }

    /// 上と同じ計算を、Viewのインスタンスを介さずに行う版。ホイールのスクロール量を決める
    /// NSEventモニタから使う(makeWheelMonitorのコメント参照。あのクロージャは`self`を
    /// 捕まえてはいけない)。
    private static func cellSize(from preferences: AppPreferences) -> CGFloat {
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
        let cellWidth = cellSize * effectiveCellAspect
        return max(1, Int(((available + horizontalSpacing) / (cellWidth + horizontalSpacing)).rounded(.down)))
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
            let cellHeight = cellSize
            let cellWidth = cellHeight * effectiveCellAspect
            let gridPixelSize = Self.gridThumbnailPixelSize(forCellHeight: cellHeight)
            let hSpacing = horizontalSpacing
            let count = columnCount(forPanelWidth: panelWidth)
            let columns = Array(repeating: GridItem(.fixed(cellWidth), spacing: hSpacing), count: count)
            // 固定幅の列はLazyVGridの先頭(左)から詰められるので、グリッド自体の幅を列数ぶんに
            // 絞ってから中央に置く(そうしないと右側だけ余る)。
            let gridWidth = CGFloat(count) * cellWidth + CGFloat(max(count - 1, 0)) * hSpacing

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    (Text("Page List (Total ") + Text("\(viewModel.pageCount)") + Text(" pages)"))
                        .font(.headline)
                        .panelOutlinedContent()
                    Spacer(minLength: 8)
                    // サムネイルのサイズをその場で変えるスライダー(ユーザー要望)。値は環境設定と
                    // 共通(AppPreferences.thumbnailGridCellSize)なので、次回以降も引き継がれる。
                    Image(systemName: "photo")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .panelOutlinedContent()
                    Slider(
                        value: $preferences.thumbnailGridCellSize,
                        in: AppPreferences.thumbnailGridCellSizeRange
                    )
                    .frame(width: 140)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Thumbnail Size"))
                    // つまみは白く、明るい面の上ではほとんど見えない。文字と同じ輪郭は
                    // 使えない(つまみの落ち影までにじむ)ので、部品ごと薄い溝に収める
                    // (panelControlWellのコメント参照)。
                    .panelControlWell()
                    Image(systemName: "photo")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .panelOutlinedContent()
                    // 拡大プレビューのON/OFF(ユーザー要望)。環境設定「外観」→「ページ一覧」の
                    // 「カーソルを合わせたら拡大プレビューを表示」とまったく同じ値
                    // (AppPreferences.showThumbnailHoverPreview)で、どちらから変えても即座に
                    // 両方へ反映される。読みながら切り替えたい設定なので、その場に口を出す。
                    //
                    // サムネイルサイズの3部品(小さいアイコン・スライダー・大きいアイコン)の
                    // **右**に置く(ユーザーの指示)。あの3つで1つのまとまりなので、間に
                    // 割り込ませず外側へ出してある。
                    //
                    // 見出しは画面に出さず、ツールチップだけにする(ユーザーの指示)。
                    // 隣のスライダーも同じで、この行に文字を増やさず部品だけを並べる形に
                    // 揃っている。ラベル自体はToggleに持たせたまま`.labelsHidden()`で
                    // 隠すので、読み上げには従来どおり文言が伝わる。
                    //
                    // 面の塗りつぶし対策は`.panelControlWell()`。スイッチはONのとき
                    // アクセントカラーで塗られ、つまみは白い部品なので、文字と同じ輪郭は
                    // 掛けられない(つまみの落ち影までシルエットに含まれてにじむ)。
                    // 隣のスライダーとまったく同じ理由・同じ対処になる
                    // (panelControlWellのコメント参照)。
                    Toggle(isOn: $preferences.showThumbnailHoverPreview) {
                        Text("Show Preview")
                    }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Show Preview")
                    .panelControlWell()
                }
                .padding()

                ScrollView {
                    // 右クリックメニューの文言(追加/削除)を決めるためのページ番号の集合。
                    // **ここで一度だけ組む。** `.contextMenu`の中身はセルの本体評価の一部として
                    // 組み立てられる(SidePanelContextMenuHighlightの型コメント参照)ため、
                    // セルごとにviewModel.bookmarksを走査すると、ページ数×ブックマーク数の
                    // 走査が描画のたびに走る。
                    let bookmarkedPageIndices = Set(viewModel.bookmarks.map(\.pageIndex))
                    // 帳簿の下限セル数: 画面内に収まりうるセル数(列数×見えている行数+先読み分)の
                    // 3倍。これ未満で作り直すと、画面内ぶんの読み直しだけで再び予算へ達して
                    // 作り直しがループしかねない(LazyCellImageBudgetの型コメント参照)。
                    let rowHeight = Self.gridRowHeight(from: preferences)
                    let visibleCellEstimate = count * (Int((panelHeight / max(rowHeight, 1)).rounded(.up)) + 2)
                    let minimumCellCount = max(visibleCellEstimate * 3, 64)
                    LazyVGrid(columns: columns, spacing: CGFloat(preferences.thumbnailGridVerticalSpacing)) {
                        ForEach(0..<viewModel.pageCount, id: \.self) { index in
                            Button {
                                viewModel.jump(toPageIndex: index)
                                isPresented = false
                            } label: {
                                ThumbnailCell(
                                    viewModel: viewModel, index: index, isCurrent: index == viewModel.currentIndex,
                                    cellWidth: cellWidth, cellHeight: cellHeight, pixelSize: gridPixelSize,
                                    onAspectMeasured: { aspect in
                                        // 複数ページの中央値でこの本のページ比率を決める
                                        // (先頭だけ横長のカバー等に引きずられないため)。
                                        recordAspectSample(aspect)
                                    },
                                    onRetainedImage: { image in
                                        cellImageBudget.note(retaining: image, minimumCellCount: minimumCellCount)
                                    }
                                )
                            }
                            .buttonStyle(.plain)
                            // 右クリックの内容はサイドパネルのページモード・本の中身ブラウザと
                            // 完全に同じ(ユーザー要望。PageContextMenuItems参照)。
                            .contextMenu {
                                if viewModel.book.pages.indices.contains(index) {
                                    PageContextMenuItems(
                                        page: viewModel.book.pages[index],
                                        bookSourceURL: viewModel.book.sourceURL,
                                        onExport: onExportPage.map { export in { export(index) } },
                                        isBookmarked: bookmarkedPageIndices.contains(index),
                                        // シークレットウインドウ・その場限りの本ではグレーアウト。
                                        allowsBookmarking: !viewModel.skipsPersistence,
                                        onToggleBookmark: onToggleBookmark.map { toggle in { toggle(index) } }
                                    )
                                }
                            }
                        }
                    }
                    // 保持量が予算を超えたらグリッドごと作り直して、画面外セルが抱えた
                    // サムネイル・プレビューをまとめて解放する(cellImageBudgetのコメント参照)。
                    .id(cellImageBudget.epoch)
                    .frame(width: gridWidth)
                    .frame(maxWidth: .infinity)
                    .padding(Self.contentPadding)
                    // ホイール1ノッチあたりのスクロール量を環境設定に従わせるために、裏の
                    // NSScrollViewを控えておく(makeWheelMonitor参照)。
                    // **ScrollViewの内側**(スクロールされる中身)に置くこと。外側に付けると、
                    // 祖先をたどってもNSScrollViewには行き当たらない(ViewerViewの
                    // 同じアクセサの取り付け位置と同じ理由。実際にここで一度間違えて、
                    // ホイールの設定が効かずAppKitの既定のスクロールだけが起きていた)。
                    .background(ScrollViewAccessor(onResolve: { scrollGeometryBox.scrollView = $0 }))
                }
            }
            .frame(width: panelWidth, height: panelHeight)
            // パネルの背景の濃さと重ね色は環境設定「外観」に従う(ユーザー要望)。
            // 既定値では従来の .background(.regularMaterial, in:) と同じ描画になる。
            .panelSurfaceBackground(
                preferences.pageListSurfaceStyle,
                material: .regularMaterial,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
            .contentShape(Rectangle())
            .onTapGesture {
                isPresented = false
            }
            .background(PanelScreenFrameAccessor(onChange: onPanelScreenFrameChange))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                guard wheelMonitor == nil else { return }
                wheelMonitor = makeWheelMonitor()
            }
            .onDisappear {
                if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
                wheelMonitor = nil
            }
        }
    }

    // MARK: - ホイール1ノッチあたりのスクロール量(ユーザー要望)

    /// グリッド1行分の高さ(pt)。サムネイルの高さ + キャプション + 行間。
    ///
    /// 実測ではなく見積もりである。実測しようとすると、行の高さはLazyVGridが決めた
    /// あとでしか分からず、そのときには既にホイールイベントを処理し終えている。
    /// 見積もりで十分なのは、この値の用途が「1ノッチで何行ぶん動かすか」という
    /// **ユーザーが感覚で決める量**だからで、数pxの誤差はそのまま設定値の微差に埋もれる。
    /// キャプションの高さは、SwiftUIの標準的な行間(フォントサイズの約1.3倍)と、
    /// セル内VStackのspacing(4pt)から求めている。
    private static func gridRowHeight(from preferences: AppPreferences) -> CGFloat {
        let captionHeight: CGFloat = preferences.thumbnailGridCaptionStyle == .none
            ? 0
            : (preferences.thumbnailGridCaptionFontSize * 1.3).rounded(.up) + 4
        return cellSize(from: preferences) + captionHeight
            + CGFloat(preferences.thumbnailGridVerticalSpacing)
    }

    /// このスクロールイベントが、トラックパッド(や Magic Mouse の指でなぞる操作)ではなく
    /// **物理マウスホイールのノッチ**によるものか。
    ///
    /// 判定は**このアプリの他の箇所と同じ`phase`/`momentumPhase`で行う**
    /// (ViewerView.makeScrollMonitorの`isTrackpadOriginated`と同じ式)。指でなぞる操作だけが
    /// phaseを伴い、ホイールのノッチは解像度に関わらず常に空になる。
    ///
    /// バグ修正(ユーザー報告): ここは当初`!event.hasPreciseScrollingDeltas`だった。そのため
    /// **「ホイール1ノッチのスクロール行数」が一度も適用されていなかった。** 高解像度
    /// スクロールに対応した最近のマウス(報告者の環境はLogitech MX Anywhere 3S)は、
    /// 物理ホイールであっても`hasPreciseScrollingDeltas == true`で届くためである。
    /// 統合ログで実測した1ノッチぶんの値:
    ///
    ///     precise=YES phase=0 momentum=0 scrollingDeltaY=-13.0 deltaY=-1.0
    ///
    /// つまり以前の条件では、ホイールを回しても常に「トラックパッド」と見なして素通しして
    /// いた。ここだけ他と違う条件を使っていたこと自体が誤りだった。
    private static func isWheelOriginated(_ event: NSEvent) -> Bool {
        event.phase.isEmpty && event.momentumPhase.isEmpty
    }

    /// ページ一覧の上でマウスホイールを回したときのスクロール量を、環境設定
    /// (thumbnailGridWheelScrollRows)に従わせるためのNSEventローカルモニタ。
    ///
    /// ■ 対象を物理マウスホイールだけに絞っている
    /// トラックパッドは1回の操作が細かいイベントの連なりとして届くため「1回ぶん」に
    /// 意味が無い。指の動きにそのまま追従する既定の挙動をそのまま通す(環境設定の
    /// invertTwoFingerScrollingが逆にトラックパッド側だけを対象にしているのと同じ考え方で、
    /// 両者は操作の質が違い、片方に合う値がもう片方では極端になる)。判定は
    /// `isWheelOriginated(_:)`(そちらのコメントに実測値と、以前の誤りの経緯)。
    ///
    /// ■ 判定は「実際にこのグリッドへ届くクリックか」(矩形の内外ではない)
    /// ヒットテストで、そのポインタ位置にあるビューがこのScrollViewの子孫かどうかを見る。
    /// 矩形の内外だけで判定すると、**上に重なっているものを無視してしまう** ―― サイドパネルを
    /// 自動表示(ホバーで手前に浮かせる)しているとき、パネルはページ一覧の上に重なるので、
    /// その一覧をスクロールしようとしたホイールをこちらが横取りしてしまい、サイドパネルが
    /// 一切スクロールできなくなる(ViewerView.makeScrollMonitorがisSidePanelFloatingOverlayを
    /// 見ているのと同じ問題)。ヒットテストなら、重なりの有無を問わず常に正しく判定できる。
    /// パネル上部の見出し・サムネイルサイズのスライダーの上でも、同じ理由で素通しする。
    ///
    /// ■ 既定のスクロールは行わせない(nilを返す)
    /// 自前で動かしたうえでイベントも通すと、AppKitの既定のスクロールと二重になって
    /// 設定した量の何倍も動いてしまう。
    ///
    /// なお、ViewerView側のスクロールモニタはページ一覧の表示中は素通し(return event)
    /// なので、こちらと競合しない(ViewerView.makeScrollMonitor参照)。
    ///
    /// ■ クロージャが`self`を捕まえないようにしてある(重要)
    /// このViewは`viewModel`(ViewerViewModel、本ごとのPageLoaderと画像キャッシュを持つ)を
    /// 保持している。`self`を捕まえると、モニタの取り外しに一度でも失敗しただけで、
    /// その本のキャッシュがプロセスの生存期間ずっと解放されなくなる。取り外しは
    /// `.onDisappear`頼みで、SwiftUIがウインドウを閉じたときに必ず呼ぶとは限らない
    /// (このリポジトリで実際に確認されている挙動。ViewerViewが各モニタの取り外しを
    /// `handleOnDisappear`にも二重に置いているのはそのため)。
    /// そこで、クロージャが触るのは`scrollGeometryBox`(小さな入れ物)と
    /// `preferences`(アプリ全体で1つ)だけに限り、寸法の計算も`static`にしてある。
    private func makeWheelMonitor() -> Any? {
        let scrollGeometryBox = self.scrollGeometryBox
        let preferences = self.preferences
        return NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            guard Self.isWheelOriginated(event), event.deltaY != 0 else { return event }
            guard let scrollView = scrollGeometryBox.scrollView,
                  let window = scrollView.window, event.window === window,
                  let contentView = window.contentView
            else { return event }
            // hitTest(_:)は「そのビューのsuperviewの座標系」で点を受け取る。contentViewの
            // superviewはウインドウのフレームビューなので、event.locationInWindowをそのまま
            // 渡せる(AppKitで定番の書き方)。
            guard let hitView = contentView.hitTest(event.locationInWindow),
                  hitView.isDescendant(of: scrollView)
            else { return event }
            guard let bounds = ScrollViewBounds(scrollGeometryBox.scrollView) else { return event }

            let rows = preferences.thumbnailGridWheelScrollRows
            let distance = Self.gridRowHeight(from: preferences) * CGFloat(rows)
            var position = bounds.position
            // ■ ノッチ数は`scrollingDeltaY`ではなく`deltaY`から取る
            // `scrollingDeltaY`の単位は機器によって変わる ―― 従来のホイールは「行」だが、
            // 高解像度ホイールは「ポイント」で届く(実測で1ノッチ=13.0)。これに行の高さを
            // 掛けると、1ノッチで13行ぶん飛ぶことになる。
            // 一方`deltaY`はどちらの機器でも**1ノッチ=±1**に正規化されている
            // (実測値は上のisWheelOriginatedのコメント参照)ので、「1ノッチあたり何行」という
            // この設定の意味とそのまま噛み合う。
            //
            // 符号: deltaYは「システム設定のナチュラルなスクロール」を反映済みの値で、
            // 上へ回すと正になる。positionは下へ進むほど増える向きなので反転させる。
            // 大きさをそのまま掛けているのは、速く回すとAppKitが1イベントへ複数ノッチ分を
            // まとめてくる(実測で-3〜-6)ため、その加速をそのまま活かすため。
            position.y -= event.deltaY * distance
            // アニメーションは付けない。「1ノッチ = N行」をそのまま目に見える動きにするため
            // (連続して回したときにアニメーション同士が競合して、行数と実際の移動量が
            // 食い違って見えるのも避けられる)。可動範囲へのクランプはscroll(to:)が行う。
            bounds.scroll(to: position)
            return nil
        }
    }
}

/// オーバーレイ表示するパネル(ページ一覧・「情報を見る」)の背後に敷く、ビューア画面
/// いっぱいの透明なレイヤー。パネルの外側へ漏れたクリックを受け止め、背後のツールバーや
/// ページ送りが誤って反応しないようにする。
///
/// ■ `isPresented`を渡すかどうかで役割が変わる
/// 渡した場合は「外側をクリックしたら閉じる」層になる(「情報を見る」パネルはこちら。
/// 従来どおりの挙動)。渡さない場合はクリックを受け止めるだけで何もしない層になる。
///
/// ページ一覧は後者を使う。閉じる条件が「画像表示領域のクリックだけ」に限定された
/// (ツールバー・プログレスバーのクリックでは閉じない)ため、このレイヤーのタップ
/// ジェスチャーでは条件を表現できないためである。ページ一覧を閉じる判定は
/// ViewerView.installThumbnailGridDismissMonitorIfNeededがスクリーン座標で行う。
///
/// なお、ページ一覧の表示中にツールバーをクリックしても何も起きない(このレイヤーが
/// 受け止めて終わる)のは意図した挙動である。パネルを出したまま背後のページを送れて
/// しまうほうが分かりにくい。
struct ThumbnailGridBackdropView: View {
    var isPresented: Binding<Bool>?

    var body: some View {
        Color.black.opacity(0.001)
            .contentShape(Rectangle())
            .onTapGesture {
                isPresented?.wrappedValue = false
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
    /// サムネイル枠の大きさ(pt)。高さがAppPreferences.thumbnailGridCellSize、幅はその
    /// cellAspectRatio倍(以前は120×120の正方形固定)。
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// このセルのサムネイルをデコードする解像度(px)。セルの大きさに追従する(ぼやけ対策)。
    let pixelSize: CGFloat
    /// 読み込めた画像の実寸から測った縦横比(幅/高さ)を、最初の1回だけ親へ知らせる。
    var onAspectMeasured: (CGFloat) -> Void = { _ in }
    /// このセルが@Stateに画像(サムネイル・拡大プレビュー)を保持したことを親へ知らせる。
    /// 親はLazyCellImageBudgetで合計量を数え、予算超過でグリッドを作り直す
    /// (LazyVGridは画面外セルの保持物を解放しないため。詳細は同型コメント参照)。
    var onRetainedImage: (CGImage) -> Void = { _ in }
    @EnvironmentObject private var preferences: AppPreferences
    @State private var image: CGImage?

    /// カーソルが小さいサムネイルの上にあるかどうか。拡大プレビュー用のpopoverの表示制御に使う
    /// (BookmarkListView.PageRowView.thumbnailPreviewContentと同じ考え方・同じ操作性を、
    /// この「ページ一覧」グリッドにも移植してほしいというユーザー要望)。
    @State private var isHoveringThumbnail = false
    /// 拡大プレビュー用の画像(ポップオーバーの枠に合わせた解像度。ViewerViewModel.
    /// loadPreviewImage参照)。一度読み込めば、同じセルを何度ホバーしても読み込み直さない
    /// よう@Stateにキャッシュしておく(素早くホバーを出し入れしたときのちらつき防止)。
    @State private var previewImage: CGImage?
    /// ホバー開始から実際にpopoverを出すまでの遅延用タスク。
    @State private var hoverPreviewTask: Task<Void, Never>?
    /// ホバー開始から実際にpopoverを出すまでの遅延(ナノ秒)。BookmarkListView.PageRowViewの
    /// hoverPreviewDelayNanosecondsと同じ値(350ms)を使う。

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // 読み込み中・比率の合わないページ(横長の見開き等)のときにだけ見える下地。
                // 枠が実際のページ比率(effectiveCellAspect)に合っているので、通常ページでは
                // 画像が枠いっぱいに収まり、この下地は見えなくなる(左右のプレースホルダが消える)。
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.15))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: cellWidth, height: cellHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    // 枠の色は環境設定「外観」で選べる(ユーザー要望)。既定の「アクセントカラー」は
                    // 従来と同じ Color.accentColor に解決される(AppPreferences.
                    // effectiveCurrentPageBorderColor参照)。
                    .stroke(isCurrent ? preferences.effectiveCurrentPageBorderColor : Color.clear, lineWidth: 3)
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
            // サムネイルの下に何を書くかは環境設定「外観」で選ぶ(ユーザー要望:
            // ページ番号のみ/ファイル名/表示なし)。「表示なし」のときは`Text`自体を
            // 置かないので、VStackのspacingぶんの隙間も消え、サムネイルだけが詰まって並ぶ。
            if let caption {
                Text(caption)
                    // 大きさも環境設定から(既定の11ptは、従来使っていた.caption2の実寸と同じ)。
                    .font(.system(size: preferences.thumbnailGridCaptionFontSize))
                    // ユーザー報告: .secondary(グレー)だと、サムネイル一覧パネルの背景
                    // (.regularMaterial)上では視認性が悪い。白固定にして見やすくする。
                    .foregroundStyle(.white)
                    // 文字だけに輪郭を掛ける(すぐ上のサムネイルは画像なので対象外 ――
                    // 掛けると画像の縁に色が回ってしまう)。この文字は白のベタ書きなので、
                    // 明るい面では輪郭が無いと完全に消える。
                    .panelOutlinedContent()
                    // ファイル名はページ番号と違って長くなりうる。セルの幅で頭打ちにし、
                    // 中央を省略する(先頭と末尾のほうが見分けに使えるため)。
                    // 番号のときも同じ指定で問題ない(折り返しようがない短さのため)。
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: cellWidth)
            }
        }
        // セルの大きさ(pixelSize)が変わったら、その解像度で読み直す(スライダーで拡大したときに
        // ぼやけないように)。idにpixelSizeを含めることで、サイズ変更時に.taskが再実行される。
        .task(id: "\(index)-\(Int(pixelSize))") {
            image = await viewModel.loadGridThumbnail(at: index, maxPixelSize: pixelSize)
            if let image, image.height > 0 {
                onAspectMeasured(CGFloat(image.width) / CGFloat(image.height))
            }
            if let image {
                onRetainedImage(image)
            }
            // 環境設定「表示中のサムネイルの拡大画像を先読み」: 見えているセルのプレビュー画像を
            // 先にデコードしておく(PageLoaderのメモリキャッシュに載るので、プレビューが即座に
            // 出る)。LazyVGridは画面内のセルしか作らないため「表示中」に自然と限定される。
            if preferences.preloadThumbnailGridPreviews, preferences.showThumbnailHoverPreview,
               previewImage == nil, !Task.isCancelled {
                previewImage = await viewModel.loadPreviewImage(at: index)
                if let previewImage {
                    onRetainedImage(previewImage)
                }
            }
        }
    }

    /// サムネイルをホバーしたときのpopoverの中身。プレビュー画像(previewImage)とファイル名を
    /// 縦に並べる。BookmarkListView.PageRowView.thumbnailPreviewContentと同じ構成・同じサイズ
    /// (環境設定で変えられる一辺。AppPreferences.thumbnailHoverPreviewSideLength)にしている。popoverが実際に画面へ表示されるたびに.taskが実行される
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
            .frame(
                width: preferences.thumbnailHoverPreviewSideLength,
                height: preferences.thumbnailHoverPreviewSideLength
            )

            Text(displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: preferences.thumbnailHoverPreviewSideLength)
        }
        .padding(12)
        .task {
            guard previewImage == nil else { return }
            previewImage = await viewModel.loadPreviewImage(at: index)
            if let previewImage {
                onRetainedImage(previewImage)
            }
        }
    }

    /// サムネイルの下に書く文字。環境設定が「表示なし」ならnil(呼び出し側はTextごと省く)。
    private var caption: String? {
        switch preferences.thumbnailGridCaptionStyle {
        case .pageNumber: return "\(index + 1)"
        case .fileName: return displayName
        case .none: return nil
        }
    }

    /// プレビュー下に表示するファイル名。範囲外(理論上は起こらないはずだが、念のため)の場合は
    /// 空文字にしておく。
    private var displayName: String {
        guard viewModel.book.pages.indices.contains(index) else { return "" }
        return viewModel.book.pages[index].displayName
    }
}



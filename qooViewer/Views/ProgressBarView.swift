import SwiftUI
import CoreGraphics
// 強調色の明るさの判定(NSColor)と、サムネイルの解像度を決めるための画面の倍率(NSScreen)。
import AppKit

/// 画面下部にウインドウの横幅いっぱいに表示するページインジケータ(プログレスバー)。
///
/// バーにカーソルを合わせると、カーソル位置付近を中心に前後合わせて最大
/// filmstripVisibleCount枚(環境設定「外観」の「サムネイルの数」。既定9枚)のサムネイルを
/// 横一列(フィルムストリップ)に表示する。
/// 各スロットの表示位置は常に固定で、ホバー位置が変わると各スロットに
/// 表示するページ(=画像)だけを差し替える(スライドするアニメーションは行わない)。
/// カーソル直下のサムネイルは、スロットのうち常に真ん中に来るのではなく、
/// カーソルの実際のx座標に近いスロットに来るようにする(バーの端に近い位置をホバー
/// したときに違和感がないように)。
///
/// 以前、ホバー中にメインスレッドが応答しなくなる(レインボーカーソル)不具合があったため、
/// 対策として以下の点に注意して実装している。
/// (1) カーソルのx座標そのものは@Stateに保持しない(表示上意味のある「ホバー中のページ番号」
/// だけを保持し、値が変わったときだけ更新する)
/// (2) サムネイル読み込みはデバウンス後に始め、同時に走らせる数を絞る(ensureThumbnailsLoaded参照)
/// (3) フィルムストリップのコンテナに実際の描画サイズと一致する明示的なframeを与え、
/// バー本体と表示位置が重なるバグを防ぐ
/// フィルムストリップの各セルはウインドウの横幅いっぱいを使って均等割りした同じ大きさで
/// 表示し、カーソル直下のセルだけ拡大せず枠線の色とページ番号バッジで区別する。
///
/// 見た目(枚数・文字の大きさ・カーソル位置以外を暗くするか・強調の色と太さ)は環境設定
/// 「外観」の「プログレスバーのフィルムストリップ」で変えられる(ユーザー要望。
/// AppearanceSettingsView.filmstripSection参照)。既定値のままなら、この設定を入れる前と
/// 見た目は変わらない。
///
/// 環境設定「閲覧中の動作」の「カーソルを合わせたページをプレビュー」がOFFのときは、この
/// フィルムストリップの代わりに、カーソル位置に対応するページ番号だけを表示するシンプルな
/// 表示になる(hoverPageNumberBadge参照。サムネイルの読み込み自体も行わない)。
struct ProgressBarView: View {
    @ObservedObject var viewModel: ViewerViewModel
    /// 環境設定「閲覧中の動作」の「カーソルを合わせたページをプレビュー」。OFFのときは、
    /// フィルムストリップの代わりにカーソル位置に対応するページ番号だけを表示するシンプルな
    /// 表示にする(hoverPageNumberBadge参照。サムネイルの読み込み自体も行わなくなる)。
    @EnvironmentObject private var preferences: AppPreferences

    /// ホバー中のページ番号(0-indexed)。ホバーしていないときはnil。
    @State private var hoverIndex: Int?
    /// ホバー中のページを、フィルムストリップのスロットのうちどの位置(0が左端、
    /// filmstripVisibleCount-1が右端)に表示するか。カーソルの実際のx座標に応じて
    /// 決まる値で、カーソルが1px動くたびに更新するのではなく、この値(枚数と同じ段数の整数)
    /// 自体が変わったときだけ更新する(過去の不具合の反省を踏まえた安全策)。
    @State private var hoverSlot: Int = 0
    /// ホバー中のカーソルのx座標(バー内のローカル座標、ホバーしていないときはnil)。
    /// サムネイルプレビューがOFFのとき(hoverPageNumberBadge参照)だけ使う値で、その場合は
    /// サムネイルのデコード・フィルムストリップの再描画コストが一切発生しないため、
    /// hoverSlotのようにスロットの段数へ間引かず、カーソルの動きにそのまま追従させる
    /// (サムネイルプレビューがONのときは、この値は更新しない。理由はファイル冒頭のコメント参照)。
    @State private var hoverXPosition: CGFloat?
    /// フィルムストリップに表示中のサムネイル(ページ番号→画像)。
    @State private var thumbnails: [Int: LoadedThumbnail] = [:]
    /// サムネイル読み込み中のタスク。表示範囲1回ぶんの読み込みをまとめて1つのタスクで
    /// 行う(中で同時数を絞って並列に読む。詳細はensureThumbnailsLoadedのコメント参照)ため、
    /// Dictionaryではなく1つだけ持つ。
    @State private var thumbnailLoadTask: Task<Void, Never>?

    /// 読み込み済みのサムネイル1枚分。
    ///
    /// 画像と一緒に**どの解像度でデコードしたか**を持つ。セルの大きさが変わったとき
    /// (枚数の設定・ウインドウ幅の変更・ページの縦横比の確定)に、解像度の足りない画像だけを
    /// 選んで読み直すため ―― 一律に捨てて読み直すと、そのたびに全セルがスピナーへ戻って
    /// ちらつく。読み直しが終わるまでは前の画像を出したままにできる。
    private struct LoadedThumbnail {
        /// デコードに失敗したページはnil。失敗も記録しておかないと、範囲が変わるたびに
        /// 同じページの読み込みを延々と試みることになる。
        let image: CGImage?
        /// この画像をデコードしたときの最大ピクセルサイズ。
        let pixelSize: CGFloat
    }
    /// ページ数が多い本ではバーの1pxごとに対応ページが変わるため、カーソルの位置が短時間
    /// 落ち着いてから初めてサムネイル読み込みを開始する(マウスを素早く動かしただけで
    /// 大量の読み込み要求が発生するのを防ぐため)。
    @State private var thumbnailLoadDebounceTask: Task<Void, Never>?
    /// 実際に読み込めたサムネイルから測った縦横比(幅/高さ)のサンプル。セルの枠は「最初の1枚」
    /// ではなく、ここに溜めた**複数ページの中央値**に合わせる ―― 先頭だけ横長のカバーがある本で、
    /// その1枚に全セルの形が引きずられないようにするため(ページ一覧とまったく同じ理由・同じ
    /// 手順。ThumbnailGridViewのaspectSamples参照)。
    @State private var aspectSamples: [CGFloat] = []
    /// 中央値を確定したら以降は動かさない(サンプルが増えるたびに枠の形が変わってちらつくのを防ぐ)。
    @State private var measuredPageAspect: CGFloat?

    private let barHeight: CGFloat = 6
    private let hitAreaHeight: CGFloat = 28
    /// セル同士の最小の間隔。幅を均等割りしたセルが下のmaxCellHeightに収まっているあいだは、
    /// 常にこの間隔で詰めて並ぶ(=従来どおり幅いっぱいに敷き詰める)。
    private let minCellSpacing: CGFloat = 6
    private let filmstripBottomGap: CGFloat = 14
    /// セル1枚の高さの上限(pt)。
    ///
    /// 枚数を減らすと1枚が大きくなる仕組み(cellWidth(for:)参照)なので、上限を設けないと
    /// 広いウインドウで3枚にしたときにサムネイルがウインドウの高さを突き抜けてしまう。
    /// 上限に達した場合は、余った幅をセルの間隔へ回して、スロットの位置(=カーソルの
    /// x座標との対応)がずれないようにする(cellSpacing(for:)参照)。
    ///
    /// **幅ではなく高さで頭打ちにする。** セルの形はページの縦横比に合わせて変わる
    /// (effectiveCellAspect参照)ので、幅で抑えても縦長の本では高さが伸び続けてしまう。
    /// 360ptは、サムネイルのデコード解像度の上限(720px)を2倍のRetina画面で使い切る大きさ。
    private let maxCellHeight: CGFloat = 360

    /// セル枠の縦横比(幅/高さ)の初期値。実際のページのサムネイルが読めたら、その実寸から
    /// 測った中央値(measuredPageAspect)へ差し替える。
    ///
    /// 以前はページの形に関わらず 1 : 1.2 の枠に`.fit`で収めていたため、多くの漫画
    /// (≒0.66)ではサムネイルの左右に黒いプレースホルダーの帯が残っていた(ユーザー報告)。
    /// ページ一覧が同じ指摘を受けて実測に合わせる形になっているので、こちらも揃える
    /// (ThumbnailGridView.defaultCellAspectRatio参照。既定値0.66も同じ)。
    private static let defaultCellAspectRatio: CGFloat = 0.66

    /// 中央値を確定するのに必要なサンプル数。短い本では総ページ数で頭打ちにする。
    private var aspectSampleTarget: Int { min(viewModel.pageCount, 9) }

    /// 実際に使う縦横比。確定前は既定値。極端な値でレイアウトが破綻しないよう安全域へ収める
    /// (ページ一覧と同じ範囲)。
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

    /// セル1枚の高さ。幅はバーを均等割りして決まる(cellWidth(for:)参照)ので、
    /// 高さのほうをページの縦横比に合わせる。
    private func cellHeight(forCellWidth width: CGFloat) -> CGFloat {
        width / effectiveCellAspect
    }

    /// フィルムストリップに一度に並べる枚数(環境設定。既定9枚)。
    /// UserDefaultsを直接書き換えられていた場合に備えて、ここでも範囲へ丸める。
    private var filmstripVisibleCount: Int {
        let range = AppPreferences.filmstripThumbnailCountRange
        let clamped = min(max(preferences.filmstripThumbnailCount, range.lowerBound), range.upperBound)
        return Int(clamped.rounded())
    }

    /// カーソル直下のセルの強調に使う色(環境設定。既定はアクセントカラー)。
    /// 枠線・光彩・ページ番号バッジの3つに同じ色を使う。
    private var highlightColor: Color { preferences.effectiveFilmstripHighlightColor }

    /// 強調色で塗ったページ番号バッジに載せる文字の色。
    ///
    /// 従来は常に白だったが、強調色を選べるようにしたことで**白や黄を選ぶと文字が消える**。
    /// 選ばれた色の明るさを見て白/黒を切り替える(アクセントカラーのようにシステム追従で
    /// 固定値を持たない色も、NSColorへ解決すれば実際の明るさが分かる)。
    private var highlightTextColor: Color {
        guard let srgb = NSColor(highlightColor).usingColorSpace(.sRGB) else { return .white }
        let luminance =
            0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    /// サムネイルに添える文字(ファイル名・ページ番号・書庫内の相対パス)の大きさ(環境設定)。
    /// 既定の10ptは、設定にする前に使っていた`.caption`/`.caption2`の実寸そのもの
    /// (macOSではこの2つはどちらも10ptなので、既定値のままなら見た目は変わらない)。
    private var labelFont: Font { .system(size: preferences.filmstripFontSize) }

    /// カーソル直下のセル**以外**を暗くするか(環境設定。既定ON=従来どおり)。
    private var dimsOtherPages: Bool { preferences.filmstripDimsOtherPages }

    /// 右開きのときは、本のページ順と同様にバーも右から左へ進むようにする
    private var isRightToLeft: Bool { viewModel.readingDirection == .rightToLeft }

    var body: some View {
        // 左右のボタンはサイドパネル・ツールバーのボタンと同じ見た目(枠なし・15ptのアイコン・
        // 32x28のタップ領域。panelIconButtonLabel参照)に揃えてある(ユーザー要望)。
        // ボタン自身が余白を持つため、バーとの間隔は以前(10pt)より詰めている。
        HStack(spacing: 4) {
            // バーの左側のボタン。「右から左へ」がONのときは末尾へ、OFFのときは先頭へ移動する
            // (見開き/1ページ送りの左右ボタンと同じ、読み方向に応じて左右の意味を切り替える
            // 考え方)。
            Button {
                viewModel.jump(toPageIndex: isRightToLeft ? viewModel.pageCount - 1 : 0)
            } label: {
                Image(systemName: "arrow.left.to.line")
                    .panelIconButtonLabel()
            }
            .buttonStyle(.borderless)
            .help(isRightToLeft ? "Move to Last" : "Move to First")

            progressBar

            // バーの右側のボタン。左側とは逆に、「右から左へ」がONのときは先頭へ、
            // OFFのときは末尾へ移動する。
            Button {
                viewModel.jump(toPageIndex: isRightToLeft ? 0 : viewModel.pageCount - 1)
            } label: {
                Image(systemName: "arrow.right.to.line")
                    .panelIconButtonLabel()
            }
            .buttonStyle(.borderless)
            .help(isRightToLeft ? "Move to First" : "Move to Last")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .onDisappear {
            thumbnailLoadDebounceTask?.cancel()
            thumbnailLoadDebounceTask = nil
            thumbnailLoadTask?.cancel()
            thumbnailLoadTask = nil
        }
    }

    /// バー本体(進捗表示・クリックでのジャンプ・ホバー中のフィルムストリップ)。
    /// 左右の先頭/最後へ移動するボタンをbodyに追加したため、元々bodyの中身だった部分を
    /// 独立したプロパティに切り出している。
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: isRightToLeft ? .trailing : .leading) {
                // バーは外観に関わらず白で描いている。明るい面(重ね色を白にした場合など)の
                // 上では白地に白で消えてしまうため、輪郭を掛ける。**色は黒を明示する** ――
                // 既定の「文字色の反対色」はライト外観だと白になり、白いバーの輪郭にならない
                // (panelOutlinedContentのcolor引数のコメント参照)。
                RoundedRectangle(cornerRadius: barHeight / 2)
                    .fill(Color.white.opacity(0.15))
                    .frame(height: barHeight)
                    .panelOutlinedContent(color: .black)

                RoundedRectangle(cornerRadius: barHeight / 2)
                    .fill(Color.white.opacity(0.85))
                    .frame(width: progressWidth(in: geo.size.width), height: barHeight)
                    .panelOutlinedContent(color: .black)

                // クリックしたページへジャンプする。
                // 背景に`Color.clear`を使うとSwiftUI(macOS)側でヒットテストが不安定になることが
                // あるため、見た目には影響しない極小の不透明度を持つ色にしている。
                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
                    .frame(height: hitAreaHeight)
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let location):
                            let index = pageIndex(atX: location.x, width: geo.size.width)
                            let slot = highlightSlot(atX: location.x, width: geo.size.width)
                            // 実際に表示へ影響する(=ページ番号またはスロット位置が変わる)
                            // ときだけ@Stateを書き換える。マウスが1px動くたびに無条件で状態を
                            // 更新すると、見た目に影響がなくても毎回このView全体
                            // (GeometryReaderを含む)の再描画を引き起こしてしまい、これが
                            // 積み重なるとメインスレッドを圧迫してハングしたように見えることが
                            // 分かっている(過去の不具合の原因)。同じ理由で、カーソルの
                            // x座標そのものは@Stateに保持しない。
                            if hoverIndex != index || hoverSlot != slot {
                                hoverIndex = index
                                hoverSlot = slot
                            }
                            // サムネイルプレビューがOFFのときだけ、カーソルのx座標をそのまま
                            // 保持してバッジをカーソルに追従させる。この表示にはサムネイルの
                            // デコードもフィルムストリップの再描画コストも伴わないため、上記の
                            // 「1pxごとには更新しない」制約を適用する必要がない
                            // (詳細はhoverXPositionのコメント参照)。
                            if !preferences.showProgressBarThumbnailPreview {
                                hoverXPosition = location.x
                            }
                        case .ended:
                            if hoverIndex != nil {
                                hoverIndex = nil
                            }
                            hoverXPosition = nil
                        }
                    }
                    .gesture(
                        SpatialTapGesture(coordinateSpace: .local)
                            .onEnded { value in
                                let index = pageIndex(atX: value.location.x, width: geo.size.width)
                                let slot = highlightSlot(atX: value.location.x, width: geo.size.width)
                                viewModel.jump(toPageIndex: index)
                                if hoverIndex != index || hoverSlot != slot {
                                    hoverIndex = index
                                    hoverSlot = slot
                                }
                                if !preferences.showProgressBarThumbnailPreview {
                                    hoverXPosition = value.location.x
                                }
                            }
                    )

                if let hoverIndex {
                    if preferences.showProgressBarThumbnailPreview {
                        filmstrip(centeredOn: hoverIndex, slot: hoverSlot, totalWidth: geo.size.width)
                            .position(x: geo.size.width / 2, y: -(filmstripHeight(for: geo.size.width) / 2 + filmstripBottomGap))
                            .allowsHitTesting(false)
                    } else {
                        hoverPageNumberBadge(
                            pageIndex: hoverIndex,
                            rawX: hoverXPosition ?? badgeXPosition(forSlot: hoverSlot, totalWidth: geo.size.width),
                            totalWidth: geo.size.width
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(height: hitAreaHeight)
    }

    /// フィルムストリップの1セル分の幅。ウインドウの横幅いっぱいに filmstripVisibleCount 枚が
    /// 並ぶよう、余白・セル間隔を差し引いた残りを均等割りする。
    /// バーの実際の表示幅から算出するため、セルの実描画サイズとオフセット計算が必ず一致する。
    ///
    /// **枚数を減らすほど1枚が大きくなる**のはこの均等割りによるもので、環境設定に
    /// 「サムネイルの大きさ」を別に持たせていないのはそのため(幅いっぱいに並べる以上、
    /// 大きさと枚数を独立には決められない)。ただし際限なく大きくすると画面を突き抜けるので、
    /// maxCellHeightで頭を打たせる(高さで抑える理由はそちらのコメント参照)。
    private func cellWidth(for totalWidth: CGFloat) -> CGFloat {
        let count = CGFloat(filmstripVisibleCount)
        let evenlyDivided = (totalWidth - (count - 1) * minCellSpacing) / count
        // 幅の上限は、高さの上限をページの縦横比で幅に直したもの(maxCellHeight参照)。
        return min(max(24, evenlyDivided), maxCellHeight * effectiveCellAspect)
    }

    /// セル同士の間隔。上限(maxCellHeight)に達していないあいだは minCellSpacing のままで、
    /// 達したときだけ余った幅をここへ回す ―― こうしておくと、セルは常にバーの左端から
    /// 右端までを等間隔で埋めるので、「カーソルのx座標 → スロット番号」の対応
    /// (highlightSlot(atX:width:))と実際のセルの位置がずれない。
    private func cellSpacing(for totalWidth: CGFloat) -> CGFloat {
        let count = CGFloat(filmstripVisibleCount)
        guard count > 1 else { return 0 }
        let leftover = (totalWidth - count * cellWidth(for: totalWidth)) / (count - 1)
        return max(minCellSpacing, leftover)
    }

    /// このセルの高さ(pt)を、ぼやけずに描くのに要するデコード解像度(px)。
    /// ページ一覧とまったく同じ考え方・同じ刻み(ThumbnailGridView.gridThumbnailPixelSize参照。
    /// 120px刻みのバケットへ量子化して、幅が少し変わるたびに再デコードが起きるのを防ぐ)。
    ///
    /// 以前は本数によらず240px固定(ImageDecoder.progressBarThumbnailMaxPixelSize)だったが、
    /// 枚数を減らして1枚を大きくできるようにした以上、その大きさで見るとぼやける。
    /// 大きさに追随させるため、ページ一覧と同じ可変解像度のサムネイル
    /// (ViewerViewModel.loadGridThumbnail)へ切り替えてある。
    private func thumbnailPixelSize(forCellHeight height: CGFloat) -> CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let bucketed = (height * scale / 120).rounded(.up) * 120
        return min(max(bucketed, 240), 720)
    }

    /// フィルムストリップ全体の高さ(ファイル名ラベル・ページ番号ラベル分を含む)。
    /// 全セル同じ大きさなので、拡大セル分の計算は不要。この値を使ってコンテナに明示的な
    /// frameを与えるため、セルの黒背景がバー本体に重なって隠してしまう(以前の不具合の
    /// 原因)ことがないよう、余裕を持たせている。
    private func filmstripHeight(for totalWidth: CGFloat) -> CGFloat {
        let width = cellWidth(for: totalWidth)
        let height = cellHeight(forCellWidth: width)
        // 文字の大きさを設定で変えられるので、1行ぶんの高さもそれに追随させる
        // (固定の20ptのままだと、大きくしたときにラベルがバーへ重なる)。
        // +10ptは上下のpadding(1pt×2)と行間の余裕で、既定の10ptのときに従来と同じ20ptになる。
        let labelHeight = preferences.filmstripFontSize + 10
        let labelSpacing: CGFloat = 3
        let safetyMargin: CGFloat = 24
        // ファイル名ラベル1行 + ページ番号ラベル1行の、合計2行分の高さを確保する。
        // 環境設定でどちらかを消していても2行ぶん確保したままにしてある ―― 中身は下端から
        // 積むので、余ったぶんは上に空くだけで見た目には出ない(足りないと欠ける)。
        return height + (labelSpacing + labelHeight) * 2 + safetyMargin
    }

    /// カーソル位置付近を中心に、前後合わせて最大 filmstripVisibleCount 枚のサムネイルを
    /// 並べたフィルムストリップを表示する。スロットの位置は固定で、ホバー位置に応じて
    /// 各スロットに表示するページを差し替えるだけ(位置のスライドは行わない)。カーソル
    /// 直下のページは`slot`番目(カーソルの実際のx座標に近い位置)に表示され、
    /// 枠線の色とページ番号表示で区別する(サイズは他のセルと変えない)。
    @ViewBuilder
    private func filmstrip(centeredOn centerIndex: Int, slot: Int, totalWidth: CGFloat) -> some View {
        let range = visibleRange(centeredOn: centerIndex, slot: slot)
        let indices = isRightToLeft ? Array(range).reversed() : Array(range)
        let width = cellWidth(for: totalWidth)
        let pixelSize = thumbnailPixelSize(forCellHeight: cellHeight(forCellWidth: width))

        HStack(alignment: .bottom, spacing: cellSpacing(for: totalWidth)) {
            ForEach(indices, id: \.self) { index in
                filmstripCell(
                    index: index,
                    isHighlighted: index == centerIndex,
                    // 見開きで2ページとも表示しているときは、2枚とも印を付ける
                    // (ViewerViewModel.partnerPageIndex参照)。
                    isCurrentPage: index == viewModel.currentIndex
                        || index == viewModel.partnerPageIndex,
                    cellWidth: width
                )
            }
        }
        .frame(width: totalWidth, height: filmstripHeight(for: totalWidth), alignment: .bottom)
        .onAppear { scheduleThumbnailLoad(for: range, centeredOn: centerIndex, pixelSize: pixelSize) }
        .onChange(of: range) { _, newRange in
            scheduleThumbnailLoad(for: newRange, centeredOn: centerIndex, pixelSize: pixelSize)
        }
        // 枚数の設定を変えた・ウインドウの幅が変わったときは、セルの大きさに合う解像度で
        // 読み直す(ページ一覧がセルの大きさをidに含めて読み直すのと同じ理由)。
        .onChange(of: pixelSize) { _, newSize in
            scheduleThumbnailLoad(for: range, centeredOn: centerIndex, pixelSize: newSize)
        }
    }

    /// 環境設定「閲覧中の動作」の「カーソルを合わせたページをプレビュー」がOFFのときに表示する、
    /// フィルムストリップの代替のシンプルな表示。サムネイル・ファイル名は表示せず、カーソル位置に
    /// 対応するページ番号(「現在 / 総ページ数」)だけを吹き出し状のバッジで表示する。サムネイルの読み込みは一切行わないため、ensureThumbnailsLoaded等は
    /// 呼ばない。
    ///
    /// filmstrip表示と違いサムネイルの幅を考慮する必要がないため、スロットの段数には
    /// 間引かず、hoverXPosition(カーソルの実際のx座標)にそのまま追従させる
    /// (hoverXPositionのコメント参照)。
    @ViewBuilder
    private func hoverPageNumberBadge(pageIndex: Int, rawX: CGFloat, totalWidth: CGFloat) -> some View {
        Text("\(pageIndex + 1) / \(viewModel.pageCount)")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.75), in: Capsule())
            .position(x: clampedBadgeX(forRawX: rawX, totalWidth: totalWidth), y: -18)
    }

    /// バッジの中心座標として使うx座標を、バーの両端ぎりぎりに表示されて見切れないよう
    /// 左右にわずかな余白の範囲内へ収める(値自体はカーソルの実際のx座標そのまま)。
    private func clampedBadgeX(forRawX x: CGFloat, totalWidth: CGFloat) -> CGFloat {
        guard totalWidth > 0 else { return 0 }
        let margin: CGFloat = 24
        guard totalWidth > margin * 2 else { return totalWidth / 2 }
        return min(max(x, margin), totalWidth - margin)
    }

    /// hoverXPositionがまだ確定していない(ホバー開始直後など)ごく短い間の暫定位置として使う、
    /// hoverSlot(0〜filmstripVisibleCount-1)からのおおよそのx座標。
    private func badgeXPosition(forSlot slot: Int, totalWidth: CGFloat) -> CGFloat {
        guard filmstripVisibleCount > 1, totalWidth > 0 else { return totalWidth / 2 }
        let fraction = CGFloat(slot) / CGFloat(filmstripVisibleCount - 1)
        return fraction * totalWidth
    }

    /// カーソル位置が短時間落ち着いてから初めてサムネイル読み込みを開始する(理由は
    /// thumbnailLoadDebounceTaskのコメント参照)。範囲が変わるたびに呼ばれる想定で、
    /// 呼ばれるたびに前回分のタイマーはキャンセルして最新の範囲だけを予約し直す。
    private func scheduleThumbnailLoad(
        for range: ClosedRange<Int>, centeredOn centerIndex: Int, pixelSize: CGFloat
    ) {
        thumbnailLoadDebounceTask?.cancel()
        thumbnailLoadDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            ensureThumbnailsLoaded(for: range, centeredOn: centerIndex, pixelSize: pixelSize)
        }
    }

    /// フィルムストリップの1セル。全セル同じ大きさで表示し、サムネイル画像の下に
    /// ファイル名・ページ番号の2行を表示する(書庫の中のフォルダ・入れ子の書庫の中にある画像は、
    /// さらにサムネイルの**上**へ相対パスの行が加わる。位置の理由はその行のコメント参照)。
    /// 何を出すかは環境設定「サムネイルの下の表示」で変えられる(FilmstripCaptionStyle参照)。
    /// カーソル直下のセルだけ、サイズは変えずに次の3点で強調する。(1) 枠線を太く・強調色に
    /// する (2) 強調色の光彩(shadow)を付ける (3) 他のセルの画像を少し暗くして
    /// 相対的に目立たせる。
    /// これとは別に、**いま開いているページ**のセルには白い破線の枠を重ねる(isCurrentPage)。
    /// いずれも見た目だけの調整で、サムネイルのデコードや読み込み処理には一切影響しない
    /// (表示速度は変わらない)。
    @ViewBuilder
    private func filmstripCell(
        index: Int, isHighlighted: Bool, isCurrentPage: Bool, cellWidth: CGFloat
    ) -> some View {
        let height = cellHeight(forCellWidth: cellWidth)

        let location = pageLocation(at: index)
        let captionStyle = preferences.filmstripCaptionStyle
        // 「カーソル位置以外を暗くする」がOFFのときは、暗くする側の値を一切使わない
        // (=すべてのセルがカーソル直下と同じ明るさで並ぶ)。強調は枠・光彩・
        // ページ番号バッジの色だけが担う。
        let isDimmed = dimsOtherPages && !isHighlighted

        VStack(spacing: 3) {
            // 書庫の中のフォルダ・入れ子の書庫の中にある画像は、ファイル名だけではどの章の
            // ページか分からない(章ごとに001.jpgから振り直されている本では同じ名前が並ぶ)。
            // 本の直下からの相対パスを、ファイル名より一段弱い見た目で添える(ユーザー要望)。
            //
            // **この行はサムネイルの上に置く。** フィルムストリップはHStack(alignment: .bottom)
            // で並んでおり、下から積み上がる ―― 相対パスの行を持つセルと持たないセル
            // (本の直下の画像)が混在しても、サムネイル・ファイル名・ページ番号の高さは
            // 揃ったままで、増えた1行だけが上へ伸びる。ファイル名の上に置くと、その1枚だけ
            // サムネイルが持ち上がってしまう。はみ出すぶんはfilmstripHeightのsafetyMarginが
            // 吸収する(枠を切り詰めていないので、超えても描画は欠けない)。
            // ファイル名を出さない設定のときは、この行も出さない(ファイル名を補うための
            // 行なので、単独で残しても手掛かりにならない。FilmstripCaptionStyle参照)。
            if captionStyle.showsFileName, let folderPath = location.folderPath {
                Text(folderPath)
                    .font(labelFont)
                    .foregroundStyle(.white.opacity(isDimmed ? 0.5 : 0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .frame(width: cellWidth)
            }

            ZStack {
                // 読み込み中と、枠に比率の合わないページ(横長の見開きなど)のときにだけ
                // 見える下地。枠が実測の縦横比(effectiveCellAspect)に合っているので、
                // 通常のページでは画像が枠いっぱいに収まり、この下地は見えなくなる。
                // 画像に余白(padding)を付けていないのも、そのぶんの帯を残さないため
                // (ページ一覧のセルと同じ作り。ThumbnailGridViewのbody参照)。
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.75))
                if let cgImage = thumbnails[index]?.image {
                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            // ハイライトされていないセルの画像だけを少し暗くすることで、カーソル直下の
            // セルが相対的に明るく目立つようにする(画像そのものの再デコードは発生しない)。
            // 暗くされたページの中身を読み取りたい場合のために、環境設定でOFFにできる。
            .opacity(isDimmed ? 0.55 : 1)
            .frame(width: cellWidth, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            // 枠の太さと色は環境設定に従う(既定は3pt・アクセントカラーで、従来と同じ)。
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isHighlighted ? highlightColor : Color.white.opacity(0.25),
                        lineWidth: isHighlighted ? preferences.filmstripHighlightBorderWidth : 1
                    )
            )
            // いま開いているページ(ビューアに表示中のページ)の印。フィルムストリップには
            // これまで「カーソルがどこを指しているか」の印しか無く、**そこから何ページ動くのか**
            // を測る基準が画面に出ていなかった(ユーザー要望)。
            //
            // カーソル位置の強調と混同しないよう、印の付け方を変えてある ―― あちらは実線・
            // 強調色・光彩付きで、こちらは白い**破線**。強調色に白を選んでいても、実線と破線なら
            // 見分けが付く(色だけで区別すると、その組み合わせで見分けられなくなる)。
            // 枠で示すこと自体はページ一覧と同じ語彙で、見開き表示のときに2枚とも印が付くのも
            // ページ一覧・サイドパネルと同じ(ユーザー報告: 2枚表示しているのに印が1枚にしか
            // 付かないのは違和感がある。判定はViewerViewModel.partnerPageIndexに集約)。
            //
            // 枠線の**内側**へ入れているので、同じセルがカーソル位置でもあるときは
            // 外の実線と内の破線が両方見える(どちらの情報も失わない)。
            .overlay {
                if isCurrentPage {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        // 白いページの上でも破線が消えないように、輪郭代わりの薄い影を敷く。
                        .shadow(color: .black.opacity(0.8), radius: 1)
                        .padding(isHighlighted ? preferences.filmstripHighlightBorderWidth : 1)
                }
            }
            .shadow(
                color: isHighlighted ? highlightColor.opacity(0.75) : .black.opacity(0.2),
                radius: isHighlighted ? 8 : 2
            )

            if captionStyle.showsFileName {
                Text(location.fileName)
                    .font(labelFont)
                    .foregroundStyle(.white.opacity(isDimmed ? 0.7 : 0.95))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .frame(width: cellWidth)
            }

            if isHighlighted {
                Text("\(index + 1) / \(viewModel.pageCount)")
                    .font(labelFont)
                    .fontWeight(.semibold)
                    // 白固定にしない理由はhighlightTextColorのコメント参照。
                    .foregroundStyle(highlightTextColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(highlightColor, in: Capsule())
            } else {
                Text("\(index + 1)")
                    .font(labelFont)
                    .foregroundStyle(.white.opacity(isDimmed ? 0.6 : 0.85))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.5), in: Capsule())
                    // ページ番号を出さない設定でも、場所だけは空けたまま隠す。
                    // セルはHStack(alignment: .bottom)で下から積むので、カーソル位置のセルにだけ
                    // 残るページ番号(上の分岐)のぶん、そのセルのサムネイルだけが1行ぶん
                    // 持ち上がってしまうため(相対パスの行と同じ理屈。そちらのコメント参照)。
                    .opacity(captionStyle.showsPageNumber ? 1 : 0)
            }
        }
        .frame(width: cellWidth)
    }

    /// ページに対応する画像の、本の中での居場所(ファイル名と、書庫内フォルダ/入れ子の書庫の
    /// 相対パス)を返す。詳細はPageRef.location(inBookAt:)参照。
    private func pageLocation(at index: Int) -> PageLocation {
        guard viewModel.book.pages.indices.contains(index) else {
            return PageLocation(fileName: "", folderPath: nil)
        }
        return viewModel.book.pages[index].location(inBookAt: viewModel.book.sourceURL)
    }

    /// centerIndexがスロットのうち何番目(0が左端)に来るかを指定して、
    /// フィルムストリップに表示するページ範囲を求める。端に近いときは、ページ数の範囲内に
    /// 収まるようずらす(そのときはcenterIndexが必ずしもslot番目に来なくなる)。
    private func visibleRange(centeredOn centerIndex: Int, slot: Int) -> ClosedRange<Int> {
        let pageCount = viewModel.pageCount
        guard pageCount > 0 else { return 0...0 }
        if pageCount <= filmstripVisibleCount {
            return 0...(pageCount - 1)
        }
        let clampedSlot = min(max(slot, 0), filmstripVisibleCount - 1)
        var start: Int
        var end: Int
        if isRightToLeft {
            // RTLでは表示配列(indices)を反転させて並べるため、"右から数えたスロット"が
            // 左からの見た目位置と一致するよう、centerIndexは範囲の上端側から数える。
            end = centerIndex + clampedSlot
            start = end - filmstripVisibleCount + 1
        } else {
            start = centerIndex - clampedSlot
            end = start + filmstripVisibleCount - 1
        }
        if start < 0 {
            start = 0
            end = filmstripVisibleCount - 1
        }
        if end > pageCount - 1 {
            end = pageCount - 1
            start = end - filmstripVisibleCount + 1
        }
        return start...end
    }

    /// 表示範囲内でまだ読み込んでいないページのサムネイルを、カーソル直下のページに近い順に、
    /// 同時に最大maxConcurrentThumbnailLoads件ずつ読み込む。
    ///
    /// 以前は「1件ずつ順番に」だった(ホバー中にメインスレッドが固まった不具合への対策の
    /// 一つとして)。しかし固まっていた原因はカーソル座標の@State更新の積み重ねで、
    /// サムネイルのデコード自体はPageLoaderがactorの外で行い、同時数もPageLoader側で
    /// コア数に絞っている。直列にする理由は無く、既定9枚・最大15枚を1枚ずつ待つと
    /// 元ファイルからのデコード(JPEGで20ms、PNGで30〜50ms)がそのまま積み上がって
    /// 出揃うまで数百msかかっていた。結果は届いた順に1枚ずつ反映する(読み終えた順は
    /// 開始順とほぼ同じで、近いページから埋まる)。
    private func ensureThumbnailsLoaded(
        for range: ClosedRange<Int>, centeredOn centerIndex: Int, pixelSize: CGFloat
    ) {
        thumbnailLoadTask?.cancel()
        // メモリを無駄に膨らませないよう、表示範囲から離れたキャッシュ済みサムネイルは間引く
        thumbnails = thumbnails.filter { range.contains($0.key) }

        // まだ無いページと、**別の解像度で読んであるページ**が読み直しの対象
        // (LoadedThumbnail参照)。読み直しのあいだも古い画像は消さずに出したままにする。
        let missing = range
            .filter { thumbnails[$0]?.pixelSize != pixelSize }
            .sorted { abs($0 - centerIndex) < abs($1 - centerIndex) }
        guard !missing.isEmpty else { return }

        let viewModel = viewModel
        thumbnailLoadTask = Task {
            await withTaskGroup(of: (index: Int, image: CGImage?).self) { group in
                var pending = missing[...]
                // 近い順に、枠が空くたびに次を1件足す(常に最大maxConcurrentThumbnailLoads件が走る)。
                func addNext() {
                    guard let index = pending.popFirst() else { return }
                    group.addTask {
                        // セルの大きさに合わせた解像度で読む(thumbnailPixelSize(forCellHeight:)参照)。
                        // デコード済みのものはPageLoader側のキャッシュから即座に返るので、
                        // 同じ解像度で見ている限り読み直しは起きない。
                        (index, await viewModel.loadGridThumbnail(at: index, maxPixelSize: pixelSize))
                    }
                }
                for _ in 0..<Self.maxConcurrentThumbnailLoads { addNext() }
                for await result in group {
                    guard !Task.isCancelled else { return }
                    thumbnails[result.index] = LoadedThumbnail(image: result.image, pixelSize: pixelSize)
                    // 読めた画像の実寸から、セル枠の縦横比を決めるサンプルを溜める
                    // (recordAspectSample参照)。デコードのついでなので追加のコストは無い。
                    if let image = result.image, image.height > 0 {
                        recordAspectSample(CGFloat(image.width) / CGFloat(image.height))
                    }
                    addNext()
                }
            }
        }
    }

    /// フィルムストリップのサムネイルを同時に読み込む数。PageLoader側もデコードの同時数を
    /// コア数で絞っているので大きくしても速くはならず、ここは「届いた順に1枚ずつ反映する
    /// 再描画の回数を積み上げない」程度の控えめな値にしてある。
    private static let maxConcurrentThumbnailLoads = 4

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard viewModel.pageCount > 0 else { return 0 }
        let fraction = CGFloat(viewModel.currentIndex + 1) / CGFloat(viewModel.pageCount)
        return totalWidth * min(max(fraction, 0), 1)
    }

    private func pageIndex(atX x: CGFloat, width: CGFloat) -> Int {
        guard width > 0, viewModel.pageCount > 0 else { return 0 }
        let rawFraction = min(max(x / width, 0), 1)
        // 右開きのときは、バーが右から左へ進むのに合わせて、クリック位置の割合も左右反転させる
        let fraction = isRightToLeft ? (1 - rawFraction) : rawFraction
        return min(Int(fraction * CGFloat(viewModel.pageCount)), viewModel.pageCount - 1)
    }

    /// カーソルの画面上のx座標(左端0〜右端1に正規化)に応じて、ホバー中のページを
    /// フィルムストリップのスロットのうち何番目(0が左端、filmstripVisibleCount-1が右端)に
    /// 表示するかを決める。読む方向(RTL/LTR)に関わらず、画面上の実際の左右位置と
    /// スロット番号がそのまま対応するよう、rawFraction(反転前)をそのまま使う。
    private func highlightSlot(atX x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return filmstripVisibleCount / 2 }
        let rawFraction = min(max(x / width, 0), 1)
        let slot = Int((rawFraction * CGFloat(filmstripVisibleCount - 1)).rounded())
        return min(max(slot, 0), filmstripVisibleCount - 1)
    }
}

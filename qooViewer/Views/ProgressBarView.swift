import SwiftUI
import CoreGraphics

/// 画面下部にウインドウの横幅いっぱいに表示するページインジケータ(プログレスバー)。
///
/// バーにカーソルを合わせると、カーソル位置付近を中心に前後合わせて最大
/// filmstripVisibleCount(9)枚のサムネイルを横一列(フィルムストリップ)に表示する。
/// 9枚それぞれの表示位置(スロット)は常に固定で、ホバー位置が変わると各スロットに
/// 表示するページ(=画像)だけを差し替える(スライドするアニメーションは行わない)。
/// カーソル直下のサムネイルは、9枚のスロットのうち常に真ん中に来るのではなく、
/// カーソルの実際のx座標に近いスロットに来るようにする(バーの端に近い位置をホバー
/// したときに違和感がないように)。
///
/// 以前、ホバー中にメインスレッドが応答しなくなる(レインボーカーソル)不具合があったため、
/// 対策として以下の点に注意して実装している。
/// (1) カーソルのx座標そのものは@Stateに保持しない(表示上意味のある「ホバー中のページ番号」
/// だけを保持し、値が変わったときだけ更新する)
/// (2) サムネイル読み込みはデバウンス後に1件ずつ順番に行う(同時並行では行わない)
/// (3) フィルムストリップのコンテナに実際の描画サイズと一致する明示的なframeを与え、
/// バー本体と表示位置が重なるバグを防ぐ
/// フィルムストリップの各セルはウインドウの横幅いっぱいを使って均等割りした同じ大きさで
/// 表示し、カーソル直下のセルだけ拡大せず枠線の色とページ番号バッジで区別する。
///
/// 環境設定「閲覧」タブの「プログレスバーにカーソルを合わせたときにサムネイルプレビューを
/// 表示する」がOFFのときは、このフィルムストリップの代わりに、カーソル位置に対応する
/// ページ番号だけを表示するシンプルな表示になる(hoverPageNumberBadge参照。サムネイルの
/// 読み込み自体も行わない)。
struct ProgressBarView: View {
    @ObservedObject var viewModel: ViewerViewModel
    /// 環境設定「閲覧」タブの「プログレスバーにカーソルを合わせたときにサムネイルプレビューを
    /// 表示する」。OFFのときは、フィルムストリップの代わりにカーソル位置に対応するページ番号
    /// だけを表示するシンプルな表示にする(hoverPageNumberBadge参照。サムネイルの読み込み自体も
    /// 行わなくなる)。
    @EnvironmentObject private var preferences: AppPreferences

    /// ホバー中のページ番号(0-indexed)。ホバーしていないときはnil。
    @State private var hoverIndex: Int?
    /// ホバー中のページを、フィルムストリップの9スロットのうちどの位置(0が左端、
    /// filmstripVisibleCount-1が右端)に表示するか。カーソルの実際のx座標に応じて
    /// 決まる値で、カーソルが1px動くたびに更新するのではなく、この値(0〜8の整数)
    /// 自体が変わったときだけ更新する(過去の不具合の反省を踏まえた安全策)。
    @State private var hoverSlot: Int = 0
    /// ホバー中のカーソルのx座標(バー内のローカル座標、ホバーしていないときはnil)。
    /// サムネイルプレビューがOFFのとき(hoverPageNumberBadge参照)だけ使う値で、その場合は
    /// サムネイルのデコード・フィルムストリップの再描画コストが一切発生しないため、
    /// hoverSlotのように9段階に間引かず、カーソルの動きにそのまま追従させる
    /// (サムネイルプレビューがONのときは、この値は更新しない。理由はファイル冒頭のコメント参照)。
    @State private var hoverXPosition: CGFloat?
    /// フィルムストリップに表示中のサムネイル(ページ番号→画像)。
    @State private var thumbnails: [Int: CGImage] = [:]
    /// サムネイル読み込み中のタスク。1件ずつ順番に読み込む(詳細はensureThumbnailsLoadedの
    /// コメント参照)ため、Dictionaryではなく1つだけ持つ。
    @State private var thumbnailLoadTask: Task<Void, Never>?
    /// ページ数が多い本ではバーの1pxごとに対応ページが変わるため、カーソルの位置が短時間
    /// 落ち着いてから初めてサムネイル読み込みを開始する(マウスを素早く動かしただけで
    /// 大量の読み込み要求が発生するのを防ぐため)。
    @State private var thumbnailLoadDebounceTask: Task<Void, Never>?

    private let barHeight: CGFloat = 6
    private let hitAreaHeight: CGFloat = 28
    private let filmstripVisibleCount = 9
    private let cellSpacing: CGFloat = 6
    private let filmstripBottomGap: CGFloat = 14

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
    /// 並ぶよう、余白・セル間隔を差し引いた残りを均等割りする(上限を設けず、幅いっぱいまで使う)。
    /// バーの実際の表示幅から算出するため、セルの実描画サイズとオフセット計算が必ず一致する。
    private func cellWidth(for totalWidth: CGFloat) -> CGFloat {
        max(24, (totalWidth - CGFloat(filmstripVisibleCount - 1) * cellSpacing) / CGFloat(filmstripVisibleCount))
    }

    /// フィルムストリップ全体の高さ(ファイル名ラベル・ページ番号ラベル分を含む)。
    /// 全セル同じ大きさなので、拡大セル分の計算は不要。この値を使ってコンテナに明示的な
    /// frameを与えるため、セルの黒背景がバー本体に重なって隠してしまう(以前の不具合の
    /// 原因)ことがないよう、余裕を持たせている。
    private func filmstripHeight(for totalWidth: CGFloat) -> CGFloat {
        let width = cellWidth(for: totalWidth)
        let cellHeight = width * 1.2
        let labelHeight: CGFloat = 20
        let labelSpacing: CGFloat = 3
        let safetyMargin: CGFloat = 24
        // ファイル名ラベル1行 + ページ番号ラベル1行の、合計2行分の高さを確保する。
        return cellHeight + (labelSpacing + labelHeight) * 2 + safetyMargin
    }

    /// カーソル位置付近を中心に、前後合わせて最大 filmstripVisibleCount 枚のサムネイルを
    /// 並べたフィルムストリップを表示する。9枚のスロット位置は固定で、ホバー位置に応じて
    /// 各スロットに表示するページを差し替えるだけ(位置のスライドは行わない)。カーソル
    /// 直下のページは、9枚のうち`slot`番目(カーソルの実際のx座標に近い位置)に表示され、
    /// 枠線の色とページ番号表示で区別する(サイズは他のセルと変えない)。
    @ViewBuilder
    private func filmstrip(centeredOn centerIndex: Int, slot: Int, totalWidth: CGFloat) -> some View {
        let range = visibleRange(centeredOn: centerIndex, slot: slot)
        let indices = isRightToLeft ? Array(range).reversed() : Array(range)
        let width = cellWidth(for: totalWidth)

        HStack(alignment: .bottom, spacing: cellSpacing) {
            ForEach(indices, id: \.self) { index in
                filmstripCell(index: index, isHighlighted: index == centerIndex, cellWidth: width)
            }
        }
        .frame(width: totalWidth, height: filmstripHeight(for: totalWidth), alignment: .bottom)
        .onAppear { scheduleThumbnailLoad(for: range, centeredOn: centerIndex) }
        .onChange(of: range) { _, newRange in scheduleThumbnailLoad(for: newRange, centeredOn: centerIndex) }
    }

    /// 環境設定「プログレスバーにカーソルを合わせたときにサムネイルプレビューを表示する」が
    /// OFFのときに表示する、フィルムストリップの代替のシンプルな表示。サムネイル・ファイル名は
    /// 表示せず、カーソル位置に対応するページ番号(「現在 / 総ページ数」)だけを吹き出し状の
    /// バッジで表示する。サムネイルの読み込みは一切行わないため、ensureThumbnailsLoaded等は
    /// 呼ばない。
    ///
    /// filmstrip表示と違いサムネイルの幅を考慮する必要がないため、9段階のスロットには
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
    /// hoverSlot(0〜filmstripVisibleCount-1の9段階)からのおおよそのx座標。
    private func badgeXPosition(forSlot slot: Int, totalWidth: CGFloat) -> CGFloat {
        guard filmstripVisibleCount > 1, totalWidth > 0 else { return totalWidth / 2 }
        let fraction = CGFloat(slot) / CGFloat(filmstripVisibleCount - 1)
        return fraction * totalWidth
    }

    /// カーソル位置が短時間落ち着いてから初めてサムネイル読み込みを開始する(理由は
    /// thumbnailLoadDebounceTaskのコメント参照)。範囲が変わるたびに呼ばれる想定で、
    /// 呼ばれるたびに前回分のタイマーはキャンセルして最新の範囲だけを予約し直す。
    private func scheduleThumbnailLoad(for range: ClosedRange<Int>, centeredOn centerIndex: Int) {
        thumbnailLoadDebounceTask?.cancel()
        thumbnailLoadDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            ensureThumbnailsLoaded(for: range, centeredOn: centerIndex)
        }
    }

    /// フィルムストリップの1セル。全セル同じ大きさで表示し、サムネイル画像の下に
    /// ファイル名・ページ番号の2行を表示する。カーソル直下のセルだけ、サイズは変えずに
    /// 次の3点で強調する。(1) 枠線を太く・アクセントカラーにする (2) アクセントカラーの
    /// 光彩(shadow)を付ける (3) 他のセルの画像を少し暗くして相対的に目立たせる。
    /// いずれも見た目だけの調整で、サムネイルのデコードや読み込み処理には一切影響しない
    /// (表示速度は変わらない)。
    @ViewBuilder
    private func filmstripCell(index: Int, isHighlighted: Bool, cellWidth: CGFloat) -> some View {
        let height = cellWidth * 1.2

        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.75))
                if let cgImage = thumbnails[index] {
                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(2)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            // ハイライトされていないセルの画像だけを少し暗くすることで、カーソル直下の
            // セルが相対的に明るく目立つようにする(画像そのものの再デコードは発生しない)。
            .opacity(isHighlighted ? 1 : 0.55)
            .frame(width: cellWidth, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isHighlighted ? Color.accentColor : Color.white.opacity(0.25), lineWidth: isHighlighted ? 3 : 1)
            )
            .shadow(color: isHighlighted ? Color.accentColor.opacity(0.75) : .black.opacity(0.2), radius: isHighlighted ? 8 : 2)

            Text(pageDisplayName(at: index))
                .font(.caption)
                .foregroundStyle(.white.opacity(isHighlighted ? 0.95 : 0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                .frame(width: cellWidth)

            if isHighlighted {
                Text("\(index + 1) / \(viewModel.pageCount)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
            } else {
                Text("\(index + 1)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.5), in: Capsule())
            }
        }
        .frame(width: cellWidth)
    }

    /// ページに対応する画像ファイル名(フォルダの階層は含まない、ファイル名のみ)を返す。
    private func pageDisplayName(at index: Int) -> String {
        guard viewModel.book.pages.indices.contains(index) else { return "" }
        return viewModel.book.pages[index].displayName
    }

    /// centerIndexが9枚のスロットのうち何番目(0が左端)に来るかを指定して、
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

    /// 表示範囲内でまだ読み込んでいないページのサムネイルを、カーソル直下のページに近い順に
    /// **1件ずつ順番に**読み込む(同時並行では行わない。理由はファイル冒頭のコメント参照)。
    private func ensureThumbnailsLoaded(for range: ClosedRange<Int>, centeredOn centerIndex: Int) {
        thumbnailLoadTask?.cancel()
        // メモリを無駄に膨らませないよう、表示範囲から離れたキャッシュ済みサムネイルは間引く
        thumbnails = thumbnails.filter { range.contains($0.key) }

        let missing = range
            .filter { thumbnails[$0] == nil }
            .sorted { abs($0 - centerIndex) < abs($1 - centerIndex) }
        guard !missing.isEmpty else { return }

        thumbnailLoadTask = Task {
            for index in missing {
                guard !Task.isCancelled else { return }
                let image = await viewModel.loadThumbnail(at: index)
                guard !Task.isCancelled else { return }
                thumbnails[index] = image
            }
        }
    }

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
    /// フィルムストリップの9スロットのうち何番目(0が左端、filmstripVisibleCount-1が右端)に
    /// 表示するかを決める。読む方向(RTL/LTR)に関わらず、画面上の実際の左右位置と
    /// スロット番号がそのまま対応するよう、rawFraction(反転前)をそのまま使う。
    private func highlightSlot(atX x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return filmstripVisibleCount / 2 }
        let rawFraction = min(max(x / width, 0), 1)
        let slot = Int((rawFraction * CGFloat(filmstripVisibleCount - 1)).rounded())
        return min(max(slot, 0), filmstripVisibleCount - 1)
    }
}

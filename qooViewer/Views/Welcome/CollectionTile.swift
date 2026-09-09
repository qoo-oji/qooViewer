import CoreGraphics
import SwiftUI

/// コレクション1つ分のタイル(改善要望5)。中身のカバーを敷き詰めた角丸の札で、クリックすると
/// その中へ入る。
///
/// ■ 割り付けはライブラリの縦横比で決まる
/// 2:3 なら3列2行で最大6冊、1:1 なら2列2行で最大4冊(CoverAspectRatio.tileColumns)。どちらも
/// **札全体がほぼ正方形になる**組み合わせで、縦横比の指定を別に書かなくても正方形に落ち着く
/// ので、タイルの大きさはスライダーの値(LazyVGridの`.adaptive(minimum:)`)にそのまま従わせられる
/// (計算はCoverAspectRatio.tileColumnsのコメント)。余白と間隔の値はCollectionTileLayoutが持つ
/// ―― 焼いた絵を作る側と表示側で食い違わせないため。
///
/// ■ 絵の出どころは2通り
/// - **焼いた札の絵**(CollectionTileImageStore): 中身のカバーを敷き詰めた1枚を先に作って
///   持っておき、ここではそれを切り分けて並べるだけ。1コレクションにつきファイル読みと復号が
///   1回で済む(セルごとに読むと札100枚で600回になる。あちらの型コメント参照)
/// - **生のセル**(CollectionCoverThumbnail): 抽出待ち・失敗・実体が見つからない本が混じる札は
///   こちら。どれも状態で見た目が変わるもので、絵に焼き込むと状態が伝わらなくなる
///
/// 割り付けはどちらも同じ`grid(cell:)`を通るので、経路が切り替わっても1ptも動かない。
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
    /// 表示する本(並び替え済み)。先頭`aspectRatio.tileCellCount`冊だけを描く。
    let items: [CollectionItem]
    /// この本の実体が見つかっているか。
    let exists: (CollectionItem) -> Bool
    /// いま抽出中か。
    let isExtracting: (CollectionItem) -> Bool
    /// この本のカバーで残す位置(本ごとの上書き ?? ライブラリの既定)。
    let cropAnchor: (CollectionItem) -> CoverCropAnchor
    let coverStore: CollectionCoverStore
    /// 焼いた札の絵の保管庫。
    let tileStore: CollectionTileImageStore
    /// このライブラリのカバーの縦横比。セルの形とここの割り付けの両方がこれで決まる。
    let aspectRatio: CoverAspectRatio
    /// 札の地の色(ライブラリの設定。既定は明暗どちらにも馴染む薄い地)。
    var backgroundColor: Color = Color.primary.opacity(0.07)
    /// タイルの一辺の目安(スライダーの値)。角丸とセルの復号サイズの見積もりに使う。
    let size: CGFloat
    /// 札の下に出す名前の文字の大きさ(pt。環境設定「外観」→「ウェルカム画面」)。
    /// 既定の13ptは、設定にする前の`Text`の既定(macOSの`.body`)そのもの。
    var nameFontSize: CGFloat = 13
    /// 保持した画像を呼び出し側の帳簿(LazyCellImageBudget)へ伝える。第2引数は
    /// **その1枚が何セル分に相当するか** ―― 焼いた札の絵は1枚で中身のカバー全部を兼ねる。
    var onImageRetained: ((CGImage, Int) -> Void)?
    /// 編集モードか。クリックの意味(開く/選ぶ)がこれで変わる。
    var isEditing: Bool = false
    var isSelected: Bool = false
    let onOpen: () -> Void
    /// 編集モード中のクリック。
    var onToggleSelection: () -> Void = {}

    /// いま持っている焼いた絵。`key`は`CollectionTileImageStore.cacheKey`で、これが
    /// 一致しないもの(比を変えた・本が増えた・大きさを変えた)は使わない。
    private struct LoadedSheet {
        var key: String
        var image: CGImage
    }
    @State private var loadedSheet: LoadedSheet?

    /// 焼いた絵を切り分けた結果の控え。**参照型**にしてあるのは、bodyの中で埋めても
    /// ビューの再評価を起こさないため(`@State`の値をbodyから書き換えることはできない)。
    ///
    /// ■ なぜ控えるのか(ユーザー報告 2026-09-10「サイドパネルの表示・非表示でウインドウ全体が
    /// 軽く明滅する」)
    /// `CGImage.cropping(to:)`は画素をコピーしない代わりに、呼ぶたびに**別のオブジェクト**を
    /// 返す。bodyのたびに切り直すと、SwiftUIから見て`Image`の中身が毎回すり替わったことになり
    /// 描き直しになる。しかもContentViewはサイドパネルのホバー表示に`.animation(_:value:)`を
    /// **ウインドウ全体へ**掛けているので、その差し替えがアニメーションの対象になり、カーソルを
    /// 端へ近づけるたびに画面中の札がまとめてクロスフェードしていた(実測: 1回の表示/非表示で
    /// 札104枚のbodyが再評価され、セル624枚を切り直していた)。同じオブジェクトを返せば
    /// SwiftUIは「変わっていない」と判断して何も描き直さない。
    private final class SliceCache {
        private var key: String?
        private var sheet: CGImage?
        private var slices: [CGImage] = []

        func slices(forKey key: String, sheet: CGImage, aspectRatio: CoverAspectRatio) -> [CGImage] {
            // 鍵が同じでも、いったんメモリから落ちて復号し直した絵は別のオブジェクトになる。
            if self.key == key, let cached = self.sheet, cached === sheet { return slices }
            var made: [CGImage] = []
            made.reserveCapacity(aspectRatio.tileCellCount)
            for index in 0..<aspectRatio.tileCellCount {
                guard let slice = sheet.cropping(to: CollectionTileLayout.cellRect(
                    index: index, inImageOfSize: (sheet.width, sheet.height), aspectRatio: aspectRatio
                )) else { break }
                made.append(slice)
            }
            self.key = key
            self.sheet = sheet
            self.slices = made
            return made
        }
    }
    @State private var sliceCache = SliceCache()

    /// セル1つの実寸の見積もり(復号サイズの上限にだけ使う。実際の割り付けはGridが決める)。
    private var cellWidth: CGFloat {
        CollectionTileLayout.cellWidth(tileWidth: size, aspectRatio: aspectRatio)
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
                .font(.system(size: nameFontSize))
                .lineLimit(1)
                .truncationMode(.middle)
                .panelOutlinedContent()
        }
        .help(collection.name)
    }

    private var artwork: some View {
        // 注文書と鍵はここで1度だけ組み立てて、描画と`.task`の両方へ渡す(指紋の計算を
        // bodyの中で二重に走らせない)。
        let request = tileImageRequest
        let key = request.map { CollectionTileImageStore.cacheKey($0, pixelSize: sheetPixelSize) }
        return cells(request: request, key: key)
            .padding(CollectionTileLayout.padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundColor)
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
            // 焼いた絵の読み込み。鍵が変われば(比・並び・切り出す位置・大きさが変わった)
            // 読み直す。焼いた絵を使えない札では鍵がnilで、何もしない。
            .task(id: key ?? "live") {
                await loadSheet(request: request, key: key)
            }
    }

    // MARK: - 割り付け

    /// 割り付けは焼いた絵でも生のセルでも同じ。
    private func grid<Cell: View>(@ViewBuilder cell: @escaping (Int) -> Cell) -> some View {
        Grid(
            horizontalSpacing: CollectionTileLayout.cellSpacing,
            verticalSpacing: CollectionTileLayout.cellSpacing
        ) {
            ForEach(0..<aspectRatio.tileRows, id: \.self) { row in
                GridRow {
                    ForEach(0..<aspectRatio.tileColumns, id: \.self) { column in
                        cell(row * aspectRatio.tileColumns + column)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cells(request: CollectionTileImageRequest?, key: String?) -> some View {
        if let request, let key, let sheet = sheetImage(forKey: key) {
            // 切り分けは控えから取る(SliceCacheの型コメント参照)。ここで毎回切り直すと、
            // サイドパネルの表示・非表示のたびに画面中の札が描き直しになる。
            let slices = sliceCache.slices(forKey: key, sheet: sheet, aspectRatio: aspectRatio)
            grid { index in bakedCell(index, slices: slices, count: request.cells.count) }
        } else {
            grid { index in liveCell(index) }
        }
    }

    /// 焼いた絵から切り出した1セル。`CGImage.cropping(to:)`は元画像を参照する部分画像を
    /// 作るだけで、画素のコピーは起きない(CoverImageResolver.cropped(_:to:anchor:)と同じ)。
    @ViewBuilder
    private func bakedCell(_ index: Int, slices: [CGImage], count: Int) -> some View {
        if index < count, index < slices.count {
            Image(decorative: slices[index], scale: 1)
                .resizable()
                .aspectRatio(aspectRatio.value, contentMode: .fit)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: CollectionCoverThumbnail.cornerRadius(forWidth: cellWidth),
                        style: .continuous
                    )
                )
        } else {
            emptyCell
        }
    }

    @ViewBuilder
    private func liveCell(_ index: Int) -> some View {
        if index < items.count {
            let item = items[index]
            CollectionCoverThumbnail(
                item: item,
                coverStore: coverStore,
                aspectRatio: aspectRatio,
                anchor: cropAnchor(item),
                displayWidth: cellWidth,
                exists: exists(item),
                isExtracting: isExtracting(item),
                onImageRetained: { onImageRetained?($0, 1) }
            )
        } else {
            emptyCell
        }
    }

    /// 枠を埋めきらないぶんは、同じ大きさの空きとして残す(詰めて並べると、冊数によって
    /// 札の中の割り付けが変わり、一覧が揃って見えない)。
    private var emptyCell: some View {
        Color.clear
            .aspectRatio(aspectRatio.value, contentMode: .fit)
    }

    // MARK: - 焼いた札の絵

    /// この札を1枚の絵として焼けるか。焼けるならその注文書。
    ///
    /// 抽出待ち(スピナー)・失敗(形式バッジ)・実体が見つからない(淡く描く)が1つでも
    /// 混じっていたら焼かない ―― どれも状態で見た目が変わるもので、絵にしてしまうと
    /// 状態が変わったことが伝わらなくなる。棚が育ちきった後はほとんどの札が焼ける側に入る。
    private var tileImageRequest: CollectionTileImageRequest? {
        guard !items.isEmpty else { return nil }
        var cells: [CollectionTileImageRequest.Cell] = []
        cells.reserveCapacity(items.count)
        for item in items {
            guard item.coverState == .ready, exists(item) else { return nil }
            cells.append(
                .init(itemID: item.id, anchor: cropAnchor(item), coverAspect: item.coverAspect)
            )
        }
        return CollectionTileImageRequest(
            collectionID: collection.id, aspectRatio: aspectRatio, cells: cells
        )
    }

    /// 焼いた絵を復号する最大辺(画素)。
    ///
    /// 焼いてあるのは一番大きく表示したとき(320pt)の画素数なので、それより小さい札では
    /// そのぶん縮めて復号する。スライダーを動かすたびに鍵が1ptごとに変わると、ドラッグ中に
    /// 復号し直しが延々と走るので32px刻みに量子化する。
    private var sheetPixelSize: Int {
        let sheet = CollectionTileLayout.sheetPixelSize(aspectRatio)
        let referenceCellWidth = CGFloat(CollectionTileLayout.cellPixelSize(aspectRatio).width)
        let scale = min(1, cellWidth * CollectionTileLayout.referenceScale / referenceCellWidth)
        let needed = CGFloat(max(sheet.width, sheet.height)) * scale
        return max(32, Int((needed / 32).rounded(.up)) * 32)
    }

    private func sheetImage(forKey key: String) -> CGImage? {
        if let loadedSheet, loadedSheet.key == key { return loadedSheet.image }
        // グリッドが作り直された直後(LazyCellImageBudget.epoch)は@Stateが空から始まる。
        // メモリに残っていれば`.task`の到着を待たずにここで描けるので、絵がいったん消えて
        // から出てくる、というちらつきが出ない(CollectionTileImageCacheの型コメント参照)。
        return tileStore.cachedImage(forKey: key)
    }

    private func loadSheet(request: CollectionTileImageRequest?, key: String?) async {
        guard let request, let key else {
            if loadedSheet != nil { loadedSheet = nil }
            return
        }
        if let hit = tileStore.cachedImage(forKey: key) {
            adopt(hit, key: key)
            return
        }
        let image = await tileStore.image(for: request, pixelSize: sheetPixelSize)
        guard !Task.isCancelled else { return }
        guard let image else {
            // 焼けなかった(カバーのファイルが消えている等)。生のセルで描く。
            if loadedSheet != nil { loadedSheet = nil }
            return
        }
        adopt(image, key: key)
    }

    private func adopt(_ image: CGImage, key: String) {
        loadedSheet = LoadedSheet(key: key, image: image)
        // 帳簿へ渡すのは焼いた絵**1枚だけ**。セルはこの1枚を参照する部分画像で、実際に
        // 確保されている画素はこの1枚ぶんだから(LazyCellImageBudget)。数えるセル数は
        // 中身のぶん(tileCellCount)にする ―― 1枚=1セルと数えると、下限セル数に届くまでに
        // 何画面ぶんも溜め込むことになる。
        onImageRetained?(image, aspectRatio.tileCellCount)
    }
}

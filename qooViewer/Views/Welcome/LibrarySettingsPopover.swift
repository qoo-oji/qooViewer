import SwiftUI

/// ライブラリ1つ分の設定(ユーザー要望 2026-09-09)。ウェルカム画面の右上、スライダーの右の
/// 歯車から出す。コレクションの一覧からもコレクションの中からも同じものが開く。
///
/// 持っているのはカバーの見せ方と、並び順から外して端へ置くコレクションの指定:
/// - **縦横比** … 2:3 / 1:1 / 3:2。商業コミックなら2:3でよいが、同人CG集のように横長画像だけで
///   構成された本は、2:3へ切ると横幅の半分以上を捨てることになる。画像ビューアとして使うなら
///   3:2 がいちばん素直(CoverAspectRatio参照)。
/// - **残す位置** … 画像の比が枠と違うぶんをどこで切るか。切る軸(左右か上下か)は画像ごとに
///   決まるので、選択肢は軸に依存しない3つ(CoverCropAnchor参照)。ラベルだけは両方の軸を
///   併記する ―― 「始端」では何が起きるのか読めないため。
/// - **常に先頭/末尾に表示** … ここで指定したコレクションだけ、並び順(名前順・更新順…)に
///   関わらず必ず端に出る(ユーザー要望 2026-09-10)。未分類の本をまとめておく棚が並び替えの
///   たびに移動して探しにくい、というのが動機。既定はどちらも「指定なし」で、そのときは
///   従来どおり全部が並び順に従う。それぞれ1つずつ(CollectionStore.setPinnedCollection)。
///
/// **札の地の色はここには無い。** 一度はこの面の3つ目に置いていたが、ライブラリを選び直す
/// たびに一覧の地の色が入れ替わるのは外観として落ち着かないので、アプリ全体で1つの設定として
/// 環境設定「外観」→「パネル」→「ウェルカム画面」→「ライブラリ」へ移した
/// (ユーザー指示 2026-09-09。AppPreferences.collectionTileBackgroundColor参照)。
///
/// **説明文は置かない**(ユーザー指示 2026-09-09)。ラジオが並ぶだけの小さな面なので、文章を
/// 1つ足すとそれだけで面の半分が字で埋まる。幅も内容なりに任せ、余白は詰めてある。
/// 「本ごとに上書きできる」といった説明はここではなくMANUAL.mdに書く。
///
/// どちらもカバー画像を作り直さない。保存してあるのは切っていない画像で、枠へ合わせるのは
/// 表示のたびに行うので、選び直した瞬間に一覧が変わる
/// (CoverImageResolver.cropped(_:to:anchor:)のコメント参照)。
///
/// ポップオーバーの中身はmacOSが不透明に描くので、すりガラス面の輪郭は要らない(CLAUDE.md)。
struct LibrarySettingsPopover: View {
    let library: BookLibrary

    @EnvironmentObject private var collectionStore: CollectionStore
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library Settings")
                    .font(.headline)
                Text(library.displayName(language: locale))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240, alignment: .leading)
            }

            Divider()

            group("Cover Shape") {
                Picker(selection: aspectRatioSelection) {
                    Text("Portrait (2:3)").tag(CoverAspectRatio.portrait)
                    Text("Square (1:1)").tag(CoverAspectRatio.square)
                    Text("Landscape (3:2)").tag(CoverAspectRatio.landscape)
                } label: {
                    EmptyView()
                }
            }

            group("Keep When Cropping") {
                Picker(selection: cropAnchorSelection) {
                    Text("Top / Left").tag(CoverCropAnchor.start)
                    Text("Center").tag(CoverCropAnchor.center)
                    Text("Bottom / Right").tag(CoverCropAnchor.end)
                } label: {
                    EmptyView()
                }
            }

            // コレクションが1つも無いライブラリでは、選ぶ先が「指定なし」しか無いので節ごと
            // 出さない(空のメニューを開けても意味が無い)。
            if !sortedCollections.isEmpty {
                Divider()
                pinGroup(
                    "Always First", selection: pinnedSelection(atStart: true),
                    excluding: library.pinnedLastCollectionID
                )
                pinGroup(
                    "Always Last", selection: pinnedSelection(atStart: false),
                    excluding: library.pinnedFirstCollectionID
                )
            }
        }
        .padding(12)
        // 幅は内容なりに。長いのはライブラリ名だけなので、そこだけ上限を決めて省略させる。
        .frame(minWidth: 180, alignment: .leading)
    }

    /// 「常に先頭/末尾に表示」1つぶん。ラジオではなくメニュー ―― 候補はコレクションの数だけ
    /// あり、ラジオで縦に並べるとライブラリによっては面が画面の高さを超える。
    ///
    /// **もう片方に指定されているコレクションは候補に出さない**(`excluding`)。同じものを
    /// 先頭にも末尾にも置くことはできないので、選べてしまうより最初から並べないほうがよい
    /// (選んだ場合の後始末はCollectionStore.setPinnedCollectionが持っている)。
    private func pinGroup(
        _ title: LocalizedStringKey, selection: Binding<UUID?>, excluding: UUID?
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            Picker(selection: selection) {
                Text("None").tag(UUID?.none)
                ForEach(sortedCollections.filter { $0.id != excluding }, id: \.id) { collection in
                    Text(collection.name).tag(UUID?.some(collection.id))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // 長い名前のコレクションに引きずられて面が横に伸びないよう、上限を決めておく
            // (ライブラリ名と同じ扱い)。**alignment: .leading を必ず付ける** ―― 既定の
            // .center だと、メニューが上限240の枠の中央へ寄って、上の見出しやラジオの左端と
            // 揃わない(実測 2026-09-10)。
            .frame(maxWidth: 240, alignment: .leading)
        }
    }

    /// 候補に出すコレクション(名前順)。**CollectionStore.collections(in:sort:)は通さない**
    /// ―― あちらは指定したコレクションを端へ出す(それがこの設定の効果そのもの)ので、
    /// 選ぶための一覧としては読みにくくなる。ここは常に名前順のまま。
    private var sortedCollections: [BookCollection] {
        library.collections.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 見出しを**上に**置いた設定1つぶん。
    ///
    /// `Picker("見出し", …)`のままだと、ラジオの並びが見出しの幅に押されて右へ寄る ―― 見出しの
    /// 長さが2つの設定で違うので、ラジオの左端も揃わず、右側に使い道の無い余白が残る(実測)。
    /// ラベルは畳んで、見出しは自前で上に置く。
    private func group<Content: View>(
        _ title: LocalizedStringKey, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            content()
                .pickerStyle(.radioGroup)
                .labelsHidden()
        }
    }

    /// DBが唯一の持ち主なので`@State`には写さず毎回読む(ExportCoverPickerContentの
    /// cropAnchorSelectionと同じ形)。別のウインドウが変えても次の描画で揃う。
    private var aspectRatioSelection: Binding<CoverAspectRatio> {
        Binding(
            get: { library.coverAspectRatio },
            set: {
                collectionStore.setCoverAppearance(
                    library, aspectRatio: $0, anchor: library.coverCropAnchor
                )
            }
        )
    }

    /// 常に先頭/末尾に表示するコレクション。DBが唯一の持ち主なので`@State`には写さない
    /// (aspectRatioSelectionと同じ形)。
    private func pinnedSelection(atStart: Bool) -> Binding<UUID?> {
        Binding(
            get: {
                atStart
                    ? collectionStore.pinnedFirstCollection(in: library)?.id
                    : collectionStore.pinnedLastCollection(in: library)?.id
            },
            set: { id in
                let collection = id.flatMap { collectionStore.collection(withID: $0) }
                collectionStore.setPinnedCollection(collection, atStart: atStart, in: library)
            }
        )
    }

    private var cropAnchorSelection: Binding<CoverCropAnchor> {
        Binding(
            get: { library.coverCropAnchor },
            set: {
                collectionStore.setCoverAppearance(
                    library, aspectRatio: library.coverAspectRatio, anchor: $0
                )
            }
        )
    }
}

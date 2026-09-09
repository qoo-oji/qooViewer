import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// コレクションの中から1冊ぶんのメタデータとカバー画像を編集するシート(改善要望5 §5.3)。
///
/// 「メタデータの編集」ウインドウと**同じDBの同じ行**を書く。違いは2つだけ:
///
/// - この画面は本のURLを持てている(コレクションのブックマークから解決済み)ので、登録の際に
///   セキュリティスコープ付きブックマークとinodeも一緒に保存できる(ウインドウ版はファイルを
///   開いていないため`sourceURL: nil`で登録するしかない)。
/// - カバーを1枚の画像として大きく出し、そこへ直接画像ファイルを落とせる。
///
/// **カバーの操作はメタデータの4欄とは独立に即時保存される**(書き出しウインドウのカバー列と
/// 同じ挙動)。Cancelで戻るのは4欄の入力だけで、カバーの変更は取り消されない ―― カバーの変更は
/// その場でコレクションのタイルへ反映されるものなので、シートを閉じるまで確定しない作りに
/// すると「変わったのに戻った」と見えてしまう。
///
/// シートの中身はmacOSが不透明に描くので、すりガラス面の輪郭は要らない(CLAUDE.md参照)。
struct BookMetadataSheet: View {
    /// 対象の本(コレクションの行)のid。カバーの状態(抽出済みか・横長を切ったか)も行から読む。
    ///
    /// **モデルの参照ではなくidで受ける**(監査で指摘 2026-09-09)。シートを出している間に
    /// 別のウインドウがその本をコレクションから外してsaveすると、`CollectionItem`本体を
    /// 持ったままでは次の描き直しで消えた行の属性を読んで落ちる(SwiftDataの
    /// "model instance was invalidated")。毎回ストアから引き直し、無くなっていたら閉じる。
    let itemID: UUID
    /// 本の実体。呼び出し側が`CollectionStore.resolvedExistingURL`で解決してから渡す
    /// (解決できない本ではシートを出さず「本が見つかりません」のアラートにする)。
    let sourceURL: URL
    /// この本が入っているライブラリ。カバーのプレビューをそのライブラリの縦横比で描き、
    /// 「残す位置」の既定(=ライブラリの設定)を示すために要る。
    let library: BookLibrary

    @EnvironmentObject private var metadataStore: BookMetadataStore
    @EnvironmentObject private var formatStore: MetadataFormatStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    /// 編集中の4欄。「メタデータの編集」ウインドウと同じ初期値の決め方
    /// (登録済みならDBの値、未登録ならファイル名からの推測値)。
    @State private var draft = MetadataEditorViewModel.Draft()
    /// カバーの指定。環境オブジェクトが要るのでinitでは作れず、onAppearで組み立てる
    /// (MetadataEditorWindowが@StateのViewModelを組み立てるのと同じ形)。
    @State private var coverController: CoverOverrideController?

    /// カバーの表示幅。高さはライブラリの縦横比から決まる(2:3なら1.5倍、1:1なら等倍)。
    /// 右の4欄+説明とだいたい同じ高さになる値にしてある ―― どちらかが極端に長いと、
    /// 短いほうの下に用の無い余白が残る。
    private static let coverWidth: CGFloat = 130

    /// 対象の行。別のウインドウが外していればnil(itemIDのコメント参照)。
    private var item: CollectionItem? {
        collectionStore.item(withID: itemID)
    }

    /// 「残す位置」の指定が効くか。カバーの比が枠の比と違って**実際に切ることになる**ときだけ
    /// ―― ぴったり合っているカバーに位置を指定させても何も起きない。まだ抽出できていない
    /// (比が分からない)本では、選ばせておいて後から効かせる。
    private func isCropAnchorEffective(for item: CollectionItem) -> Bool {
        guard item.coverState == .ready, item.coverAspect > 0 else { return true }
        return CoverImageResolver.cropsAnyEdge(
            imageAspect: CGFloat(item.coverAspect),
            targetAspect: library.coverAspectRatio.value
        )
    }

    var body: some View {
        if let item {
            content(for: item)
        } else {
            // 出している間に外された(itemIDのコメント参照)。何も描かずに閉じる。
            Color.clear
                .frame(width: 460, height: 120)
                .onAppear { dismiss() }
        }
    }

    private func content(for item: CollectionItem) -> some View {
        // **幅はボタンではなくラベルに与える。** `Button(...).frame(width:)`では、与えた幅は
        // レイアウト上の枠にしか効かず、実際に描かれるベゼルは文字列の長さのまま枠の中央に
        // 置かれる(実測。WelcomeTopBarの同じコメント参照)。ラベル側を同じ幅にすれば、
        // ベゼルもその幅+左右のインセットで揃う。余白(chrome)を0にしているのはそのため。
        let labelWidth = MetadataButtonWidthEstimator.equalWidth(
            for: [
                String(localized: "Cancel", language: locale),
                String(localized: "Register", language: locale),
            ],
            minWidth: 60,
            chrome: 0
        )
        return VStack(alignment: .leading, spacing: 14) {
            // どの本を編集しているのかは、この画面のどこにも出ていなかった ―― コレクションの
            // 一覧はカバーだけを並べていて名前を出さないので、右クリックで開いた先にも
            // 名前が無いと対象を取り違える。
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit Metadata")
                    .font(.headline)
                Text(item.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.title)
            }

            Divider()

            HStack(alignment: .top, spacing: 16) {
                cover(for: item)
                VStack(alignment: .leading, spacing: 10) {
                    fields
                    Text("Drop an image file on the cover, or right-click it to choose a page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button(role: .cancel) { dismiss() } label: {
                    Text("Cancel").frame(width: labelWidth)
                }
                .keyboardShortcut(.cancelAction)
                Button { register(bookID: item.bookID) } label: {
                    Text("Register").frame(width: labelWidth)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        // 別のウインドウ(「メタデータの編集」ウインドウ・書き出しウインドウ)から同じ本の
        // カバーを変えられたときも追いつく。契機はコントローラの`revision`に一本化してある
        // (CoverOverrideController.revisionのコメント参照)。
        .onReceive(NotificationCenter.default.publisher(for: .layoutDataDidChange)) { _ in
            coverController?.noteCoverDidChange()
        }
        .onAppear {
            draft = MetadataEditorViewModel.initialDraft(
                forBookID: item.bookID,
                baseName: MetadataEditorViewModel.baseName(forBookID: item.bookID),
                metadataStore: metadataStore, formatStore: formatStore
            )
            guard coverController == nil else { return }
            coverController = CoverOverrideController(
                layoutStore: layoutStore, preferences: preferences,
                // この画面は対象の本を1冊しか扱わないので、URLの解決は済んだものを返すだけ。
                resolveURL: { _ in sourceURL }
            )
        }
    }

    // MARK: - メタデータの4欄

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("Author")
                    .gridColumnAlignment(.trailing)
                // 欄そのものにラベルは持たせない(左の見出しが名前になる)。読み上げのために
                // アクセシビリティ用の名前だけ同じ文字列で与える。
                TextField("", text: $draft.author)
                    .accessibilityLabel(Text("Author"))
            }
            GridRow {
                Text("Title")
                TextField("", text: $draft.title)
                    .accessibilityLabel(Text("Title"))
            }
            GridRow {
                Text("Series")
                TextField("", text: $draft.series)
                    .accessibilityLabel(Text("Series"))
            }
            GridRow {
                Text("Volume")
                TextField("", text: $draft.seriesIndex)
                    .accessibilityLabel(Text("Volume"))
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    // MARK: - カバー画像

    /// カバーの絵と、その右クリックメニュー。
    ///
    /// **コントローラができるまでは出さない。** カバーの指定を読み書きする口がすべて
    /// コントローラにあるため、無い状態で描いても「未指定」としか出せず、しかもその状態で
    /// 組まれたメニューがそのまま残ることがある(下のCoverAreaのコメント参照)。
    @ViewBuilder
    private func cover(for item: CollectionItem) -> some View {
        if let coverController {
            CoverArea(
                controller: coverController, item: item, library: library,
                width: Self.coverWidth, isCropAnchorEnabled: isCropAnchorEffective(for: item),
                coverStore: collectionStore.coverStore, locale: locale
            )
        } else {
            // 高さを合わせるためだけの場所取り(一瞬で入れ替わる)。
            Color.clear
                .frame(width: Self.coverWidth, height: Self.coverWidth / library.coverAspectRatio.value)
        }
    }

    // MARK: - 登録

    /// 4欄をDBへ登録する(登録済みなら上書き)。4欄すべてが空のまま押すと、既存仕様どおり
    /// `upsert`が行そのものを消す ―― 「解除」を兼ねるのでボタン名は「Register」のままにする。
    private func register(bookID: String) {
        metadataStore.upsert(
            bookID: bookID,
            author: draft.author, title: draft.title,
            series: draft.series, seriesIndex: draft.seriesIndex,
            // ウインドウ版と違い、この画面は本のURLを持てている(ブックマークとinodeも入る)。
            sourceURL: sourceURL
        )
        dismiss()
    }
}

/// カバーの絵と、その右クリックメニュー(BookMetadataSheetから切り出したもの)。
///
/// ■ なぜ別のビューにしたのか(ユーザー報告 2026-09-09)
/// 元はシートの中の計算プロパティで、`CoverOverrideController`はシートが`@State`で持っていた。
/// **`@State`に入れた`ObservableObject`は購読されない**ので、カバーの指定を変えても画面が
/// 描き直される保証が無く、シート側は`@State`のカウンタ(`coverRevision`)を自分で増やして
/// 描き直しを促していた。
///
/// これが「切り取るときに残す位置を変えても、カバーもチェックマークも変わらない(閉じて開き直すと
/// 反映済み)」の正体だった。DBへの書き込みと読み戻しは毎回成功していることを実測で確認済みで、
/// 古いのは表示だけ。**`.contextMenu`の中身は`@State`の変化だけでは組み直されないことがある** ――
/// macOSのSwiftUIではメニュー系(MenuBarExtra・ToolbarItem・contextMenu)が`@State`に追随しない
/// 事例が知られていて、案内されている回避策も「`@State`ではなく観測対象から描く」ことだった。
/// 計測用のログを挟むと再現しなくなる(タイミング依存)ことも、この筋と符合する。
///
/// そこで、契機をコントローラの`@Published var revision`へ一本化し、こちらは
/// `@ObservedObject`で購読する。カウンタを手で回す必要は無くなった。
private struct CoverArea: View {
    @ObservedObject var controller: CoverOverrideController
    let item: CollectionItem
    let library: BookLibrary
    let width: CGFloat
    /// 「残す位置」を選ばせてよいか(BookMetadataSheet.isCropAnchorEffective)。
    let isCropAnchorEnabled: Bool
    let coverStore: CollectionCoverStore
    let locale: Locale

    @State private var isPickingPage = false
    @State private var isCoverDropTargeted = false

    var body: some View {
        // **`.id`はカバーとメニューにだけ掛ける。** `@ObservedObject`の購読だけでもbodyは
        // 組み直されるが、`.contextMenu`が実際に組み直される保証はそこには無い(型コメント参照)。
        // 作り直しを明示するのがいちばん確実で、これは他の箇所で見開き一覧に対して採った手と
        // 同じ(画面外のセルが解放されない件で、`.id(epoch)`だけが効いた)。
        //
        // `@State`(ページを選ぶ画面を出しているか、ドロップの当たり判定)は**このビューが持つ**
        // ので、中身を作り直しても消えない ―― ページを選ぶ画面の中でカバーを差し替えても、
        // その画面が閉じてしまうことは無い。
        thumbnailWithMenu
            .id(controller.revision)
            .popover(isPresented: $isPickingPage) {
                ExportCoverPickerContent(
                    bookID: item.bookID, controller: controller,
                    showsCropAnchor: true, isCropAnchorEnabled: isCropAnchorEnabled
                )
            }
            .accessibilityLabel(Text("Cover"))
    }

    private var thumbnailWithMenu: some View {
        CollectionCoverThumbnail(
            item: item, coverStore: coverStore,
            aspectRatio: library.coverAspectRatio,
            anchor: controller.cropAnchor(forBookID: item.bookID) ?? library.coverCropAnchor,
            displayWidth: width
        )
        .frame(width: width)
        .overlay {
            if isCoverDropTargeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        // シートは別のNSWindowなので、ウインドウ本体に付けた受け口では拾えない
        // (BookFileDropTarget参照)。ここで受けるのは画像1枚だけ ―― 本ではないので
        // bookFileDropTargetは通さない。
        .fileURLDropTarget(isTargeted: $isCoverDropTargeted) { urls in
            guard let imageURL = urls.first(where: { isImageFile($0.lastPathComponent) }) else { return }
            controller.setExternalCover(forBookID: item.bookID, fileURL: imageURL)
        }
        .contextMenu { coverMenu }
    }

    @ViewBuilder
    private var coverMenu: some View {
        // ページを選ぶ画面(ExportCoverPickerContent)には「Choose File…」も
        // 「Reset to Default (First Page)」も入っているが、要望どおりここにも並べておく
        // ―― カバーを1枚だけ差し替えるのに、いちいちページ一覧を開かせない。
        Button("Choose Page in This Book…") { isPickingPage = true }
        Button("Choose File…") { chooseExternalFile() }
        Button("Reset to Default (First Page)") {
            controller.resetCover(forBookID: item.bookID)
        }

        Divider()

        // カバーの比が枠の比と違うぶんを、どこで切るか(ユーザー要望 2026-09-09)。切る軸は
        // 画像ごとに決まるのでラベルは両方の軸を併記する(CoverCropAnchor参照)。
        // 「ライブラリの設定に従う」= 本ごとの上書きを持たない状態(nil)。
        Menu("Keep When Cropping") {
            cropAnchorItem("Use Library Setting", nil)
            cropAnchorItem("Top / Left", .start)
            cropAnchorItem("Center", .center)
            cropAnchorItem("Bottom / Right", .end)
        }
        .disabled(!isCropAnchorEnabled)
    }

    private func cropAnchorItem(_ titleKey: LocalizedStringKey, _ anchor: CoverCropAnchor?) -> some View {
        Button {
            controller.setCropAnchor(forBookID: item.bookID, anchor)
        } label: {
            // コンテキストメニューのButtonにはチェックマークが付かないため、選択中の項目には
            // 自分で印を添える(メニューバーのToggleと違い、ここは1つを選ぶ4択)。
            if controller.cropAnchor(forBookID: item.bookID) == anchor {
                Label(titleKey, systemImage: "checkmark")
            } else {
                Text(titleKey)
            }
        }
    }

    private func chooseExternalFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = String(
            localized: "Choose an image file to use as the cover.", language: locale
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.setExternalCover(forBookID: item.bookID, fileURL: url)
    }
}

import AppKit
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
    /// 対象の本(コレクションの行)。カバーの状態(抽出済みか・横長を切ったか)もここから読む。
    let item: CollectionItem
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
    @State private var isPickingPage = false
    @State private var isCoverDropTargeted = false

    /// カバーの表示幅。高さはライブラリの縦横比から決まる(2:3なら1.5倍、1:1なら等倍)。
    /// 右の4欄+説明とだいたい同じ高さになる値にしてある ―― どちらかが極端に長いと、
    /// 短いほうの下に用の無い余白が残る。
    private static let coverWidth: CGFloat = 130

    /// 「残す位置」の指定が効くか。カバーの比が枠の比と違って**実際に切ることになる**ときだけ
    /// ―― ぴったり合っているカバーに位置を指定させても何も起きない。まだ抽出できていない
    /// (比が分からない)本では、選ばせておいて後から効かせる。
    private var isCropAnchorEffective: Bool {
        guard item.coverState == .ready, item.coverAspect > 0 else { return true }
        return CoverImageResolver.cropsAnyEdge(
            imageAspect: CGFloat(item.coverAspect),
            targetAspect: library.coverAspectRatio.value
        )
    }

    var body: some View {
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
                cover
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
                Button { register() } label: {
                    Text("Register").frame(width: labelWidth)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
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

    private var cover: some View {
        CollectionCoverThumbnail(
            item: item, coverStore: collectionStore.coverStore,
            aspectRatio: library.coverAspectRatio,
            anchor: coverController?.cropAnchor(forBookID: item.bookID)
                ?? library.coverCropAnchor,
            displayWidth: Self.coverWidth
        )
        .frame(width: Self.coverWidth)
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
            coverController?.setExternalCover(forBookID: item.bookID, fileURL: imageURL)
        }
        .contextMenu { coverMenu }
        .popover(isPresented: $isPickingPage) {
            if let coverController {
                ExportCoverPickerContent(
                    bookID: item.bookID, controller: coverController,
                    showsCropAnchor: true, isCropAnchorEnabled: isCropAnchorEffective
                )
            }
        }
        .accessibilityLabel(Text("Cover"))
    }

    @ViewBuilder
    private var coverMenu: some View {
        // ページを選ぶ画面(ExportCoverPickerContent)には「Choose File…」も
        // 「Reset to Default (First Page)」も入っているが、要望どおりここにも並べておく
        // ―― カバーを1枚だけ差し替えるのに、いちいちページ一覧を開かせない。
        Button("Choose Page in This Book…") { isPickingPage = true }
        Button("Choose File…") { chooseExternalFile() }
        Button("Reset to Default (First Page)") {
            coverController?.resetCover(forBookID: item.bookID)
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
        .disabled(!isCropAnchorEffective)
    }

    private func cropAnchorItem(_ titleKey: LocalizedStringKey, _ anchor: CoverCropAnchor?) -> some View {
        Button {
            coverController?.setCropAnchor(forBookID: item.bookID, anchor)
        } label: {
            // コンテキストメニューのButtonにはチェックマークが付かないため、選択中の項目には
            // 自分で印を添える(メニューバーのToggleと違い、ここは1つを選ぶ4択)。
            if coverController?.cropAnchor(forBookID: item.bookID) == anchor {
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
        coverController?.setExternalCover(forBookID: item.bookID, fileURL: url)
    }

    // MARK: - 登録

    /// 4欄をDBへ登録する(登録済みなら上書き)。4欄すべてが空のまま押すと、既存仕様どおり
    /// `upsert`が行そのものを消す ―― 「解除」を兼ねるのでボタン名は「Register」のままにする。
    private func register() {
        metadataStore.upsert(
            bookID: item.bookID,
            author: draft.author, title: draft.title,
            series: draft.series, seriesIndex: draft.seriesIndex,
            // ウインドウ版と違い、この画面は本のURLを持てている(ブックマークとinodeも入る)。
            sourceURL: sourceURL
        )
        dismiss()
    }
}

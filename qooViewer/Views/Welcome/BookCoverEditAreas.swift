import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 本の表紙(コレクション表紙)を変える面(2026-09-30 までは 1 冊ぶんのメタデータ編集シート BookMetadataSheet の一部。
// シートはホームのインスペクタ(HomeInspectorPane)に置き換えて廃止し、表紙の面だけをここに残した)。
//
// **表紙の操作はその場で保存される**(書き出しウインドウのカバー列と同じ)。インスペクタのメタデータの欄とは独立。
// 指定の保存先は BookLayoutSettings の shelfCover* の列(本ごと)なので、どの面で変えても同じ表紙になる:
// - `CollectionCoverEditArea` ―― コレクションに入っている本。そのライブラリの比・合わせ方で出す(コレクションで見えるとおり)
// - `FileBrowserCoverArea` ―― コレクションの外の本(ファイルブラウザ)。**切らずに**出し、絵はアイコン表示と同じ提供役から引く。
//   スマートライブラリの本は、スマートライブラリに並ぶとおり(環境設定「スマートライブラリ」の形・切り取るときに残す位置)に出す
//
// どちらも、画像ファイルのドロップと、右クリックの「この本のページから選ぶ…」「ファイルを選ぶ…」「デフォルトに戻す」
// 「切り取るときに残す位置」を持つ(`isEditable` が false ―― シークレットウインドウ ―― なら、どちらも無い絵だけ)。

/// コレクションに入っている本のカバーの絵と、その右クリックメニュー(もとは BookMetadataSheet から切り出した `CoverArea`)。
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
struct CollectionCoverEditArea: View {
    @ObservedObject var controller: CoverOverrideController
    let item: CollectionItem
    let library: BookLibrary
    let width: CGFloat
    let coverStore: CollectionCoverStore
    let locale: Locale
    /// 表紙を変えられるか(シークレットウインドウでは false ―― ドロップも右クリックも無い絵だけ)。
    var isEditable = true

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
            // 表紙の左に出す(インスペクタはウインドウの右端にあり、既定の向きでは画面の右端からはみ出した。2026-09-30 の実機検証)。
            .popover(isPresented: $isPickingPage, arrowEdge: .leading) {
                ExportCoverPickerContent(
                    bookID: item.bookID, controller: controller,
                    showsCropAnchor: true
                )
            }
            .accessibilityLabel(Text("Collection Cover"))
    }

    private var thumbnailWithMenu: some View {
        CollectionCoverThumbnail(
            item: item, coverStore: coverStore,
            aspectRatio: library.coverAspectRatio,
            anchor: controller.cropAnchor(forBookID: item.bookID) ?? library.coverCropAnchor,
            fit: library.coverFit,
            displayWidth: width
        )
        .frame(width: width)
        .overlay {
            if isCoverDropTargeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        // ウインドウ全体の受け口(本を開く)より手前で、画像 1 枚だけを受ける ―― 本ではないので bookFileDropTarget は通さない
        // (BookFileDropTarget参照。シートの頃は別の NSWindow だったので自前で受ける必要があった。インスペクタでも、落とした画像を
        // 「本として開く」へ流さないために同じく自前で受ける)。
        .coverEditing(
            isEnabled: isEditable, isDropTargeted: $isCoverDropTargeted,
            onDropImage: { imageURL in
                Task { await controller.setCoverFile(forBookID: item.bookID, fileURL: imageURL) }
            },
            menu: { coverMenu }
        )
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
        // 画像ごとに決まるのでラベルは両方の軸を併記する(CoverCropAnchor参照)。4 択は `coverCropAnchorMenuItems`。
        Menu("Keep When Cropping") {
            coverCropAnchorMenuItems(controller: controller, bookID: item.bookID)
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
        WindowSheet.beginChoosing(panel) { urls in
            guard let url = urls?.first else { return }
            Task { await controller.setCoverFile(forBookID: item.bookID, fileURL: url) }
        }
    }
}

/// 表紙の右クリックの「切り取るときに残す位置」の 4 択(CollectionCoverEditArea と FileBrowserCoverArea が使う)。
///
/// **「設定なし」+ 3 つの位置**(2026-09-23、利用者の指示)。本ごとの指定(`BookLayoutSettings.coverCropAnchor`)は
/// ライブラリとスマートライブラリで**共有**で、「設定なし」(nil)ならそれぞれの設定(ライブラリの歯車 / 環境設定
/// 「スマートライブラリ」)に従う。以前は開いた場所に合わせて「ライブラリの設定に従う」「スマートライブラリの設定に従う」と
/// 書き分けていたが、同じ値がもう一方にも効くので、どちらか一方の名前で呼ぶと意味を取り違える。
/// 「メタデータの編集」ウインドウのカバー列の同じ選択(ExportCoverPickerContent)も同じ文言。
///
/// **いつでも選べる**(以前はライブラリの版で、比が枠とぴったりのカバーには押せなかった)。この画面で切らなくても、
/// もう一方の画面では切ることがあるため。
///
/// **Toggle で描く**(2026-09-23 の実機検証)。以前は Button のラベルを `Label(…, systemImage: "checkmark")` にして自分で印を
/// 添えていたが、macOS 27 SDK でリンクするとメニューの項目の画像は既定で出なくなり(CLAUDE.md「Build & run」)、印が消えて
/// どれを選んでいるか分からなかった。メニューの中の Toggle は AppKit のチェックマーク(画像ではない)で描かれる。
/// 選んでいる項目をもう一度選んでも同じ値を書くだけ(外す操作にはならない ―― 4 択の 1 つを選ぶもの)。
@ViewBuilder
private func coverCropAnchorMenuItems(controller: CoverOverrideController, bookID: String) -> some View {
    let options: [(LocalizedStringKey, CoverCropAnchor?)] = [
        ("No Setting", nil), ("Top / Left", .start), ("Center", .center), ("Bottom / Right", .end),
    ]
    ForEach(options.indices, id: \.self) { index in
        let (titleKey, anchor) = options[index]
        Toggle(isOn: Binding(
            get: { controller.cropAnchor(forBookID: bookID) == anchor },
            set: { _ in controller.setCropAnchor(forBookID: bookID, anchor) }
        )) {
            Text(titleKey)
        }
    }
}

/// コレクションに入っていない本のカバーの面(ファイルの冒頭のコメント)。
///
/// 絵は**アイコン表示と同じ提供役**(FileBrowserThumbnailProvider)から引く。指定を変えると、提供役がその本の指定の変化を
/// 見て `revision` を進め、アイコン表示のセルとこの面が同じ絵に描き直される。コントローラの `revision` も鍵に入れる
/// (指定の書き込みと同じ流れで進むので、通知の順番に頼らない)。ライブラリの比が無いので**切らずに**枠へ収める。
///
/// スマートライブラリの版(`smartLibraryCrop`)は、スマートライブラリのカバーの形の枠に、本ごとの指定 ?? 環境設定の
/// 所を残して切って出す(スマートライブラリに並ぶとおりに見せ、右クリックの「切り取るときに残す位置」で選んだ所がすぐ見えるように)。右クリックの「切り取るときに残す位置」はどちらの版にも出す。
struct FileBrowserCoverArea: View {
    /// スマートライブラリの表紙の見せ方(環境設定「スマートライブラリ」の値)。
    struct SmartLibraryCrop {
        let shape: SmartLibraryCoverShape
        /// 形の合わせ方(余白を付けるなら切らない)。
        let fit: CoverFit
        /// 本ごとの指定が無いときに残す位置。
        let defaultAnchor: CoverCropAnchor
    }

    @ObservedObject var controller: CoverOverrideController
    let entry: FileBrowserEntry
    let bookID: String
    let width: CGFloat
    let locale: Locale
    var smartLibraryCrop: SmartLibraryCrop?
    /// 表紙を変えられるか(`CollectionCoverEditArea.isEditable`)。
    var isEditable = true
    /// 作った絵をディスクキャッシュへ書くか(シークレットウインドウでは false。FileBrowserThumbnailProvider の型コメント)。
    var savesToDisk = true
    /// 絵のディスクキャッシュの鍵を知っていれば(スマートライブラリの本。`FileBrowserThumbnailProvider.thumbnail(…knownKey:)`)。
    var knownKey: FileBrowserThumbnailKey?
    /// 高さの上限(インスペクタ。2026-09-30)。`width` は使ってよい幅で、上限があると:
    /// - 切らずに出す表紙は、絵の比のまま幅 × 上限の箱に収め、**枠も絵の大きさに縮める**(横長の表紙が幅で頭打ちになり、2:3 の枠の
    ///   中で上下に空白を残して小さく見えていた。利用者の指摘)
    /// - 形の決まった枠(スマートライブラリの 2:3 / 1:1 / 3:2)は、枠の高さが上限を超えるぶん幅を縮める
    /// nil なら従来どおり、幅 × `frameHeightRatio` の枠。
    var maxHeight: CGFloat?

    @EnvironmentObject private var thumbnails: FileBrowserThumbnailProvider
    /// 余白を付けるときの余白の色(スマートライブラリの版。環境設定「外観」→「ホーム」→「スマートライブラリ」)。
    @EnvironmentObject private var appearance: AppearanceSettings
    @State private var image: CGImage?
    /// 絵を作れなかった(読めない本・画像の無い本)。読み込み中の印を出し続けないため。
    @State private var didFail = false
    @State private var isPickingPage = false
    @State private var isCoverDropTargeted = false

    /// 枠の高さ(幅に対する比)。既定のライブラリと同じ 2:3。
    static let heightRatio: CGFloat = 1.5

    private var kind: BookThumbnailer.Kind? {
        BookThumbnailer.kind(
            forName: entry.url.lastPathComponent, isNavigableFolder: entry.isNavigableFolder,
            isPackage: entry.isPackage, isSymbolicLink: entry.isSymbolicLink
        )
    }

    /// 絵の比(幅 ÷ 高さ)。
    static func aspect(of image: CGImage) -> CGFloat {
        image.height > 0 ? CGFloat(image.width) / CGFloat(image.height) : 0
    }

    /// 枠の比(スマートライブラリの版で、形が「実際の画像に合わせる」でないときだけ)。切るか余白を付けるかは、絵が届いてから
    /// その比で決める(`CoverFit.resolved`。「向きで切り替える」は表紙ごとに違う)。
    private var cropAspect: CGFloat? { smartLibraryCrop.flatMap { $0.shape.cropAspect } }

    /// 枠の高さ(幅に対する比)。スマートライブラリの版はその形の比。
    private var frameHeightRatio: CGFloat { smartLibraryCrop?.shape.heightRatio ?? Self.heightRatio }

    /// 描く枠の大きさ(`maxHeight` のコメント)。
    private var frameSize: CGSize {
        let ratioFrame = Self.shrunk(CGSize(width: width, height: width * frameHeightRatio), toMaxHeight: maxHeight)
        guard let maxHeight, cropAspect == nil else { return ratioFrame }
        // 切らずに出す表紙: 絵が来たら絵の比で幅 × 上限の箱に収める(来るまでは 2:3 の場所取り)。
        guard let image, image.width > 0, image.height > 0 else { return ratioFrame }
        let aspect = Self.aspect(of: image)
        let fittedWidth = min(width, maxHeight * aspect)
        return CGSize(width: fittedWidth, height: fittedWidth / aspect)
    }

    /// 高さが上限を超えるなら、比を保って縮める。
    private static func shrunk(_ size: CGSize, toMaxHeight maxHeight: CGFloat?) -> CGSize {
        guard let maxHeight, size.height > maxHeight, size.height > 0 else { return size }
        return CGSize(width: size.width * maxHeight / size.height, height: maxHeight)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let frameSize = frameSize
        ZStack {
            if let image {
                if let cropAspect, let smartLibraryCrop,
                   smartLibraryCrop.fit.resolved(imageAspect: Self.aspect(of: image), frameAspect: cropAspect) == .crop {
                    // 本ごとの指定 ?? 環境設定の所を残して切る(スマートライブラリのグリッドと同じ。SmartLibraryContent.cropAnchor)。
                    let anchor = controller.cropAnchor(forBookID: bookID) ?? smartLibraryCrop.defaultAnchor
                    Image(decorative: CoverImageResolver.cropped(image, to: cropAspect, anchor: anchor), scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: frameSize.width, height: frameSize.height)
                        .clipShape(shape)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                } else if cropAspect != nil {
                    // 余白を付ける(「向きで切り替える」で余白になった表紙も)。スマートライブラリのグリッドと同じ見た目(SmartBookThumbnail)。
                    ZStack {
                        appearance.effectiveSmartLibraryCoverMargin
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    }
                    .frame(width: frameSize.width, height: frameSize.height)
                    .clipShape(shape)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                } else {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                }
            } else {
                shape.fill(Color.secondary.opacity(0.15))
                if !didFail { ProgressView().controlSize(.small) }
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .overlay {
            if isCoverDropTargeted {
                shape.strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .contentShape(shape)
        .task(id: loadKey) { await load() }
        // CollectionCoverEditArea と同じく自前で受ける。画像 1 枚だけ。
        .coverEditing(
            isEnabled: isEditable, isDropTargeted: $isCoverDropTargeted,
            onDropImage: { imageURL in
                Task { await controller.setCoverFile(forBookID: bookID, fileURL: imageURL) }
            },
            menu: {
                Button("Choose Page in This Book…") { isPickingPage = true }
                Button("Choose File…") { chooseExternalFile() }
                Button("Reset to Default (First Page)") { controller.resetCover(forBookID: bookID) }
                Divider()
                // ライブラリの版(CollectionCoverEditArea)と同じ 4 択(`coverCropAnchorMenuItems`)。切らずに出している面でも出す ――
                // 本ごとの指定はライブラリとスマートライブラリの両方に効くので、この面が切らずに出していても選ぶ意味がある。
                Menu("Keep When Cropping") {
                    coverCropAnchorMenuItems(controller: controller, bookID: bookID)
                }
            }
        )
        // 選んだ位置のチェックマークを確実に付け直す(`.contextMenu` は描き直しだけでは組み直されないことがある。CollectionCoverEditArea の
        // `.id(controller.revision)` と同じ手)。`@State`(絵・ページを選ぶ画面)はこのビュー自身が持つので消えない。
        .id(controller.revision)
        // 表紙の左に出す(CollectionCoverEditArea と同じ理由)。
        // 「切り取るときに残す位置」もコレクションの本と同じく出す(2026-10-04 の監査 SL-10。以前はコレクションの本だけで、ファイル
        // ブラウザ・スマートライブラリの本の吹き出しには無かった。CLAUDE.md「設定する所はどこも同じ 4 択」)。
        .popover(isPresented: $isPickingPage, arrowEdge: .leading) {
            ExportCoverPickerContent(bookID: bookID, controller: controller, showsCropAnchor: true)
        }
        .accessibilityLabel(Text("Collection Cover"))
    }


    /// 絵を頼み直す条件。出どころの鍵(`FileBrowserThumbnailProvider.sourceKey`)が変わったときだけ ―― 全体の `revision` は表紙を
    /// 1 冊抽出するたびに進むので、それを鍵にすると、選んでいる本と関係の無い抽出のたびに頼み直して絵を作り直していた(2026-10-05 の
    /// 効率の監査 C1。グリッドのセルは 2026-09-25 にこの形にした)。表紙の指定・表紙ができた・キャッシュを消した、は出どころの鍵に入る。
    private var loadKey: String {
        let source = kind.map { thumbnails.sourceKey(for: entry, kind: $0) } ?? ""
        let known = knownKey.map { "\($0.volume)-\($0.inode)-\($0.modified)-\($0.size)" } ?? ""
        return "\(source)|\(known)|\(controller.revision)"
    }

    private func load() async {
        guard let kind else {
            didFail = true
            return
        }
        let buffer = await thumbnails.thumbnail(
            for: entry, kind: kind, pixelSize: 512, savesToDisk: savesToDisk, knownKey: knownKey
        )
        guard !Task.isCancelled else { return }
        guard let made = buffer?.makeImage() else {
            didFail = image == nil
            return
        }
        didFail = false
        image = made
    }

    private func chooseExternalFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose an image file to use as the cover.", language: locale)
        WindowSheet.beginChoosing(panel) { urls in
            guard let url = urls?.first else { return }
            Task { await controller.setCoverFile(forBookID: bookID, fileURL: url) }
        }
    }
}

private extension View {
    /// 表紙を変える口(画像ファイルのドロップと右クリック)。`isEnabled` が false なら何も付けない(シークレットウインドウ ――
    /// 保存データへの書き込み ―― と、シークレットフォルダの本。後者は表紙の下に理由を出す。HomeInspectorBookView.body)。
    /// シークレットウインドウでは値がウインドウの一生のあいだ変わらないが、シークレットフォルダの本では一覧を変えると変わり、
    /// `if` で分けたビューが作り直される(2026-10-04 の監査 X-5。以前は「変わらないので作り直されない」と書いていた)。表紙の側は
    /// 持つ状態がドロップの強調だけなので、作り直されても失うものは無い。
    @ViewBuilder
    func coverEditing<MenuContent: View>(
        isEnabled: Bool, isDropTargeted: Binding<Bool>, onDropImage: @escaping (URL) -> Void,
        @ViewBuilder menu: () -> MenuContent
    ) -> some View {
        if isEnabled {
            let menuContent = menu()
            // 画像のドロップ。インスペクタの中では列の受け口に任せる(HomeInspectorCoverDrop の型コメント)。
            modifier(CoverImageDropModifier(isTargeted: isDropTargeted, onDropImage: onDropImage))
                .contextMenu { menuContent }
        } else {
            self
        }
    }
}


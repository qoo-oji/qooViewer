import SwiftUI

/// ホームの右ペイン「インスペクタ」(2026-09-30、利用者の要望)。Finder のプレビュー(右ペイン)と同じ位置付けで、中央の一覧で
/// 選んでいるものを見せる。
///
/// ```
/// [帯]
/// [ファイルブラウザ / スマートライブラリ / ライブラリ(中央)] | [インスペクタ]
/// ```
///
/// ■ 並び(上から)
/// 1. 絵 ―― 本はコレクション表紙(メタデータの編集シートの表紙の面をそのまま置いた。画像のドロップ・右クリックでページ/ファイルを
///    選ぶ・デフォルトに戻す・切り取るときに残す位置)。本でないものは Finder のプレビューに揃える(動画はサムネイル。
///    `HomeInspectorItemPreview`)
/// 2. 名前(ファイル名)と、種類・サイズの 1 行
/// 3. 本ならメタデータの欄(その場で直せる。`HomeInspectorMetadataSection`)
/// 4. 情報(種類・サイズ・場所・作成日・変更日。Finder のプレビューと同じ項目)
///
/// ■ 何を見せるか(`HomeInspectorSubject`)
/// - ファイルブラウザ: 選んだ項目。フォルダは画像フォルダ(1 冊の本)かどうかを 1 回だけ調べる(`ShelfFolderResolver.isSingleBookFolder`)
/// - スマートライブラリ: 選んだ本・束
/// - ライブラリ: コレクションの中なら選んだ本、一覧なら選んだコレクション
/// 何も選んでいなければ「選択されていません」、2 つ以上なら数だけ。
///
/// ■ 出し入れ
/// `WelcomeLibraryState.isInspectorShown`(3 つの画面で共通)。3 つの機能が全部 OFF のホームには無い。右クリックの
/// 「メタデータの編集…」は、その本を選んでインスペクタを出し、題の欄に焦点を入れる(以前の 1 冊ぶんのシートの代わり)。
///
/// ■ シークレットウインドウ
/// 見るだけ(メタデータの欄は淡色、表紙はドロップ・右クリックを受けない)。保存データへ書かない約束(AppState.isPrivateWindow)。
///
/// ■ すりガラス面
/// ホーム全体が `PanelSurface.welcome`。文字・アイコン → `.panelOutlinedContent()`(部品ごと)、入力欄・絵 → 何も掛けない。
struct HomeInspectorPane: View {
    @ObservedObject var home: WelcomeLibraryState
    @ObservedObject var fileBrowser: FileBrowserState
    @ObservedObject var smartLibrary: SmartLibraryViewState
    /// 保存データへ書けるか(シークレットウインドウでは false)。
    let allowsEditing: Bool

    @EnvironmentObject private var collectionStore: CollectionStore
    @Environment(\.locale) private var locale

    @EnvironmentObject private var appState: AppState

    /// ペインの幅(`onGeometryChange` で測る)。
    @State private var paneWidth: CGFloat = WelcomeLibraryState.defaultInspectorWidth
    /// 表紙への画像のドロップの受け口(列に 1 つ。HomeInspectorCoverDrop の型コメント)。
    @State private var coverDrop = HomeInspectorCoverDrop()

    var body: some View {
        content(for: subject, width: max(0, paneWidth - Self.horizontalPadding * 2))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
            // 余白のクリックで入力欄を離れる(欄を離れたときに書き、足したまま空の入力欄を消すため。
            // releasesFieldFocusOnBackgroundClick のコメント)。
            .releasesFieldFocusOnBackgroundClick()
            .homeInspectorDropTarget(coverDrop, appState: appState)
    }

    static let horizontalPadding: CGFloat = 14

    /// いま選んでいるもの。
    private var subject: HomeInspectorSubject {
        switch home.mode {
        case .browser:
            let entries = fileBrowser.selectedEntries
            guard let first = entries.first else { return .none }
            guard entries.count == 1 else { return .multiple(entries.count) }
            return .fileBrowserEntry(first, effective: fileBrowser.effective(first), currentFolder: fileBrowser.currentFolder)
        case .smart:
            return HomeInspectorSubject.smart(selection: smartLibrary.selection.ids, items: smartLibrary.gridItems)
        case .shelf:
            if home.openedCollectionID != nil {
                let ids = home.selectedItemIDs
                guard let first = ids.first else { return .none }
                return ids.count == 1 ? .collectionItem(first) : .multiple(ids.count)
            }
            let ids = home.selectedCollectionIDs
            guard let first = ids.first else { return .none }
            return ids.count == 1 ? .collection(first) : .multiple(ids.count)
        case .classic:
            return .none
        }
    }

    @ViewBuilder
    private func content(for subject: HomeInspectorSubject, width: CGFloat) -> some View {
        switch subject {
        case .none:
            HomeInspectorMessage(systemImage: nil, text: String(localized: "No Selection", language: locale))
        case .multiple(let count):
            HomeInspectorMessage(
                systemImage: "square.on.square",
                text: String(format: String(localized: "%lld items", language: locale), count)
            )
        case .fileBrowserEntry(let entry, let effective, let currentFolder):
            HomeInspectorScroll {
                HomeInspectorFileBrowserItem(
                    entry: entry, effective: effective, currentFolder: currentFolder, width: width,
                    allowsEditing: allowsEditing, home: home
                )
            }
            .id(entry.id)
        case .smartBook(let book):
            HomeInspectorScroll {
                HomeInspectorBookView(
                    book: .smart(book), width: width, allowsEditing: allowsEditing, home: home
                )
            }
            .id(book.id)
        case .smartGroup(let name, let bookCount):
            HomeInspectorScroll {
                VStack(spacing: 12) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.secondary)
                        .panelOutlinedContent()
                        .frame(height: 110)
                    HomeInspectorTitle(
                        name: name,
                        subtitle: String(format: String(localized: "%lld books", language: locale), bookCount)
                    )
                }
            }
            .id(name)
        case .collectionItem(let id):
            // モデルは渡さず id と本の id だけ(別のウインドウが外すと、持っていたモデルを読んで落ちる ―― 以前のシートの
            // 監査 2026-09-09。本の面は描くたびに id から引き直す)。
            if let item = collectionStore.item(withID: id) {
                HomeInspectorScroll {
                    HomeInspectorBookView(
                        book: .collectionItem(id: id, bookID: item.bookID), width: width, allowsEditing: allowsEditing,
                        home: home
                    )
                }
                .id(id)
            } else {
                HomeInspectorMessage(systemImage: nil, text: String(localized: "No Selection", language: locale))
            }
        case .collection(let id):
            if let collection = collectionStore.collection(withID: id), let library = collection.library {
                HomeInspectorScroll {
                    HomeInspectorCollectionView(collection: collection, library: library, width: width, home: home)
                }
                .id(id)
            } else {
                HomeInspectorMessage(systemImage: nil, text: String(localized: "No Selection", language: locale))
            }
        }
    }
}

/// インスペクタが見せるもの(`HomeInspectorPane` の型コメント「何を見せるか」)。
enum HomeInspectorSubject: Equatable {
    case none
    case multiple(Int)
    /// ファイルブラウザの項目。`effective` は記号リンク・エイリアスの先(本かどうか・メタデータはこちらで見る。
    /// Finder と同じく、リンクは先の項目として扱う ―― 右クリックの「メタデータの編集…」と同じ)。
    case fileBrowserEntry(FileBrowserEntry, effective: FileBrowserEntry, currentFolder: URL?)
    case smartBook(SmartBook)
    case smartGroup(name: String, bookCount: Int)
    case collectionItem(UUID)
    case collection(UUID)

    /// スマートライブラリの選択から。リスト表示で開いた束の中の本は並び(`gridItems`)の直下に無いので、束の中も探す。
    static func smart(selection ids: Set<String>, items: [SmartGridItem]) -> HomeInspectorSubject {
        guard let id = ids.first else { return .none }
        guard ids.count == 1 else { return .multiple(ids.count) }
        if id.hasPrefix(SmartGridItem.bookIDPrefix) {
            let path = String(id.dropFirst(SmartGridItem.bookIDPrefix.count))
            for item in items {
                switch item {
                case .book(let book) where book.id == path:
                    return .smartBook(book)
                case .group(_, _, let books):
                    if let book = books.first(where: { $0.id == path }) { return .smartBook(book) }
                default:
                    break
                }
            }
            return .none
        }
        for item in items where item.id == id {
            if case .group(_, let name, let books) = item { return .smartGroup(name: name, bookCount: books.count) }
        }
        return .none
    }
}

/// インスペクタの縦のスクロール(中身は上から詰める)。
private struct HomeInspectorScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            content
                .padding(.horizontal, HomeInspectorPane.horizontalPadding)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.automatic)
    }
}

// MARK: - ファイルブラウザの項目

/// ファイルブラウザで選んだ項目 1 つ。本(書庫・PDF・EPUB・画像フォルダ)なら本の面、それ以外は Finder のプレビューの形。
private struct HomeInspectorFileBrowserItem: View {
    let entry: FileBrowserEntry
    let effective: FileBrowserEntry
    let currentFolder: URL?
    let width: CGFloat
    let allowsEditing: Bool
    let home: WelcomeLibraryState

    /// 本かどうか。ファイルは名前で決まり、フォルダは画像フォルダかを 1 回だけ調べる(調べる間は nil)。
    @State private var isBook: Bool?
    /// 「メタデータの編集…」の頼みで本と分かったフォルダのパス。調べ終わりが後から「本でない」を書いても、これを優先する
    /// (頼みは欄が拾うと消えるので、頼みそのものは後で見られない)。
    @State private var bookPathConfirmedByRequest: String?

    var body: some View {
        Group {
            switch isBook {
            case true?:
                HomeInspectorBookView(
                    book: .fileBrowser(entry: effective, displayed: entry, currentFolder: currentFolder),
                    width: width, allowsEditing: allowsEditing, home: home
                )
            case false?:
                HomeInspectorPlainItemView(entry: entry, currentFolder: currentFolder, width: width,
                                           savesToDisk: allowsEditing)
            case nil:
                // 調べている間も、本でないものと同じ形で出しておく(絵・名前・情報は同じ。本と分かったら表紙とメタデータに替わる)。
                HomeInspectorPlainItemView(entry: entry, currentFolder: currentFolder, width: width,
                                           savesToDisk: allowsEditing)
            }
        }
        // リンクの先が後から解けて `effective` が変わったら決め直す(一覧はリンクの先を読み込みの後で解く ―― FileBrowserState.resolveLinkTargets)。
        .task(id: effective) { await decide() }
        // 選んだままのフォルダに「メタデータの編集…」の頼みだけが置かれたときも本として出し直す。選択が変わらないので
        // `effective` も変わらず、上の決め直しは走らない(2026-10-01 のレビュー: ネットワーク越し・TCC の保護下の画像フォルダを
        // 選んだまま右クリックの「メタデータの編集…」を押すと、本でない形のまま欄が出ず、頼みも拾われずに残っていた)。
        // `home` は購読しない(ほかの値の変化でこの面を描き直さない)ので、頼みだけを受け取る。
        .onReceive(home.$inspectorFocusRequest) { _ in noteFocusRequest() }
    }

    /// 選んでいるフォルダへの頼みが来ていたら、本として出す(頼みを置いた入り口が、本であることを確かめている ―― `decide`)。
    private func noteFocusRequest() {
        guard effective.isDirectory, !effective.isVolume, !effective.isPackage,
              home.hasInspectorFocusRequest(for: effective.url.path) else { return }
        bookPathConfirmedByRequest = effective.url.path
        if isBook != true { isBook = true }
    }

    private func decide() async {
        if effective.isVolume || effective.isPackage {
            isBook = false
        } else if !effective.isDirectory {
            isBook = effective.isBookFile
        } else if home.hasInspectorFocusRequest(for: effective.url.path) || bookPathConfirmedByRequest == effective.url.path {
            // 右クリックの「メタデータの編集…」から来た: その入り口が画像フォルダであることを確かめてから頼みを置いている
            // (FileBrowserActions.editMetadata)。読み直さない(ネットワーク越しのフォルダでも本として出せる)。
            isBook = true
        } else {
            // 利用者が入っていないフォルダの中を自分から読むので、ファイルブラウザの約束に従う(docs/15「サンドボックスと TCC の約束」):
            // ネットワーク越しのボリュームは読まない(矢印キーで選ぶたびに共有へ取りに行き、眠っている NAS では 1 つごとに 30 秒
            // FileIO を塞ぐ)、TCC の保護下の場所は見ているフォルダと同じ場所のときだけ(読むと許可のダイアログが出る)。
            // 読まなかったフォルダは本でないものとして出す(右クリックの「メタデータの編集…」なら、確かめたうえで本として出る)。
            // 判定そのものは子フォルダの中を全部読まない `ShelfFolderResolver.isSingleBookFolder`(右クリックと同じ)。
            let url = effective.url
            guard DirectoryProbe.mayReadUnentered(url, from: currentFolder, mountTable: .current()) else {
                isBook = false
                return
            }
            isBook = nil
            let result = await FileIO.perform { ShelfFolderResolver.isSingleBookFolder(url) }
            guard !Task.isCancelled else { return }
            // 調べている間に「メタデータの編集…」で本と分かっていたら、そちらを残す(欄が出て頼みを拾ったあとで消さない)。
            isBook = result || bookPathConfirmedByRequest == url.path
        }
    }
}

/// 本でない項目(Finder のプレビューの形: 絵・名前・情報)。
private struct HomeInspectorPlainItemView: View {
    let entry: FileBrowserEntry
    let currentFolder: URL?
    let width: CGFloat
    let savesToDisk: Bool

    var body: some View {
        let facts = HomeInspectorFileFacts(entry: entry)
        VStack(spacing: 14) {
            HomeInspectorItemPreview(
                entry: entry, currentFolder: currentFolder, width: width, maxHeight: HomeInspectorBookView.maxCoverHeight,
                savesToDisk: savesToDisk
            )
            HomeInspectorTitle(
                name: entry.displayName, subtitle: HomeInspectorFormat.subtitle(kind: facts.kind, size: facts.size)
            )
            HomeInspectorFileInfoSection(
                facts: facts, folderSizePolicy: entry.isVolume ? .never : .ifReadable(currentFolder: currentFolder)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - コレクション

/// ライブラリの一覧で選んだコレクション 1 つ(札の絵・名前・冊数・情報)。
private struct HomeInspectorCollectionView: View {
    let collection: BookCollection
    let library: BookLibrary
    let width: CGFloat
    let home: WelcomeLibraryState

    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var coverExtractor: CollectionCoverExtractor
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.locale) private var locale

    var body: some View {
        // 札はほぼ正方形(CollectionTile の型コメント)。表紙と同じ高さの上限で抑える。
        let side = min(width, HomeInspectorBookView.maxCoverHeight)
        VStack(spacing: 14) {
            CollectionTile(
                collection: collection,
                items: collectionStore.leadingItems(
                    in: collection, sort: home.itemSort, limit: library.coverAspectRatio.tileCellCount
                ),
                exists: { collectionStore.cachedFileExists(for: $0) },
                isExtracting: { coverExtractor.inFlightItemIDs.contains($0.id) },
                cropAnchor: { item in
                    layoutStore.bookLayoutSettings(forBookID: item.bookID)?.coverCropAnchor ?? library.coverCropAnchor
                },
                coverRevision: { collectionStore.coverRevision(for: $0) },
                coverStore: collectionStore.coverStore,
                tileStore: collectionStore.tileStore,
                aspectRatio: library.coverAspectRatio,
                fit: library.coverFit,
                backgroundColor: appearance.effectiveCollectionTileBackground,
                size: side,
                badgeSize: appearance.collectionTileBadgeSize,
                showsName: false,
                onClick: {}
            )
            .frame(width: side)
            .allowsHitTesting(false)
            HomeInspectorTitle(
                name: collection.name,
                subtitle: String(format: String(localized: "%lld books", language: locale), collection.items.count)
            )
            HomeInspectorInfoSection(rows: rows)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rows: [HomeInspectorInfoRow] {
        var rows: [HomeInspectorInfoRow] = [
            .init(label: "Library", value: library.displayName(language: locale)),
        ]
        if let folder = collection.autoFolderURL {
            rows.append(.init(label: "Auto-Add Folder", value: HomeInspectorFormat.abbreviated(folder.path),
                              help: folder.path))
        }
        rows.append(.init(label: "Created", value: HomeInspectorFormat.date(collection.createdAt, locale: locale)))
        rows.append(.init(label: "Modified", value: HomeInspectorFormat.date(collection.updatedAt, locale: locale)))
        return rows
    }
}

import SwiftUI

/// インスペクタに出す本 1 冊の出どころ。
enum HomeInspectorBook {
    /// ファイルブラウザの項目。`entry` は本として扱う項目(リンクなら先)、`displayed` は一覧で選んだ項目そのもの(名前と情報)。
    case fileBrowser(entry: FileBrowserEntry, displayed: FileBrowserEntry, currentFolder: URL?)
    case smart(SmartBook)
    /// コレクションの中の本。**モデルではなく id で持ち**、描くたびに引き直す(別のウインドウが外して保存すると、持っていたモデルを
    /// 読んだ時点で "model instance was invalidated" で落ちる。以前のメタデータ編集シートの監査 2026-09-09 と同じ理由)。
    case collectionItem(id: UUID, bookID: String)

    /// 本の id(パス。BookLoader が付ける id)。
    var bookID: String {
        switch self {
        case .fileBrowser(let entry, _, _): entry.url.path
        case .smart(let book): book.id
        case .collectionItem(_, let bookID): bookID
        }
    }
}

/// インスペクタの本 1 冊(表紙・名前・メタデータ・情報)。
///
/// ■ 表紙の面(以前のメタデータ編集シートの面をそのまま置いた)
/// - コレクションの中の本 → そのライブラリの比・合わせ方(`CollectionCoverEditArea`)
/// - ファイルブラウザの本 → どこかのコレクションに入っていればその行とライブラリで同じ面、入っていなければ**切らずに**
///   (`FileBrowserCoverArea`。絵はアイコン表示と同じ提供役 ―― 指定したコレクション表紙がアイコン表示にもそのまま出る)。
///   ライブラリ機能が OFF の間はコレクションの行を引かない(全件の取り出しを伴う。AppStores.applyLibraryFeature の約束)
/// - スマートライブラリの本 → スマートライブラリに並ぶとおり(環境設定「スマートライブラリ」の形・切り取るときに残す位置)
/// どれも表紙の変更はその場で保存される(メタデータの欄とは独立)。
struct HomeInspectorBookView: View {
    let book: HomeInspectorBook
    /// 使える幅(左右の余白を除いた)。
    let width: CGFloat
    let allowsEditing: Bool
    let home: WelcomeLibraryState

    /// 表紙・絵の高さの上限(2026-09-30)。幅はペインいっぱいまで使ってよく、高さだけをこれで抑える ―― 縦長の表紙は高さで止まり、
    /// 横長の表紙・動画はペインの幅まで広がる(以前は幅の上限 220pt で止めていたので、横長は縦長の半分以下の大きさになり、
    /// ペインを広げても変わらなかった。利用者の指摘)。
    static let maxCoverHeight: CGFloat = 300

    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var secretFolders: SecretFolderStore
    @Environment(\.locale) private var locale

    /// 表紙を変えられるか。シークレットフォルダの本は変えさせない(表紙の指定はレイアウトの行と元画像の複製を作る。
    /// SecretFolderStore)。変えられないときは右クリックとドロップを付けず、理由を表紙の下に出す(body。監査 X-5・決定 11)。
    private var allowsCoverEditing: Bool { allowsEditing && !secretFolders.contains(path: bookID) }

    /// 表紙の指定の口。環境オブジェクトが要るので init では作れず、onAppear で組み立てる(メタデータの編集シートと同じ形)。
    @State private var coverController: CoverOverrideController?
    /// 表紙を選ぶ画面が本を読むときの場所(コレクションの本はブックマークを解いてから入る。`resolveURL` が読む)。
    @State private var urlBox = URLBox()
    /// コレクションの本の、ブックマークを解いた場所(解けるまでは記録したパス)。
    @State private var resolvedURL: URL?
    /// コレクションの本の、読み直した情報(ファイルに触るので FileIO の上で。読むまでは nil)。
    @State private var loadedFacts: HomeInspectorFileFacts?

    private final class URLBox {
        var url: URL?
    }

    private var bookID: String { book.bookID }

    private var coverWidth: CGFloat { width }

    /// メタデータの行を作るときのブックマークに使う場所。
    private var sourceURL: URL {
        switch book {
        case .fileBrowser(let entry, _, _): entry.url
        case .smart(let smartBook): URL(fileURLWithPath: smartBook.id, isDirectory: smartBook.kind == .folder)
        // `URL(fileURLWithPath:)`(isDirectory 無し)は lstat するので、body から呼ぶここではパスから作るだけ(2026-10-06 の応答性の点検 R3-13)。
        case .collectionItem(_, let bookID): resolvedURL ?? URL(filePath: bookID)
        }
    }

    /// コレクションの本の行(外されていれば nil。描くたびに引き直す ―― `HomeInspectorBook.collectionItem`)。
    private var collectionItem: CollectionItem? {
        guard case .collectionItem(let id, _) = book else { return nil }
        return collectionStore.item(withID: id)
    }

    var body: some View {
        VStack(spacing: 14) {
            cover
            // シークレットフォルダの本は表紙を変えさせない(右クリックとドロップを付けない ―― シークレットウインドウと同じ見え方)。
            // 理由が見えなかったので、メタデータの欄と同じ注意書きを表紙の下にも出す(2026-10-04 の監査 X-5・決定 11 の (b))。
            // シークレットウインドウ(allowsEditing が false)は窓ごと見るだけなので出さない(docs/14「インスペクタ」)。
            if allowsEditing, !allowsCoverEditing {
                Label("This book is in a secret folder, so its cover can’t be changed.", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelOutlinedContent()
            }
            HomeInspectorTitle(name: name, subtitle: HomeInspectorFormat.subtitle(kind: facts?.kind, size: facts?.size))
            HomeInspectorMetadataSection(bookID: bookID, sourceURL: sourceURL, allowsEditing: allowsEditing, home: home)
                .id(bookID)
            if let facts {
                HomeInspectorFileInfoSection(facts: facts, folderSizePolicy: folderSizePolicy, extraRows: extraRows)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // 別のウインドウ(メタデータの編集ウインドウ・書き出しウインドウ)から同じ本のカバーを変えられたときも追いつく
        // (CoverOverrideController.revision に一本化。以前のシートと同じ)。
        .onReceive(NotificationCenter.default.publisher(for: .layoutDataDidChange)) { _ in
            coverController?.noteCoverDidChange()
        }
        .onAppear {
            guard coverController == nil else { return }
            urlBox.url = sourceURL
            let box = urlBox
            coverController = CoverOverrideController(
                target: .collectionCover, layoutStore: layoutStore, preferences: preferences,
                // この画面は本を 1 冊しか扱わないので、URL の解決は済んだものを返すだけ。
                resolveURL: { [box] _ in box.url }
            )
        }
        .task {
            await loadCollectionItemFacts()
            await loadSmartBookFacts()
        }
    }

    // MARK: - 表紙

    @ViewBuilder
    private var cover: some View {
        if let coverController {
            switch book {
            case .collectionItem:
                if let item = collectionItem, let library = item.collection?.library {
                    collectionCover(controller: coverController, item: item, library: library)
                }
            case .fileBrowser(let entry, _, _):
                if let registered = registeredCollectionItem {
                    collectionCover(controller: coverController, item: registered.item, library: registered.library)
                } else {
                    FileBrowserCoverArea(
                        controller: coverController, entry: entry, bookID: bookID, width: coverWidth, locale: locale,
                        isEditable: allowsCoverEditing, savesToDisk: allowsEditing, maxHeight: Self.maxCoverHeight
                    )
                }
            case .smart(let smartBook):
                FileBrowserCoverArea(
                    controller: coverController, entry: smartBook.fileBrowserEntry, bookID: bookID, width: coverWidth,
                    locale: locale,
                    smartLibraryCrop: .init(shape: preferences.smartLibraryCoverShape,
                                            fit: preferences.smartLibraryCoverFit,
                                            defaultAnchor: preferences.smartLibraryCoverCropAnchor),
                    isEditable: allowsCoverEditing, savesToDisk: allowsEditing, knownKey: smartBook.thumbnailKey,
                    maxHeight: Self.maxCoverHeight
                )
            }
        } else {
            // 高さを合わせるためだけの場所取り(一瞬で入れ替わる)。
            Color.clear.frame(height: min(coverWidth * FileBrowserCoverArea.heightRatio, Self.maxCoverHeight))
        }
    }

    private func collectionCover(
        controller: CoverOverrideController, item: CollectionItem, library: BookLibrary
    ) -> some View {
        // ライブラリの比の枠(幅 ÷ 高さ = coverAspectRatio.value)。高さが上限を超えるぶん幅を縮める。
        CollectionCoverEditArea(
            controller: controller, item: item, library: library,
            width: min(coverWidth, Self.maxCoverHeight * library.coverAspectRatio.value),
            coverStore: collectionStore.coverStore, locale: locale, isEditable: allowsCoverEditing
        )
    }

    /// ファイルブラウザの本が入っているコレクションの行とそのライブラリ(入っていなければ nil)。ライブラリ機能が OFF の間は引かない。
    private var registeredCollectionItem: (item: CollectionItem, library: BookLibrary)? {
        guard preferences.libraryFeatureEnabled else { return nil }
        return collectionStore.items(forBookID: bookID).lazy
            .compactMap { item in item.collection?.library.map { (item, $0) } }
            .first
    }

    // MARK: - 名前と情報

    private var name: String {
        switch book {
        case .fileBrowser(_, let displayed, _): displayed.displayName
        case .smart(let smartBook): smartBook.fileName
        case .collectionItem(_, let bookID): URL(filePath: bookID).lastPathComponent
        }
    }

    private var facts: HomeInspectorFileFacts? {
        switch book {
        case .fileBrowser(_, let displayed, _): HomeInspectorFileFacts(entry: displayed)
        // スマートライブラリの本は、探したときの写しをまず出し、選んだ 1 冊だけ読み直したら差し替える(`loadSmartBookFacts`)。
        case .smart(let smartBook): loadedFacts ?? HomeInspectorFileFacts(smartBook: smartBook)
        case .collectionItem: loadedFacts
        }
    }

    /// フォルダの本の大きさを数えるか(ネットワーク越し・TCC の保護下は数えない。ファイルブラウザは見ているフォルダも考える)。
    /// コレクションの本は、ブックマークのスコープの中で情報と一緒に数える(`loadCollectionItemFacts`)ので、節には数えさせない。
    private var folderSizePolicy: HomeInspectorFileInfoSection.FolderSizePolicy {
        switch book {
        case .fileBrowser(_, _, let folder): .ifReadable(currentFolder: folder)
        case .smart: .ifReadable(currentFolder: nil)
        case .collectionItem: .never
        }
    }

    /// 出どころに固有の行(追加日・最後に読んだ日・コレクション)。
    private var extraRows: [HomeInspectorInfoRow] {
        switch book {
        case .fileBrowser:
            return []
        case .smart(let smartBook):
            var rows: [HomeInspectorInfoRow] = []
            if let added = smartBook.dateAdded {
                rows.append(.init(label: "Date Added", value: HomeInspectorFormat.date(added, locale: locale)))
            }
            if let lastRead = smartBook.lastRead {
                rows.append(.init(label: "Last Read", value: HomeInspectorFormat.date(lastRead, locale: locale)))
            }
            return rows
        case .collectionItem:
            guard let item = collectionItem else { return [] }
            var rows: [HomeInspectorInfoRow] = []
            if let collection = item.collection {
                rows.append(.init(label: "Collection", value: collection.name))
            }
            rows.append(.init(label: "Date Added", value: HomeInspectorFormat.date(item.addedAt, locale: locale)))
            return rows
        }
    }

    /// コレクションの本の場所と情報を読む。ブックマークは裏の解決(繋がっていない共有へ繋ぎに行かない。BookmarkResolution)で、
    /// 読むのは FileIO の上(応答しない共有で固まらない)。**読むのはブックマークのスコープを開けている間**(許可したフォルダの外の本は
    /// そのブックマークでしか読めない ―― スコープを閉じてから確かめると、開ける本を「見つかりません」と出す)。フォルダの本の大きさも
    /// 同じスコープの中で数える(ネットワーク越し・保護下の場所では数えない)。解けなければ記録したパスを読み、それも無ければ
    /// 「見つかりません」。ゴミ箱の中まで追ったものは見つからない扱い(`CollectionStore.existingURL` と同じ)。
    private func loadCollectionItemFacts() async {
        guard case .collectionItem = book, let item = collectionItem else { return }
        let bookmark = item.bookmarkData
        let recordedPath = item.bookID
        let outcome = try? await FileIO.withDeadline(.seconds(30)) {
            await FileIO.perform { Self.readCollectionItem(bookmark: bookmark, recordedPath: recordedPath) }
        }
        guard !Task.isCancelled else { return }
        // 期限切れ(応答しない共有)は「見つからない」と言い切らない(読めなかった理由が分からない)ので、情報の節を出さない。
        guard let outcome else { return }
        if let url = outcome.resolvedURL {
            resolvedURL = url
            urlBox.url = url
        }
        if let entry = outcome.entry {
            var facts = HomeInspectorFileFacts(entry: entry)
            if facts.size == nil { facts.size = outcome.folderSize }
            loadedFacts = facts
        } else {
            var missing = HomeInspectorFileFacts(
                url: URL(fileURLWithPath: recordedPath), isFolder: false, kind: nil, size: nil, created: nil, modified: nil
            )
            missing.isMissing = true
            loadedFacts = missing
        }
    }

    /// スマートライブラリの本の情報を、選んだ 1 冊だけ読み直す(2026-10-04 の監査 SL-8)。
    ///
    /// 一覧はアプリの外の変化では探し直さない(SmartLibraryCatalog の型コメントの仕様)ので、写しのままだと、消えた本・書き換わった本
    /// でも探したときの大きさ・日付を出し続けた。読むのは FileIO の上で、期限つき。**ネットワーク越しの本は読まない**(写しのまま。
    /// 選ぶたびに共有へ往復しない)。「無い」と言うのは OS が無いと答えたときと、ボリュームが繋がっていないときだけ
    /// (`LastBookPresence` と同じ分け方 ―― 読めなかったことを「見つかりません」に読み替えない)。
    private func loadSmartBookFacts() async {
        guard case .smart(let smartBook) = book else { return }
        let url = URL(fileURLWithPath: smartBook.id, isDirectory: smartBook.kind == .folder)
        let mounts = MountTable.current()
        guard !mounts.isRemote(url) else { return }
        let reading = try? await FileIO.withDeadline(.seconds(10)) {
            await FileIO.perform { Self.readSmartBook(url, mounts: mounts) }
        }
        guard !Task.isCancelled, let reading else { return }
        switch reading {
        case .present(let entry):
            loadedFacts = HomeInspectorFileFacts(entry: entry)
        case .absent:
            var missing = HomeInspectorFileFacts(smartBook: smartBook)
            missing.isMissing = true
            loadedFacts = missing
        case .unknown:
            break
        }
    }

    nonisolated private enum SmartBookReading: Sendable {
        case present(FileBrowserEntry)
        case absent
        case unknown
    }

    /// **ブロッキングする**(FileIO の上で)。
    nonisolated private static func readSmartBook(_ url: URL, mounts: MountTable) -> SmartBookReading {
        if mounts.isOnAnUnmountedVolume(url) { return .absent }
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .absent
            default: return .unknown
            }
        }
        var kindCache: [String: String] = [:]
        return .present(FileBrowserListing.makeEntry(url, kindCache: &kindCache))
    }

    nonisolated private struct CollectionItemReading: Sendable {
        var resolvedURL: URL?
        var entry: FileBrowserEntry?
        var folderSize: Int64?
    }

    /// **ブロッキングする**(FileIO の上で)。
    nonisolated private static func readCollectionItem(bookmark: Data, recordedPath: String) -> CollectionItemReading {
        var reading = CollectionItemReading()
        var url = URL(fileURLWithPath: recordedPath)
        var scoped: URL?
        if let resolved = BookmarkResolution.resolve(bookmark, purpose: .background), !BookLocationResolver.isInTrash(resolved) {
            url = resolved
            if resolved.startAccessingSecurityScopedResource() { scoped = resolved }
        }
        defer { scoped?.stopAccessingSecurityScopedResource() }
        guard FileManager.default.fileExists(atPath: url.path) else { return reading }
        reading.resolvedURL = url
        var kindCache: [String: String] = [:]
        let entry = FileBrowserListing.makeEntry(url, kindCache: &kindCache)
        reading.entry = entry
        if entry.isNavigableFolder, entry.fileSize == nil,
           DirectoryProbe.mayReadUnentered(url, from: nil, mountTable: .current()),
           case .measured(let bytes, false) = HomeInspectorFolderSize.sum(url) {
            reading.folderSize = bytes
        }
        return reading
    }
}

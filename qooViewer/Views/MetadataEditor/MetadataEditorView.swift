import AppKit
import QooMetaKit
import SwiftData
import SwiftUI

/// 「メタデータの編集」ウインドウ(編集メニューから開く独立ウインドウ)。
///
/// 2026-09-21 に qooMeta のメインウインドウ 3 ページ目(確認・編集)を土台に作り直した
/// (docs/plans/qoometa-smart-library-plan.md)。一覧は AppKit の NSTableView(`MetadataBookTable`)、上に絞り込みの帯。
/// qooMeta の 2 ページ目(解析方法の選択)は持たず、ルールセットは本ごとに自動で選ぶ。代わりに、ファイル名フォーマットと
/// 合致しなかった本の絞り込み(帯。合致しなかった本は一覧の上にまとめる)・右クリックからの読み直し・解析の設定を開くボタンを持つ。
///
/// **右の詳細は持たない**(利用者の指示 2026-09-21)。まとめて直す操作(連番・シリーズ・欄・ロック・メタデータの削除・
/// 除外フォルダ)はすべて右クリックから、表紙は一覧の列(以前の窓と同じ)から。
///
/// **ロック = 登録**(利用者の決定 2026-09-21、案 A)。直した値は青く出る下書きで、鍵を掛けると登録される(MetadataWorkspace)。
///
/// 一覧に並べる本(= メタデータを自動で作る対象)は、**開いた本・ライブラリの本**(このアプリが保存データを持っている本。
/// `KnownBooks`、以前の窓と同じ)と、**スマートライブラリの対象フォルダの中の本**(`SmartLibraryCatalog.folderBookIDs()`)。
/// ファイルブラウザの「よく使う項目」のフォルダの中の本は、開くまで対象にしない(2026-09-22、利用者の指示)。
///
/// 中身(`MetadataWorkspace`)は窓を開くたびに作り、閉じたら捨てる(閉じている間に DB が変わっても、次に開いたときは
/// DB から読み直すだけで済む)。
struct MetadataEditorWindow: View {
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var folderAccess: FolderAccessStore
    @EnvironmentObject private var smartLibraryCatalog: SmartLibraryCatalog
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(MetadataRulesStore.self) private var rulesStore
    @Environment(\.modelContext) private var modelContext

    @State private var model: MetadataEditorModel?

    var body: some View {
        Group {
            if let model, let workspace = model.workspace {
                MetadataEditorContent(model: model, workspace: workspace, rulesStore: rulesStore)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 480)
        .task { [metadataStore, bookmarkStore, layoutStore, favoritesStore, collectionStore, folderAccess, smartLibraryCatalog] in
            let model = MetadataEditorModel(
                metadataStore: metadataStore, rulesStore: rulesStore,
                stores: .init(favoritesStore: favoritesStore, collectionStore: collectionStore, bookmarkStore: bookmarkStore,
                              layoutStore: layoutStore, metadataStore: metadataStore, folderAccess: folderAccess,
                              smartLibraryCatalog: smartLibraryCatalog, modelContext: modelContext),
                preferences: preferences,
                resolveURL: { [weak metadataStore, weak bookmarkStore, weak layoutStore, weak collectionStore] bookID in
                    bookmarkStore?.resolvedURLFromBookmarkData(forBookID: bookID)
                        ?? layoutStore?.resolvedURL(forBookID: bookID)
                        ?? metadataStore?.resolvedURL(forBookID: bookID)
                        ?? collectionStore?.anyBookmarkData(forBookID: bookID)
                            .flatMap { FavoritesStore.resolvedURL(fromBookmark: $0) }
                })
            self.model = model
            await model.open()
        }
        .onDisappear {
            model?.close()
            model = nil
        }
    }
}

/// 窓の持ちもの: 中身(`MetadataWorkspace`)と、それを DB・規則・ほかの窓へつなぐ所。
@MainActor @Observable
final class MetadataEditorModel {
    /// 本の保存データに触るストア一式(一覧の母体・実体の確かめ・保存データの削除)。
    struct Stores {
        let favoritesStore: FavoritesStore
        let collectionStore: CollectionStore
        let bookmarkStore: BookmarkStore
        let layoutStore: LayoutStore
        let metadataStore: BookMetadataStore
        let folderAccess: FolderAccessStore
        /// スマートライブラリの対象フォルダの中の本(一覧の母体に足す)。
        let smartLibraryCatalog: SmartLibraryCatalog
        let modelContext: ModelContext
    }

    private(set) var workspace: MetadataWorkspace?
    /// 以前の版の欄(4 つだけ)で登録した本のうち、この一覧にあるもの。開いたときに、空の欄を埋めるか・解析し直すかを尋ねる。
    var outdatedBookIDs: Set<String> = []
    let metadataStore: BookMetadataStore
    let rulesStore: MetadataRulesStore
    private let stores: Stores
    /// コレクションの表紙の指定(改善要望5 §5.4。一覧の「コレクションの表紙」の列)。
    let coverController: CoverOverrideController
    /// 直したがロック(登録)していない値(窓を閉じても残す)。
    private let drafts: MetadataDraftStore
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var existenceTask: Task<Void, Never>?
    /// スマートライブラリの対象フォルダの本も一覧に入れるか(開くたびに読む)。
    @ObservationIgnored private let includesSmartLibraryFolders: () -> Bool

    init(metadataStore: BookMetadataStore, rulesStore: MetadataRulesStore, stores: Stores,
         preferences: AppPreferences, drafts: MetadataDraftStore? = nil,
         resolveURL: @escaping (String) -> URL?) {
        self.drafts = drafts ?? MetadataDraftStore()
        self.metadataStore = metadataStore
        self.rulesStore = rulesStore
        self.stores = stores
        includesSmartLibraryFolders = { [weak preferences] in preferences?.smartLibraryFeatureEnabled ?? true }
        coverController = CoverOverrideController(target: .collectionCover, layoutStore: stores.layoutStore,
                                                  preferences: preferences, resolveURL: resolveURL)
    }

    /// 対象の本を集め、qooMeta で読む。
    func open() async {
        // 対象外のフォルダの本は並べない(MetadataRulesStore.excludedFolders。登録済みのメタデータは消さない)。
        var known = KnownBooks.collect(from: KnownBooks.Sources(
            metadataStore: stores.metadataStore, bookmarkStore: stores.bookmarkStore, layoutStore: stores.layoutStore,
            favoritesStore: stores.favoritesStore, collectionStore: stores.collectionStore, modelContext: stores.modelContext))
        // スマートライブラリが OFF の間は、その対象フォルダを探しに行かない(AppPreferences.smartLibraryFeatureEnabled)。
        if includesSmartLibraryFolders() {
            known.formUnion(await stores.smartLibraryCatalog.folderBookIDs())
        }
        let bookIDs = known.filter { !rulesStore.isExcluded(bookID: $0) }
        drafts.keepOnly(Set(bookIDs))
        let entries = bookIDs.map { bookID in
            MetadataWorkspace.Entry(bookID: bookID, registeredValues: metadataStore.metadata(forBookID: bookID)?.values,
                                    draft: drafts.drafts[bookID])
        }
        let workspace = await MetadataWorkspace.open(entries, rules: rulesStore.rules)
        workspace.writeBack = { [weak metadataStore] entries in metadataStore?.upsertAll(entries) }
        workspace.draftsChanged = { [drafts] changes in
            for (id, draft) in changes { drafts.set(draft, for: id) }
            drafts.save()
        }
        // 規則の窓(解析の設定・抽出の設定)に、この一覧の名前を渡す(規則を直しながら、この一覧の名前で読めぐあいを見る)。
        MetadataRulesPicked.shared.set(workspace.books.map(\.fileName))
        self.workspace = workspace
        outdatedBookIDs = metadataStore.outdatedFieldBookIDs.intersection(workspace.bookIDs)
        observeStoreChanges(of: workspace)
        checkExistence(of: workspace)
    }

    /// 以前の版の欄で登録した本の、空の欄だけをファイル名から埋める(登録した値はそのまま。ロックも掛けたまま)。
    func fillMissingFieldsOfOutdatedBooks() {
        let rules = rulesStore.rules
        metadataStore.fillMissingFields(of: outdatedBookIDs) { bookID in
            BookMetadataValues(MetadataRulesStore.reading(forBookID: bookID, rules: rules).metadata)
        }
        outdatedBookIDs = []
    }

    /// 以前の版の欄で登録した本のロックを外し、ファイル名から解析・抽出し直す(登録した値は捨てる。鍵を掛け直して登録する)。
    func reparseOutdatedBooks() {
        guard let workspace else { return }
        let ids = outdatedBookIDs
        outdatedBookIDs = []
        workspace.setLocked(ids, false)
        workspace.reparseFromFileNames(ids)
    }

    /// 本の実体があるかを、画面の外で確かめる(「本ごとの保存データを削除」ウインドウと同じ判定。BookExistenceProbe)。
    /// **確かめられなかった本(アクセス権が無い・ボリュームが繋がっていない)は「無い」にしない** ―― 灰色で出して
    /// 削除を促すのは、確かに無いと分かった本だけ。
    private func checkExistence(of workspace: MetadataWorkspace) {
        let probes = workspace.bookIDs.map { bookID in
            BookExistenceProbe.make(
                bookID: bookID, metadataStore: stores.metadataStore, layoutStore: stores.layoutStore,
                bookmarkStore: stores.bookmarkStore, favoritesStore: stores.favoritesStore,
                collectionStore: stores.collectionStore, folderAccess: stores.folderAccess)
        }
        existenceTask?.cancel()
        existenceTask = Task { [weak workspace] in
            let missing = await Task.detached(priority: .utility) {
                Set(probes.filter { $0.evaluate() == .missing }.map(\.bookID))
            }.value
            guard !Task.isCancelled else { return }
            workspace?.setMissing(missing)
        }
    }

    /// この窓の外で DB が変わったら(1 冊ぶんのシート・保存データの読み込み・ビューアの取り込み)、その本を合わせる。
    /// **この窓が書いた知らせは読まない**(`isWritingBack`)。
    private func observeStoreChanges(of workspace: MetadataWorkspace) {
        let observer = NotificationCenter.default.addObserver(
            forName: .bookMetadataDidChange, object: metadataStore, queue: .main
        ) { [weak self, weak workspace] notification in
            MainActor.assumeIsolated {
                guard let self, let workspace, !workspace.isWritingBack else { return }
                let ids: [String]
                if let bookID = notification.userInfo?["bookID"] as? String {
                    ids = workspace.contains(bookID) ? [bookID] : []
                } else {
                    ids = workspace.bookIDs
                }
                var changes: [String: BookMetadataValues?] = [:]
                for id in ids { changes[id] = .some(self.metadataStore.metadata(forBookID: id)?.values) }
                workspace.applyExternalChanges(changes)
            }
        }
        observers.append(observer)
    }

    /// 対象外のフォルダが変わったら、一覧を作り直す(対象に戻った本を並べ直すため。取り消しの歩みは捨てる)。
    func reopen() async {
        close()
        await open()
    }

    /// 規則が変わったら読み直す(規則の窓で直したとき)。
    func rulesChanged() async {
        await workspace?.setRules(rulesStore.rules)
    }

    func close() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        existenceTask?.cancel()
        if MetadataEditorUndoRouter.shared.workspace === workspace { MetadataEditorUndoRouter.shared.workspace = nil }
        workspace = nil
    }
}

/// 編集メニューの「取り消す」「やり直す」を、メタデータの編集ウインドウが前にあるときはこの窓の操作へ流すための仲立ち。
/// 窓がキーになったときに自分の中身を入れ、キーでなくなったら外す(QooViewerApp の undoRedo の置き換え)。
@MainActor @Observable
final class MetadataEditorUndoRouter {
    static let shared = MetadataEditorUndoRouter()
    weak var workspace: MetadataWorkspace?
}

/// 窓の中身。
struct MetadataEditorContent: View {
    let model: MetadataEditorModel
    @Bindable var workspace: MetadataWorkspace
    @Bindable var rulesStore: MetadataRulesStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var showsExcludedFolders = false
    @State private var confirmsReparseAll = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MetadataFilterBar(workspace: workspace)
                Divider()
                MetadataBookTableView(model: model, workspace: workspace, rulesStore: rulesStore,
                                      openParsingSettings: openParsingSettings)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ListWindowStatusBar {
                    Text(verbatim: "%1$lld / %2$lld books".ui(workspace.visibleCount, workspace.books.count))
                    if workspace.selection.count > 0 {
                        ListWindowStatusSeparator()
                        Text(verbatim: "%lld selected".ui(workspace.selection.count))
                    }
                }
            }
            .searchable(text: $workspace.searchText, placement: .toolbar, prompt: Text("Search fields and file names"))
            .toolbar {
                if workspace.isWorking {
                    ToolbarItem { ProgressView().controlSize(.small) }
                }
                // 並びは利用者の指示(2026-09-21): すべて選択・メタデータを再生成・ロック・解析の設定・抽出の設定・対象外のフォルダ。
                ToolbarItem {
                    Button { workspace.toggleSelectAll() } label: {
                        Label(workspace.isEveryVisibleBookSelected ? "Deselect All" : "Select All",
                              systemImage: "checkmark.rectangle.stack")
                    }
                    // ほかのボタンと同じく文字も出す(絵だけでは何のボタンか分からない)。
                    .labelStyle(.titleAndIcon)
                    .disabled(workspace.visibleCount == 0)
                    .help("Select All / Deselect All")
                }
                ToolbarItem {
                    Button { confirmsReparseAll = true } label: {
                        Label("Regenerate Metadata", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(workspace.regenerationTargets.isEmpty)
                    .help("Parses and extracts the selected unlocked books again from their file names, throwing away the values edited but not locked")
                }
                ToolbarItem {
                    // 選んだ本のロック(= 登録)。全部ロック済みなら外す、そうでなければ掛ける(右クリックと同じ)。
                    let selected = workspace.selectedBooks
                    let allLocked = !selected.isEmpty && selected.allSatisfy(\.isRegistered)
                    Button { workspace.setLocked(Set(selected.map(\.id)), !allLocked) } label: {
                        Label(allLocked ? "Unlock" : "Lock", systemImage: allLocked ? "lock.open" : "lock")
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(selected.isEmpty)
                    .help("Locks the selected books and registers their metadata, or unlocks them")
                }
                ToolbarItem {
                    Button { openParsingSettings() } label: {
                        Label("Parsing Settings", systemImage: "doc.text.magnifyingglass")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Look at and correct the rule sets that read file names: the formats, the author separators and the words that choose a rule set")
                }
                ToolbarItem {
                    Button { openWindow(id: SeriesRulesView.windowID) } label: {
                        Label("Extraction Settings", systemImage: "list.bullet.indent")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Look at and correct the rules that derive the series and volume: policies, word rules and word lists")
                }
                ToolbarItem {
                    Button { showsExcludedFolders = true } label: {
                        Label("Excluded Folders", systemImage: "folder.badge.minus")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Folders whose books (including those in their subfolders) are left out of metadata registration")
                }
            }
            .hardTopScrollEdgeEffect()
        }
        // 以前の版の欄(著者・タイトル・シリーズ・巻数だけ)で登録した本がある(利用者の指示 2026-09-21: 増えた欄を埋め直す)。
        .alert("Some metadata was registered before the new fields existed",
               isPresented: Binding(get: { !model.outdatedBookIDs.isEmpty }, set: { if !$0 { model.outdatedBookIDs = [] } })) {
            Button("Fill Only the Empty Fields") { model.fillMissingFieldsOfOutdatedBooks() }
            Button("Unlock and Parse Again", role: .destructive) { model.reparseOutdatedBooks() }
            Button("Later", role: .cancel) { model.outdatedBookIDs = [] }
        } message: {
            Text(verbatim: "%lld books were registered with only the author, title, series and volume, so their genre, event, source work and info are empty. Fill only the empty fields from the file names (the registered values stay locked), or unlock them and parse and extract them again from the file names (the registered values are thrown away; lock them again to register).".ui(model.outdatedBookIDs.count))
        }
        .alert("Regenerate the metadata?", isPresented: $confirmsReparseAll) {
            Button("Cancel", role: .cancel) {}
            Button("Regenerate", role: .destructive) { workspace.reparseFromFileNames(workspace.regenerationTargets) }
        } message: {
            Text(verbatim: "%lld unlocked books are parsed and extracted again from their file names, and the values edited but not locked are thrown away. Locked books are left alone. You can undo this with Undo.".ui(workspace.regenerationTargets.count))
        }
        .sheet(isPresented: $showsExcludedFolders) {
            MetadataExcludedFoldersSheet(rulesStore: rulesStore)
        }
        // 対象外のフォルダが変わったら一覧を作り直す。
        .onChange(of: rulesStore.excludedFolders) {
            Task { await model.reopen() }
        }
        // 規則の窓で変えた内容を一覧へ届ける(打っている途中の変更をまとめるため、少し待つ)。
        .task(id: rulesStore.rules.contentHash) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await model.rulesChanged()
        }
        .onChange(of: controlActiveState, initial: true) { _, state in
            let router = MetadataEditorUndoRouter.shared
            if state == .key {
                router.workspace = workspace
            } else if router.workspace === workspace {
                router.workspace = nil
            }
        }
        .alert(isPresented: Binding(get: { rulesStore.storageIssueText != nil },
                                    set: { if !$0 { rulesStore.dismissStorageIssue() } })) {
            Alert(title: Text(verbatim: rulesStore.storageIssueText ?? ""))
        }
    }

    /// 解析の設定の窓を、選んでいる本のルールセットを選んだ状態で開く。
    private func openParsingSettings() {
        let picked = workspace.selectedBooks.first.map { workspace.presetName(for: $0.id) }
        MetadataRulesPicked.shared.open(ruleSet: picked ?? workspace.formats.defaultName)
        openWindow(id: FileNameRulesView.windowID)
    }
}

// MARK: - 絞り込み

/// 一覧の上の絞り込み: ジャンル → 著者(ジャンルで候補が絞られる。値ごとの冊数と「(空)」つき)と、本の状態。
/// **いつも見えている**ので、一覧のどこを見ているかが分かる。qooViewer では、ファイル名フォーマットと合致しなかった本が
/// いくつあるかを帯に出し、押せばそれだけを出す(qooMeta の 2 ページ目で見ていた読めぐあいの代わり)。
struct MetadataFilterBar: View {
    @Bindable var workspace: MetadataWorkspace

    private var isFiltering: Bool {
        workspace.genreFilter != nil || workspace.authorFilter != nil || workspace.stateFilter != .all
    }

    var body: some View {
        HStack(spacing: 16) {
            MetadataValueFilterMenu(title: "Genre", values: workspace.genreValues, selection: workspace.genreFilter) {
                workspace.setGenreFilter($0)
            }
            MetadataValueFilterMenu(title: "Authors", values: workspace.authorValues, selection: workspace.authorFilter) {
                workspace.authorFilter = $0
            }
            Picker("Show", selection: $workspace.stateFilter) {
                ForEach(MetadataWorkspace.StateFilter.allCases) { Text(verbatim: $0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            if isFiltering {
                Button("Clear the filters") {
                    workspace.setGenreFilter(nil)
                    workspace.authorFilter = nil
                    workspace.stateFilter = .all
                }
                .buttonStyle(.link)
            }
            Spacer()
            let unmatched = workspace.unmatchedCount
            if unmatched > 0, workspace.stateFilter != .unmatched {
                Button {
                    workspace.stateFilter = .unmatched
                } label: {
                    Label("%lld books matched no file name format".ui(unmatched), systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(.link)
                .foregroundStyle(.orange)
                .help("Shows only the books whose file names matched no file name format of their rule set. Right-click them to parse them again with another rule set")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// 値で絞り込むメニュー(ジャンル・著者)。中身は**押して開いたときに作る**。
struct MetadataValueFilterMenu: View {
    /// 見出しの鍵(英語)。
    var title: String
    var values: [(key: MetadataValueKey, count: Int)]
    var selection: MetadataValueKey?
    var pick: (MetadataValueKey?) -> Void

    var body: some View {
        Menu {
            Button("All") { pick(nil) }
            Divider()
            ForEach(values, id: \.key) { row in
                Button { pick(row.key) } label: {
                    Text(verbatim: "\(row.key.label) (\(row.count))")
                }
            }
        } label: {
            // Menu の label は Text 1 つだけにする(macOS 26 SDK の古い経路では先頭の Text だけが題になる。CLAUDE.md)。
            Text(verbatim: "\(title.ui): \(selection?.label ?? "All".ui)")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
    }
}

// MARK: - 一覧

/// 右クリックから開くシート。
enum MetadataEditorSheet: Identifiable {
    /// 選んだ本を 1 つのシリーズにする(名前を入れる)。
    case series(Set<String>)
    /// 選んだ本に一覧の順で巻を振る。
    case numbering([String])
    /// 選んだ本の欄をまとめて同じ値にする。
    case field(QMBookMetadata.Field, Set<String>)

    var id: String {
        switch self {
        case .series(let ids): "series-\(ids.sorted().joined())"
        case .numbering(let ids): "numbering-\(ids.joined())"
        case .field(let field, let ids): "field-\(field.rawValue)-\(ids.sorted().joined())"
        }
    }
}

/// 1 冊 1 行の一覧。ファイル名のほかの欄は、セルを 2 回押せばその場で直せる(qooMeta と同じ)。
struct MetadataBookTableView: View {
    let model: MetadataEditorModel
    @Bindable var workspace: MetadataWorkspace
    @Bindable var rulesStore: MetadataRulesStore
    var openParsingSettings: () -> Void

    @EnvironmentObject private var preferences: AppPreferences
    @State private var pendingSeries: PendingSeries?
    @State private var sheet: MetadataEditorSheet?
    @State private var deletingMetadata: Set<String>?

    struct PendingSeries: Identifiable {
        let ids: Set<String>
        let name: String
        let preview: MetadataWorkspace.SeriesChangePreview
        var id: String { name + ids.sorted().joined() }
    }

    nonisolated static let columns: [QMBookMetadata.Field] = [.genre, .authors, .title, .series, .volume]
    nonisolated static let columnsAfterVolume: [QMBookMetadata.Field] = [.source, .event, .info]

    nonisolated static func width(_ field: QMBookMetadata.Field) -> (min: CGFloat, ideal: CGFloat, max: CGFloat?) {
        switch field {
        case .genre: (56, 88, 160)
        case .authors: (80, 160, nil)
        case .title: (120, 240, nil)
        case .series: (100, 180, nil)
        case .volume: (40, 72, 140)
        case .source: (70, 130, 220)
        case .event: (56, 100, 200)
        case .info: (56, 110, 220)
        }
    }

    var body: some View {
        let controller = model.coverController
        MetadataBookTable(books: workspace.books, positions: workspace.visiblePositions, selection: $workspace.selection,
                          sortOrder: $workspace.sortOrder,
                          canEdit: canEdit, isEdited: isEdited, help: help, commit: commit,
                          contextMenu: contextMenu,
                          toggleLock: { [workspace] id in workspace.setLocked([id], !workspace.isLocked(id)) },
                          coverView: { [preferences] id in
                              AnyView(ExportCoverCell(bookID: id, controller: controller, showsCropAnchor: true)
                                  .environmentObject(preferences))
                          })
        .alert(item: $pendingSeries) { pending in
            Alert(title: Text(verbatim: "Make “%@” the series?".ui(pending.name)),
                  message: Text(verbatim: "This also changes %1$lld books you did not pick: %2$lld gain a series and %3$lld lose one."
                      .ui(pending.preview.others, pending.preview.gained, pending.preview.lost)),
                  primaryButton: .default(Text("Apply anyway")) {
                      workspace.setSeries(pending.name, for: pending.ids)
                  },
                  secondaryButton: .cancel())
        }
        .sheet(item: $sheet) { sheet in
            MetadataEditorSheetView(sheet: sheet, workspace: workspace, rulesStore: rulesStore) { name, ids in
                applySeriesName(name, to: ids)
            }
        }
        .alert(
            "Delete the metadata of these books?",
            isPresented: Binding(get: { deletingMetadata != nil }, set: { if !$0 { deletingMetadata = nil } })
        ) {
            Button("Cancel", role: .cancel) { deletingMetadata = nil }
            Button("Delete", role: .destructive) {
                if let deletingMetadata { workspace.unregister(deletingMetadata) }
                deletingMetadata = nil
            }
        } message: {
            Text(verbatim: "The metadata of %lld books, locked or edited, is deleted and they go back to the values read from the file names. This can't be undone.".ui(deletingMetadata?.count ?? 0))
        }
    }

    /// 巻数は、シリーズ名の決まっている本にしか入らない(シリーズの中の番号なので)。ロック(登録)した本は直せない。
    private func canEdit(_ field: QMBookMetadata.Field, _ book: MetadataBookRow) -> Bool {
        guard !book.isRegistered else { return false }
        return field != .volume || !MetadataWorkspace.currentSeriesName(book).isEmpty
    }

    /// 青く出す欄: 直したが、まだロック(登録)していない値(案 A。ロックした本の値はふつうの色)。
    private func isEdited(_ field: QMBookMetadata.Field, _ book: MetadataBookRow) -> Bool {
        guard !book.isRegistered else { return false }
        return field == .series || field == .volume ? book.hasConfirmedSeries : book.edited.contains(field)
    }

    private func help(_ field: QMBookMetadata.Field, _ book: MetadataBookRow) -> String {
        if book.isRegistered { return "This book is locked. Unlock it to edit".ui }
        guard canEdit(field, book) else { return "Give the book a series name first".ui }
        switch field {
        case .series: return "Double-click to settle the series for this book. Empty puts it in no series".ui
        case .volume: return "Double-click to settle the volume for this book. Empty clears it".ui
        case .authors: return "Double-click to edit. Several authors are separated by 、".ui
        default: return "Double-click to edit this book’s value".ui
        }
    }

    private func commit(_ field: QMBookMetadata.Field, _ value: String, for book: MetadataBookRow) {
        let text = value.trimmingCharacters(in: .whitespaces)
        switch field {
        case .series:
            guard !text.isEmpty else { return workspace.removeFromSeries([book.id]) }
            applySeriesName(text, to: [book.id])
        case .volume:
            if text.isEmpty { workspace.clearVolumes([book.id]) } else { workspace.setVolumes(text, for: [book.id]) }
        case .authors:
            workspace.set(field, to: text.split(whereSeparator: { "、,，".contains($0) }).map(String.init), for: [book.id])
        default:
            workspace.set(field, to: [text], for: [book.id])
        }
    }

    /// シリーズ名を入れる。**選んでいない本が巻き込まれるときだけ**、入れる前に数を見せて確かめる
    /// (確定した名前は錨なので、同じ単位のほかの本もそのシリーズへ寄る)。
    private func applySeriesName(_ name: String, to ids: Set<String>) {
        Task {
            let preview = await workspace.previewSetSeries(name, for: ids)
            if preview.others > 0 {
                pendingSeries = PendingSeries(ids: ids, name: name, preview: preview)
            } else {
                workspace.setSeries(name, for: ids)
            }
        }
    }

    // MARK: 右クリック

    /// 右クリックのメニュー。1 冊だけでも複数でも同じ並び(その場で意味の無い項目は淡色)。
    private func contextMenu(_ ids: Set<String>) -> [MetadataBookTable.MenuItem] {
        typealias Item = MetadataBookTable.MenuItem
        let books = ids.compactMap { workspace.row($0) }
        let editable = Set(books.filter { !$0.isRegistered }.map(\.id))
        let lockedIDs = Set(books.filter(\.isRegistered).map(\.id))
        let deletable = Set(books.filter { $0.isRegistered || $0.hasUnregisteredEdits }.map(\.id))

        let hasEditable = !editable.isEmpty
        // 一覧の順(連番はこの順に振る)。
        let orderedEditable = workspace.rows.map(\.id).filter { editable.contains($0) }

        var items: [Item] = []
        // ロック
        if !lockedIDs.isEmpty && lockedIDs.count == ids.count {
            items.append(Item(title: "Unlock".ui) { workspace.setLocked(ids, false) })
        } else {
            items.append(Item(title: "Lock".ui) { workspace.setLocked(ids, true) })
            if !lockedIDs.isEmpty {
                items.append(Item(title: "Unlock".ui) { workspace.setLocked(lockedIDs, false) })
            }
        }
        items.append(.separator)
        // シリーズと巻
        items.append(Item(title: "Make Into One Series…".ui, isEnabled: hasEditable) { sheet = .series(editable) })
        items.append(Item(title: "Number the Volumes…".ui, isEnabled: orderedEditable.count > 1) {
            sheet = .numbering(orderedEditable)
        })
        items.append(Item(title: "Remove From Series".ui, isEnabled: hasEditable) { workspace.removeFromSeries(editable) })
        items.append(Item(title: "Clear Volume Number".ui, isEnabled: hasEditable) { workspace.clearVolumes(editable) })
        items.append(Item(title: "Revert Series to Proposal".ui, isEnabled: hasEditable) {
            workspace.revertSeries(editable)
        })
        items.append(.separator)
        // 欄
        let fields: [QMBookMetadata.Field] = [.title, .authors, .genre, .event, .source, .info]
        items.append(Item(title: "Change a Field".ui, isEnabled: hasEditable, children: fields.map { field in
            Item(title: field.labelKey.ui + "…") { sheet = .field(field, editable) }
        }))
        items.append(.separator)
        // 読み直す
        // 名前はツールバーのボタンと揃える(利用者の指示 2026-09-21)。
        items.append(Item(title: "Regenerate Metadata".ui, isEnabled: hasEditable) {
            workspace.reparseFromFileNames(editable)
        })
        // ファイル名の解析ルール: 使うルールセットを切り替えるだけ(読み直しは「メタデータを再生成」。利用者の指示 2026-09-21)。
        let overridden = Set(ids.filter { workspace.hasPresetOverride($0) })
        var ruleSetItems: [Item] = [
            Item(title: "Automatic".ui,
                 state: overridden.isEmpty ? .on : (overridden.count == ids.count ? .off : .mixed)) {
                workspace.setRuleSet(editable, to: nil)
            },
            .separator,
        ]
        ruleSetItems += workspace.rules.presetCatalog.entries.map { entry in
            let chosen = Set(overridden.filter { workspace.presetName(for: $0) == entry.id })
            return Item(title: entry.preset.displayName,
                        state: chosen.isEmpty ? .off : (chosen.count == ids.count ? .on : .mixed)) {
                workspace.setRuleSet(editable, to: entry.id)
            }
        }
        items.append(Item(title: "File Name Parsing Rules".ui, isEnabled: hasEditable, children: ruleSetItems))
        items.append(.separator)
        // 実体の有無にかかわらず削除できる(利用者の指示 2026-09-21)。
        items.append(Item(title: "Delete Metadata…".ui, isEnabled: !deletable.isEmpty) {
            deletingMetadata = deletable
        })
        // 本のあるフォルダを、メタデータの登録の対象外にする。
        let folders = Set(ids.map { ($0 as NSString).deletingLastPathComponent })
        items.append(Item(title: folders.count == 1 ? "Exclude This Folder from Metadata".ui
                                                    : "Exclude These Folders from Metadata".ui) { [rulesStore] in
            for folder in folders.sorted() { rulesStore.addExcludedFolder(URL(fileURLWithPath: folder, isDirectory: true)) }
        })
        items.append(.separator)
        items.append(Item(title: "Copy File Name".ui) {
            let names = ids.sorted().map { URL(fileURLWithPath: $0).lastPathComponent }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
        })
        return items
    }
}

// MARK: - 右クリックから開くシート

/// 右クリックから開く小さなシート(シリーズ名・連番・欄の値)。シートの中身は macOS が不透明に描く。
struct MetadataEditorSheetView: View {
    let sheet: MetadataEditorSheet
    @Bindable var workspace: MetadataWorkspace
    @Bindable var rulesStore: MetadataRulesStore
    /// シリーズ名を入れる(巻き込みの確かめは呼び出し側)。
    let applySeries: (String, Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var text = ""
    @State private var start = 1
    @State private var width = 2

    var body: some View {
        let buttonWidth = MetadataButtonWidthEstimator.equalWidth(
            for: [String(localized: "Cancel", language: locale), String(localized: "OK", language: locale)],
            minWidth: 60, chrome: 0
        )
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: title).font(.headline)
            content
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button(role: .cancel) { dismiss() } label: { Text("Cancel").frame(width: buttonWidth) }
                    .keyboardShortcut(.cancelAction)
                Button { apply(); dismiss() } label: { Text("OK").frame(width: buttonWidth) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: prepare)
    }

    private var title: String {
        switch sheet {
        case .series(let ids): "Make %lld Books One Series".ui(ids.count)
        case .numbering(let ids): "Number %lld Books".ui(ids.count)
        case .field(let field, let ids): "Change %1$@ of %2$lld Books".ui(field.labelKey.ui, ids.count)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch sheet {
        case .series(let ids):
            TextField("Series name", text: $text, prompt: Text(verbatim: workspace.suggestedSeriesName(for: ids) ?? ""))
                .textFieldStyle(.roundedBorder)
            Text("Leave it empty to use the suggested name.").font(.caption).foregroundStyle(.secondary)
        case .numbering:
            Stepper(value: $start, in: 0...9999) { Text(verbatim: "Start at %lld".ui(start)) }
            Stepper(value: $width, in: 0...4) { Text(verbatim: "Digits %lld".ui(width)) }
            Text("Numbers the books in the order the list shows them. Books with no series name are left alone.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .field(let field, _):
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
            if field == .authors {
                Text("Separate several authors with 、").font(.caption).foregroundStyle(.secondary)
            }
            Text("Every book you picked gets this value. Empty clears the field.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var canApply: Bool {
        switch sheet {
        case .series(let ids): !text.trimmingCharacters(in: .whitespaces).isEmpty || workspace.suggestedSeriesName(for: ids) != nil
        default: true
        }
    }

    /// 欄の値の初期値は、選んだ本で揃っていればその値。
    private func prepare() {
        guard case .field(let field, let ids) = sheet else { return }
        let values = Set(ids.compactMap { workspace.row($0)?.metadata.values(field) })
        if values.count == 1, let value = values.first { text = value.joined(separator: "、") }
    }

    private func apply() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch sheet {
        case .series(let ids):
            let name = trimmed.isEmpty ? (workspace.suggestedSeriesName(for: ids) ?? "") : trimmed
            if !name.isEmpty { applySeries(name, ids) }
        case .numbering(let ids):
            workspace.numberSequentially(ids, start: start, width: width)
        case .field(let field, let ids):
            let values = field == .authors
                ? trimmed.split(whereSeparator: { "、,，".contains($0) }).map(String.init) : [trimmed]
            workspace.set(field, to: values, for: ids)
        }
    }
}

// MARK: - 対象外のフォルダ

/// メタデータの登録の対象外にするフォルダの一覧(ツールバーの「対象外のフォルダ」)。その中とサブフォルダの本は、この窓に並ばず、
/// 1 冊ぶんのシートで登録できず、本を開いたときの EPUB/PDF/ComicInfo からの取り込みもしない。既に登録してあるメタデータは消さない。
struct MetadataExcludedFoldersSheet: View {
    @Bindable var rulesStore: MetadataRulesStore
    @EnvironmentObject private var metadataStore: BookMetadataStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var selection: String?
    /// 削除を確かめているメタデータの本(対象外のフォルダの中に登録してあるもの。2026-09-21、利用者の指示)。
    @State private var deleting: [String]?

    /// 対象外のフォルダ(選んでいればそのフォルダだけ)の中に登録してあるメタデータの本。
    private var registeredInExcluded: [String] {
        let folders = selection.map { [$0] } ?? rulesStore.excludedFolders
        return metadataStore.knownBookIDs.filter { MetadataRulesStore.isExcluded(bookID: $0, in: folders) }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Excluded Folders").font(.headline)
            Text("Books in these folders and in their subfolders are left out of metadata registration. Metadata already registered for them is kept.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach(rulesStore.excludedFolders, id: \.self) { path in
                    Label {
                        Text(verbatim: path).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .tag(path)
                }
            }
            .frame(minHeight: 160)
            .overlay {
                if rulesStore.excludedFolders.isEmpty {
                    Text("No excluded folders").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button { addFolders() } label: { Image(systemName: "plus") }
                    .help("Add Folder…")
                Button {
                    if let selection { rulesStore.removeExcludedFolder(selection) }
                    selection = nil
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                .help("Remove This Folder")
                Spacer()
                let registered = registeredInExcluded
                Button(selection == nil ? "Delete Metadata in Excluded Folders…" : "Delete Metadata in This Folder…") {
                    deleting = registered
                }
                .disabled(registered.isEmpty)
                .help("Deletes the metadata already registered for books in the excluded folders")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .alert(
            "Delete the metadata of these books?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let deleting {
                    metadataStore.upsertAll(deleting.map { BookMetadataStore.BatchEntry(bookID: $0, values: nil) })
                }
                deleting = nil
            }
        } message: {
            Text(verbatim: "The registered metadata of %lld books in the excluded folders is deleted. The books themselves are not deleted. This can't be undone.".ui(deleting?.count ?? 0))
        }
    }

    /// フォルダを選ぶ。**読む権限は要らない**(パスで比べるだけ)ので、FolderAccessStore には足さない。
    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add", language: locale)
        panel.message = String(localized: "Choose folders whose books are left out of metadata registration.", language: locale)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { rulesStore.addExcludedFolder(url) }
    }
}

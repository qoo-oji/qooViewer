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
/// 一覧に並べる本と値は、メタデータ生成(`MetadataGenerator`。ファイル名からメタデータを作って DB へ書くただ 1 つの役)から
/// 受け取る。並ぶのは、このアプリが知っている本・ライブラリの本・スマートライブラリの対象フォルダの中の本(機能の ON/OFF に
/// 関わらず、最後に記録した一覧。MetadataCorpusStore)。ファイルブラウザの「よく使う項目」のフォルダの中の本は、開くまで対象に
/// しない(2026-09-22、利用者の指示)。
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
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.metadataGenerator) private var metadataGenerator
    @Environment(MetadataRulesStore.self) private var rulesStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.bookRecordRelocator) private var bookRecordRelocator

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
        .task { [metadataStore, bookmarkStore, layoutStore, favoritesStore, collectionStore, folderAccess, metadataGenerator] in
            let model = MetadataEditorModel(
                metadataStore: metadataStore, rulesStore: rulesStore,
                stores: .init(favoritesStore: favoritesStore, collectionStore: collectionStore, bookmarkStore: bookmarkStore,
                              layoutStore: layoutStore, metadataStore: metadataStore, folderAccess: folderAccess,
                              generator: metadataGenerator, modelContext: modelContext),
                preferences: preferences,
                relocator: bookRecordRelocator,
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
            // 開かないまま残った頼みを次に持ち越さない(MetadataEditorReveal)。
            MetadataEditorReveal.shared.take()
        }
    }
}

extension EnvironmentValues {
    /// アプリの外で名前を変えた本の保存データを付け替える役(AppStores.bookRecordRelocator。メタデータの編集ウインドウが使う)。
    @Entry var bookRecordRelocator: BookRecordRelocator?
    /// ファイル名からメタデータを作る役(AppStores.metadataGenerator。メタデータの編集ウインドウが使う)。
    @Entry var metadataGenerator: MetadataGenerator?
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
        /// 並べる本と値の出どころ(メタデータ生成)。
        let generator: MetadataGenerator?
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
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var existenceTask: Task<Void, Never>?
    /// アプリの外で名前を変えた本の保存データの付け替え役(AppStores に 1 つ。`relocateMovedBooks`)。
    @ObservationIgnored private let relocator: BookRecordRelocator?
    /// 付け替えを一度試した本(古いパス)。新しいパスに行があって付け替わらなかった本を、何度も試さない。
    @ObservationIgnored private var relocationAttempted: Set<String> = []

    init(metadataStore: BookMetadataStore, rulesStore: MetadataRulesStore, stores: Stores,
         preferences: AppPreferences, relocator: BookRecordRelocator?, resolveURL: @escaping (String) -> URL?) {
        self.relocator = relocator
        self.metadataStore = metadataStore
        self.rulesStore = rulesStore
        self.stores = stores
        coverController = CoverOverrideController(target: .collectionCover, layoutStore: stores.layoutStore,
                                                  preferences: preferences, resolveURL: resolveURL)
    }

    /// メタデータ生成が読み終えるのを待って並べる。
    func open() async {
        guard let generator = stores.generator else { return }
        let workspace = await MetadataWorkspace.open(generator: generator, store: metadataStore)
        // ほかの書き手(1 冊ぶんのシート・保存データの読み込み・書誌の取り込み)が変えた行の形を受ける。
        observeStoreChanges(of: workspace)
        // 規則の窓(解析の設定・抽出の設定)に、この一覧の名前を渡す(規則を直しながら、この一覧の名前で読めぐあいを見る)。
        MetadataRulesPicked.shared.set(workspace.books.map(\.fileName))
        self.workspace = workspace
        outdatedBookIDs = metadataStore.outdatedFieldBookIDs.intersection(workspace.bookIDs)
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

    /// アプリの外で名前を変えた・移した本の保存データ(5 つのストアと読書位置)を、ブックマークが指す新しいパスへ付け替える。
    /// アプリの中での移動・改名と同じ `BookRecordRelocator` を通す(2026-09-22、利用者の報告: 改名したファイルが古い名前のまま
    /// 保存データに残り続け、メタデータの編集に古い名前で並んでいた。以前は本を開いたときにしか付け替えなかった ――
    /// `reconcileBookIDIfMoved`)。
    ///
    /// 新しいパスに既に行があるストアでは付け替えない(`applyBookRelocation` の決まり)ので、古い行が残ることがある。同じ本を
    /// 窓を開いている間に何度も付け替えに行かないよう、一度試した本は覚えておく(`relocationAttempted`)。
    /// - Returns: 付け替えたか(呼び出し側は一覧を作り直す)。
    private func relocateMovedBooks(_ located: [(String, (result: BookExistenceProbe.Result, movedTo: String?))]) async -> Bool {
        guard let relocator else { return false }
        let moved = located.compactMap { bookID, location -> FileSystemChange.Relocation? in
            guard let movedTo = location.movedTo else { return nil }
            return FileSystemChange.Relocation(from: URL(fileURLWithPath: bookID), to: URL(fileURLWithPath: movedTo))
        }
        // ビューアで開いている本は見送る(ExternalMoveSweeper.excludingOpenBooks)。
        let relocations = ExternalMoveSweeper.excludingOpenBooks(moved, openBookIDs: ViewerViewModel.openBookIDs)
            .filter { relocationAttempted.insert($0.from.path).inserted }
        guard !relocations.isEmpty else { return false }
        await relocator.apply(FileSystemChange(relocations: relocations)).value
        return true
    }

    private func makeProbes(_ bookIDs: some Sequence<String>) -> [BookExistenceProbe] {
        bookIDs.map { bookID in
            BookExistenceProbe.make(
                bookID: bookID, metadataStore: stores.metadataStore, layoutStore: stores.layoutStore,
                bookmarkStore: stores.bookmarkStore, favoritesStore: stores.favoritesStore,
                collectionStore: stores.collectionStore, folderAccess: stores.folderAccess)
        }
    }

    /// 本の実体があるかを、画面の外で確かめる(`BookExistenceProbe.evaluateAtRecordedPath`。この窓は本をパスで並べるので、
    /// 名前を変えた本の古いパスも「無い」にする)。
    /// **確かめられなかった本(アクセス権が無い・ボリュームが繋がっていない)は「無い」にしない** ―― 灰色で出して
    /// 削除を促すのは、確かに無いと分かった本だけ。
    private func checkExistence(of workspace: MetadataWorkspace) {
        let probes = makeProbes(workspace.bookIDs)
        existenceTask?.cancel()
        existenceTask = Task { [weak self, weak workspace] in
            let located = await Task.detached(priority: .utility) {
                probes.map { ($0.bookID, $0.locateAtRecordedPath()) }
            }.value
            guard !Task.isCancelled, let self else { return }
            // 登録済みの本のうち、アプリの外で名前を変えた本。付け替えたら一覧を作り直す(existingOrRegistered と同じ)。
            if await self.relocateMovedBooks(located) {
                guard !Task.isCancelled else { return }
                // reopen は close でこの Task を取り消すので、別の Task で走らせる(取り消された中で開き直さない)。
                Task { await self.reopen() }
                return
            }
            workspace?.setMissing(Set(located.filter { $0.1.result == .missing }.map(\.0)))
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
                var changes: [String: BookMetadataRecord?] = [:]
                for id in ids { changes[id] = .some(self.metadataStore.record(forBookID: id)) }
                // 知らせが「全部」(bookID 無し)で、行が消えた本があれば一覧を作り直す(2026-09-22 の監査): 移動・名前の変更の
                // 付け替えでは、古いパスの行が消えて新しいパスに移る。一覧から外すだけだと、新しいパスの本が出ないまま残った。
                if notification.userInfo?["bookID"] == nil,
                   changes.contains(where: { $0.value == nil && workspace.row($0.key) != nil && self.metadataStore.deletedThisSession.contains($0.key) == false }) {
                    self.scheduleReopen()
                    return
                }
                workspace.applyExternalChanges(changes)
            }
        }
        observers.append(observer)
    }

    @ObservationIgnored private var reopenTask: Task<Void, Never>?

    /// 一覧の作り直しを頼む(続けて頼まれても 1 回)。
    private func scheduleReopen() {
        guard reopenTask == nil else { return }
        reopenTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await self?.reopen()
            self?.reopenTask = nil
        }
    }

    /// 対象外のフォルダが変わったら、一覧を作り直す(対象に戻った本を並べ直すため。取り消しの歩みは捨てる)。
    func reopen() async {
        close()
        await open()
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

/// 編集メニューの「メタデータの編集…」から、窓を開くときに「この本を選んで見せて」と頼むための置き場
/// (2026-09-23、利用者の指示)。メニューはいつもこの窓を開き、ホーム画面で本を 1 冊選んでいれば、その本を渡す。
///
/// 窓がまだ開いていないとき(頼んでから中身ができる)にも、もう開いているとき(中身が `token` の変化で気づく)にも
/// 同じ経路で渡るよう、値と通し番号を持つ ―― 同じ本を 2 度頼めるようにするため(MetadataRulesPicked と同じ形)。
/// 受け取った側は `take()` で 1 度だけ引き取る(窓を開き直したときに前の頼みが蘇らない)。
@MainActor @Observable
final class MetadataEditorReveal {
    static let shared = MetadataEditorReveal()
    private(set) var bookID: String?
    private(set) var token = 0

    /// 窓を開く直前に呼ぶ(`bookID` が nil なら、ただ開くだけ)。
    func request(bookID: String?) {
        self.bookID = bookID
        token += 1
    }

    /// 頼みを 1 度だけ引き取る。
    @discardableResult
    func take() -> String? {
        defer { bookID = nil }
        return bookID
    }
}

/// 窓の中身。
struct MetadataEditorContent: View {
    let model: MetadataEditorModel
    @Bindable var workspace: MetadataWorkspace
    @Bindable var rulesStore: MetadataRulesStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var showsExcludedFolders = false
    /// 対象外のフォルダのシートの中で一覧が変わった(閉じたら一覧を作り直す)。
    @State private var reopensAfterExcludedFoldersSheet = false
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
                    .help("Parses and extracts the selected unlocked books again from their file names, throwing away the values you edited")
                }
                ToolbarItem {
                    // 選んだ本のロック。全部ロック済みなら外す、そうでなければ掛ける(右クリックと同じ)。
                    let selected = workspace.selectedBooks
                    let allLocked = !selected.isEmpty && selected.allSatisfy(\.isLocked)
                    Button { workspace.setLocked(Set(selected.map(\.id)), !allLocked) } label: {
                        Label(allLocked ? "Unlock" : "Lock", systemImage: allLocked ? "lock.open" : "lock")
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(selected.isEmpty)
                    .help("Locks the metadata of the selected books, or unlocks it")
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
            Text(verbatim: "%lld books were registered with only the author, title, series and volume, so their genre, event, source work and info are empty. Fill only the empty fields from the file names (the registered values stay locked), or unlock them and parse and extract them again from the file names (the locked values are thrown away).".ui(model.outdatedBookIDs.count))
        }
        .alert("Regenerate the metadata?", isPresented: $confirmsReparseAll) {
            Button("Cancel", role: .cancel) {}
            Button("Regenerate", role: .destructive) { workspace.reparseFromFileNames(workspace.regenerationTargets) }
        } message: {
            Text(verbatim: "%lld unlocked books are parsed and extracted again from their file names, and the values you edited are thrown away. Locked books are left alone. You can undo this with Undo.".ui(workspace.regenerationTargets.count))
        }
        .sheet(isPresented: $showsExcludedFolders, onDismiss: {
            guard reopensAfterExcludedFoldersSheet else { return }
            reopensAfterExcludedFoldersSheet = false
            Task { await model.reopen() }
        }) {
            MetadataExcludedFoldersSheet(rulesStore: rulesStore)
        }
        // 対象外のフォルダが変わったら一覧を作り直す。ただし対象外のフォルダのシートが出ている間は、閉じるまで待つ:
        // reopen は workspace をいったん nil にするので、このビュー(と @State のシート)が作り直され、フォルダを
        // 1 つ足すたびにシートが閉じていた(2026-09-22)。
        .onChange(of: rulesStore.excludedFolders) {
            if showsExcludedFolders {
                reopensAfterExcludedFoldersSheet = true
            } else {
                Task { await model.reopen() }
            }
        }
        // 編集メニューの「メタデータの編集…」が指した本を、選んで見える位置まで運ぶ(2026-09-23、利用者の指示。
        // MetadataEditorReveal)。窓を開いたところ(initial)と、もう開いている窓に頼まれたとき(token の変化)の両方。
        .onChange(of: MetadataEditorReveal.shared.token, initial: true) { _, _ in
            guard let bookID = MetadataEditorReveal.shared.take() else { return }
            workspace.reveal(bookID)
        }
        // 規則の窓で変えた内容は、メタデータ生成が読み直して届ける(MetadataWorkspace.generatorDidUpdate)。
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
    /// 出している確かめの窓(1 つの `.alert` で出す。body のコメント)。
    @State private var tableAlert: TableAlert?

    enum TableAlert: Identifiable {
        /// メタデータを削除する。
        case delete(Set<String>)

        var id: String {
            switch self {
            case .delete(let ids): "delete-\(ids.sorted().joined())"
            }
        }
    }

    private var alertTitle: String {
        switch tableAlert {
        case .delete?: "Delete the metadata of these books?".ui
        case nil: ""
        }
    }
    @State private var sheet: MetadataEditorSheet?

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
                          sortOrder: $workspace.sortOrder, revealRequest: workspace.revealRequest,
                          canEdit: canEdit, isEdited: isEdited, help: help, commit: commit,
                          contextMenu: contextMenu,
                          toggleLock: { [workspace] id in workspace.setLocked([id], !workspace.isLocked(id)) },
                          coverView: { [preferences] id in
                              AnyView(ExportCoverCell(bookID: id, controller: controller, showsCropAnchor: true)
                                  .environmentObject(preferences))
                          })
        .sheet(item: $sheet) { sheet in
            MetadataEditorSheetView(sheet: sheet, workspace: workspace, rulesStore: rulesStore) { name, ids in
                applySeriesName(name, to: ids)
            }
        }
        // 確かめの窓は 1 つの `.alert` にまとめる(シリーズ名の確かめは AppKit で出す ―― `applySeriesName` のコメント)。
        .alert(alertTitle, isPresented: Binding(get: { tableAlert != nil }, set: { if !$0 { tableAlert = nil } }),
               presenting: tableAlert) { alert in
            switch alert {
            case .delete(let ids):
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { workspace.deleteBooks(ids) }
            }
        } message: { alert in
            switch alert {
            case .delete(let ids):
                Text(verbatim: "The metadata of %lld books is deleted and they are removed from this list. The books themselves are not deleted. This can't be undone.".ui(ids.count))
            }
        }
    }

    /// 巻数(表記・並べ替え用とも)は、シリーズ名の決まっている本にしか入らない(シリーズの中の番号なので)。
    /// 巻数(並べ替え用)は巻の表記が空の本でも入る(2026-09-22、利用者の要望)。
    /// ロック(登録)した本は直せない。
    private func canEdit(_ column: MetadataBookTable.Column, _ book: MetadataBookRow) -> Bool {
        guard !book.isLocked else { return false }
        switch column {
        case .field(.volume), .volumeSort: return !MetadataWorkspace.currentSeriesName(book).isEmpty
        case .field: return true
        case .lock, .fileName, .cover: return false
        }
    }

    /// 青く出す欄: 直したが、まだロック(登録)していない値(案 A。ロックした本の値はふつうの色)。
    private func isEdited(_ column: MetadataBookTable.Column, _ book: MetadataBookRow) -> Bool {
        guard !book.isLocked else { return false }
        switch column {
        case .field(.series), .field(.volume): return book.hasConfirmedSeries
        case .field(let field): return book.edited.contains(field)
        case .volumeSort: return book.hasConfirmedVolumeSort
        case .lock, .fileName, .cover: return false
        }
    }

    private func help(_ column: MetadataBookTable.Column, _ book: MetadataBookRow) -> String {
        if book.isLocked { return "This book is locked. Unlock it to edit".ui }
        guard canEdit(column, book) else { return "Give the book a series name first".ui }
        guard case .field(let field) = column else {
            return "Double-click to set this book’s position in the series. Empty goes back to the number read from the volume".ui
        }
        switch field {
        case .series: return "Double-click to settle the series for this book. Empty puts it in no series".ui
        case .volume: return "Double-click to settle the volume for this book. Empty clears it".ui
        case .authors: return "Double-click to edit. Several authors are separated by 、".ui
        default: return "Double-click to edit this book’s value".ui
        }
    }

    private func commit(_ column: MetadataBookTable.Column, _ value: String, for book: MetadataBookRow) {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard case .field(let field) = column else {
            guard column == .volumeSort else { return }
            guard !text.isEmpty else { return workspace.setVolumeSort(nil, for: [book.id]) }
            // 全角の数字・小数点でも入るように、揃えてから読む。数に読めなければ何もしない(元の値のまま)。
            guard let number = MetadataWorkspace.volumeSortNumber(text) else { return NSSound.beep() }
            return workspace.setVolumeSort(number, for: [book.id])
        }
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
    ///
    /// 確かめは **AppKit の `NSAlert` をこの窓のシートとして出す**(2026-09-22、利用者の報告: 巻のある本のシリーズ名をセルで
    /// 書き換えて Return を押しても、確かめが出ずに元の名前のままだった。巻を消してから書き換えると、ほかの本を巻き込まず
    /// 確かめを通らないので書き換わった)。以前は SwiftUI の `.alert(item:)` で出していたが、実物では出なかった(同じ組み立ての
    /// 小さな再現では出たので、何が止めているかは分かっていない)。表の書き換え(AppKit)から続く確かめなので、AppKit で出す。
    private func applySeriesName(_ name: String, to ids: Set<String>) {
        Task { @MainActor in
            let preview = await workspace.previewSetSeries(name, for: ids)
            guard preview.others > 0 else { return workspace.setSeries(name, for: ids) }
            let alert = NSAlert()
            alert.messageText = "Make “%@” the series?".ui(name)
            alert.informativeText = "This also changes %1$lld books you did not pick: %2$lld gain a series and %3$lld lose one."
                .ui(preview.others, preview.gained, preview.lost)
            alert.addButton(withTitle: "Apply anyway".ui)
            alert.addButton(withTitle: "Cancel".ui)
            let apply = { [workspace] in workspace.setSeries(name, for: ids) }
            if let window = NSApp.keyWindow, window.attachedSheet == nil {
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn { apply() }
                }
            } else if alert.runModal() == .alertFirstButtonReturn {
                apply()
            }
        }
    }

    // MARK: 右クリック

    /// 右クリックのメニュー。1 冊だけでも複数でも同じ並び(その場で意味の無い項目は淡色)。
    private func contextMenu(_ ids: Set<String>) -> [MetadataBookTable.MenuItem] {
        typealias Item = MetadataBookTable.MenuItem
        let books = ids.compactMap { workspace.row($0) }
        let editable = Set(books.filter { !$0.isLocked }.map(\.id))
        let lockedIDs = Set(books.filter(\.isLocked).map(\.id))

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
        // 欄。シリーズと巻も並べる(2026-09-22、利用者の指摘: まとめて変える所にシリーズが無い)。中身は一覧の欄を
        // 直接直したときと同じ(`commit`): シリーズは確定した名前、空ならシリーズから外す。巻はシリーズ名のある本だけ。
        let fields: [QMBookMetadata.Field] = [.title, .authors, .series, .volume, .genre, .event, .source, .info]
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
        // どの本でも削除できる: 一覧から消え、DB の登録と下書きも消える(利用者の指示 2026-09-22。以前は「登録か下書きが
        // ある本だけ」で、提案のままの本では淡色だった ―― 削除したいのに押せず、押せない理由も見えなかった)。
        // 「このフォルダを対象外にする」は、一覧に並ぶのは本なのにフォルダを指す項目で分かりにくい、と外した(同日)。
        // 対象外のフォルダは、ツールバーの対象外のフォルダのシートで足す。
        items.append(Item(title: "Delete Metadata…".ui) {
            tableAlert = .delete(ids)
        })
        items.append(.separator)
        // どこにある本かを辿れるように(2026-09-22、利用者の要望)。見つからない本は、残っているいちばん近いフォルダを開く。
        items.append(Item(title: "Show in Finder".ui) { showInFinder(books) })
        items.append(Item(title: "Copy File Name".ui) {
            let names = ids.sorted().map { URL(fileURLWithPath: $0).lastPathComponent }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
        })
        return items
    }
}

extension MetadataBookTableView {
    /// 「Finder で表示」。実在する本は Finder で選び(`activateFileViewerSelecting` はこのアプリの読む権限を要らない)、
    /// 見つからない本(名前を変えた・消した・未接続のボリューム)は、残っているいちばん近いフォルダを開く。
    fileprivate func showInFinder(_ books: [MetadataBookRow]) {
        let found = books.filter { !$0.isMissing }.map { URL(fileURLWithPath: $0.id) }
        if !found.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(found)
            return
        }
        var folders: [URL] = []
        for book in books {
            var folder = URL(fileURLWithPath: book.id).deletingLastPathComponent()
            while folder.path != "/" && !FileManager.default.fileExists(atPath: folder.path) {
                folder = folder.deletingLastPathComponent()
            }
            if folder.path != "/", !folders.contains(folder) { folders.append(folder) }
        }
        guard !folders.isEmpty else {
            NSSound.beep()
            return
        }
        for folder in folders { NSWorkspace.shared.open(folder) }
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
            switch field {
            case .series:
                Text("Every book you picked is put in this series. Empty removes them from their series.")
                    .font(.caption).foregroundStyle(.secondary)
            case .volume:
                Text("Every book you picked gets this volume. Books with no series name are left alone. Empty clears the volume.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                if field == .authors {
                    Text("Separate several authors with 、").font(.caption).foregroundStyle(.secondary)
                }
                Text("Every book you picked gets this value. Empty clears the field.").font(.caption).foregroundStyle(.secondary)
            }
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
        case .field(.series, let ids):
            // 選んでいない本が巻き込まれるときの確かめは、シリーズにまとめるときと同じ(`applySeries`)。
            if trimmed.isEmpty { workspace.removeFromSeries(ids) } else { applySeries(trimmed, ids) }
        case .field(.volume, let ids):
            if trimmed.isEmpty { workspace.clearVolumes(ids) } else { workspace.setVolumes(trimmed, for: ids) }
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

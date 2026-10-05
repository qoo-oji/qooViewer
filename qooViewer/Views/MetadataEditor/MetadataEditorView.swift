import AppKit
import Combine
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
    /// ツールバーのボタンから、中身(MetadataEditorContent)が持つ確かめの窓・シートを出す頼み。
    @State private var toolbarRequests = MetadataEditorToolbarRequests()
    @Environment(\.openWindow) private var openWindow

    /// ツールバーと検索欄は**窓の側に置き、最初のコマから出しておく**(表示の切り替えの監査の 17、2026-09-27)。
    /// 以前は読み込み終えた中身(MetadataEditorContent)の中にだけあり、`.task` → `model.open()` が終わってから現れたので、
    /// 開いた直後にタイトルバーの高さが変わり、一覧が下へずれた(作り直し `reopen` で中身がいったん消えるたびにも同じ)。
    /// 中身が無い間は同じ項目を淡色で出す(`MetadataEditorToolbarItems`)。確かめの窓とシートは中身の側に残す
    /// (中身の @State。作り直しで閉じる振る舞いを変えない)ので、ボタンは頼み(toolbarRequests)を送るだけ。
    var body: some View {
        let workspace = model?.workspace
        NavigationStack {
            Group {
                if let model, let workspace {
                    MetadataEditorContent(model: model, workspace: workspace, rulesStore: rulesStore,
                                          toolbarRequests: toolbarRequests)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .searchable(text: Binding(get: { workspace?.searchText ?? "" }, set: { workspace?.searchText = $0 }),
                        placement: .toolbar, prompt: Text("Search fields and file names"))
            .toolbar {
                MetadataEditorToolbarItems.items(
                    workspace: workspace,
                    requestRegenerate: { [toolbarRequests] in toolbarRequests.requestRegenerate() },
                    openParsingSettings: { [openWindow] in
                        guard let workspace else { return }
                        MetadataEditorContent.openParsingSettings(workspace: workspace, openWindow: openWindow)
                    },
                    openExtractionSettings: { [openWindow] in openWindow(id: SeriesRulesView.windowID) })
            }
            // 読み込み中は検索欄も触れないようにする(入れた文字の行き先がまだ無い)。
            .disabled(workspace == nil)
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
                // ゴミ箱の中まで追った場所は「見つからない」(BookLocationResolver.outsideTrash。2026-10-04 の監査 O-11: 「開く」でゴミ箱の中の
                // 本を開き、保存データがゴミ箱の中のパスへ付け替わっていた)。見つからなければ呼び出し側は素のパス(元の場所)を使う。
                resolveURL: { [weak metadataStore, weak bookmarkStore, weak layoutStore, weak collectionStore] bookID in
                    BookLocationResolver.outsideTrash(bookmarkStore?.resolvedURLFromBookmarkData(forBookID: bookID))
                        ?? BookLocationResolver.outsideTrash(layoutStore?.resolvedURL(forBookID: bookID))
                        ?? BookLocationResolver.outsideTrash(metadataStore?.resolvedURL(forBookID: bookID))
                        ?? BookLocationResolver.outsideTrash(collectionStore?.anyBookmarkData(forBookID: bookID)
                            .flatMap { FavoritesStore.resolvedURL(fromBookmark: $0) })
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
    /// 走っている実在の確かめ(通し番号 → 仕事)。全冊の確かめと `close` は、**全部**を取り消す(2026-10-04 のレビューの R4-4 ――
    /// 以前は最後の 1 つだけを持ち、一部の確かめが全冊の確かめを待つ間にそれと入れ替わったので、後の全冊の確かめ・閉じたときの
    /// 取り消しが前の全冊の確かめに届かず、閉じた後も付け替えまで進み、新しい確かめより後に終わると古い灰色で上書きした)。
    @ObservationIgnored private var existenceTasks: [Int: Task<Void, Never>] = [:]
    /// 最後に始めた確かめ(一部の確かめは、その後に並ぶ)。
    @ObservationIgnored private var lastExistenceTask: Task<Void, Never>?
    @ObservationIgnored private var existenceSerial = 0
    /// アプリの中の変更の知らせの出どころ(テストは自分の箱を渡す ―― FileSystemChangeCenter の型コメント)。
    @ObservationIgnored private let fileSystemChanges: FileSystemChangeCenter
    /// 規則の窓へ一覧の名前を渡す置き場(`publishNamesForRules`。既定はアプリで 1 つの `shared`。テストは自分のものを渡す ――
    /// 共有の状態に触れない)。
    @ObservationIgnored private let rulesPicked: MetadataRulesPicked
    /// アプリの外で名前を変えた本の保存データの付け替え役(AppStores に 1 つ。`relocateMovedBooks`)。
    @ObservationIgnored private let relocator: BookRecordRelocator?
    /// 付け替えを一度試した本(古いパス)。新しいパスに行があって付け替わらなかった本を、何度も試さない。
    @ObservationIgnored private var relocationAttempted: Set<String> = []

    /// 本の実体の URL(保存データのブックマークから。右クリックの「コレクションに登録」など。2026-09-23)。
    @ObservationIgnored let resolveURL: (String) -> URL?

    /// 「開く」の前に場所を解決する材料(StoredBookLocator。2026-10-04 の監査 O-12 ―― 「開く」はメインの外で期限つき・`.userOpen` で
    /// 解決する。以前は上の resolveURL(既定の `.background`、メインで同期)で、繋がっていないボリュームの本は解決できず素のパスで
    /// 新しい窓を開いてエラーにした)。
    func locatorMaterial(forBookID bookID: String) -> StoredBookLocator.Material {
        StoredBookLocator.material(
            forBookID: bookID, bookmarkStore: stores.bookmarkStore, layoutStore: stores.layoutStore,
            metadataStore: stores.metadataStore, collectionStore: stores.collectionStore
        )
    }

    init(metadataStore: BookMetadataStore, rulesStore: MetadataRulesStore, stores: Stores,
         preferences: AppPreferences, relocator: BookRecordRelocator?, fileSystemChanges: FileSystemChangeCenter = .shared,
         rulesPicked: MetadataRulesPicked? = nil, resolveURL: @escaping (String) -> URL?) {
        self.fileSystemChanges = fileSystemChanges
        self.rulesPicked = rulesPicked ?? .shared
        self.resolveURL = resolveURL
        self.relocator = relocator
        self.metadataStore = metadataStore
        self.rulesStore = rulesStore
        self.stores = stores
        coverController = CoverOverrideController(target: .collectionCover, layoutStore: stores.layoutStore,
                                                  preferences: preferences, resolveURL: resolveURL)
    }

    /// 開くたびに進める番号(`close` で進む)。待っている間に閉じられた・作り直しが重なった `open` は、待ち終えてから何もしない
    /// (2026-09-23 の 3 回目の監査の低: 以前は窓を閉じた後も続き、外されない知らせの購読・一覧・全冊の実在確認を作っていた)。
    @ObservationIgnored private var openGeneration = 0

    /// メタデータ生成が読み終えるのを待って並べる。
    /// - Parameter reregistersDeletedBooks: 利用者が窓を開いたときだけ true(`MetadataWorkspace.open`)。
    func open(reregistersDeletedBooks: Bool = true) async {
        guard let generator = stores.generator else { return }
        let generation = openGeneration
        let workspace = await MetadataWorkspace.open(generator: generator, store: metadataStore,
                                                     reregistersDeletedBooks: reregistersDeletedBooks)
        guard generation == openGeneration else { return }
        // ほかの書き手(1 冊ぶんのシート・保存データの読み込み・書誌の取り込み)が変えた行の形を受ける。
        observeStoreChanges(of: workspace)
        // 規則の窓(解析の設定・抽出の設定)に、この一覧の名前を渡す(規則を直しながら、この一覧の名前で読めぐあいを見る)。
        publishNamesForRules(of: workspace)
        self.workspace = workspace
        outdatedBookIDs = metadataStore.outdatedFieldBookIDs.intersection(workspace.bookIDs)
        checkExistence(of: workspace)
    }

    /// 規則の窓の「名前の読めぐあい」へ、一覧の本の名前と、その本を読むルールセットを渡す(2026-10-04 の監査 MD-5 ――
    /// 以前は名前だけを開いた時に 1 度渡し、規則の窓は全冊を直しているルールセットで読んでいた)。開いた時と、一覧の行が
    /// 変わるたび(`MetadataWorkspace.booksRevision`。ルールセットの切り替え・自動の選択の変更を含む)に呼ぶ。中身が同じなら
    /// 受け手が何もしない。
    func publishNamesForRules(of workspace: MetadataWorkspace) {
        rulesPicked.set(workspace.books.map { ($0.fileName, workspace.presetName(for: $0.id)) })
    }

    /// 以前の版の欄で登録した本の、空の欄だけをファイル名から埋める(登録した値はそのまま。ロックも掛けたまま)。
    ///
    /// 読むルールセットは一覧と同じ、その本のもの(右クリックで選んだものがあればそれ。`MetadataWorkspace.presetName(for:)`)。
    /// 2026-10-04 の監査 MD-13(b) ―― 以前は自動の選択だけで読み、行で選んだルールセットを見なかった。
    func fillMissingFieldsOfOutdatedBooks() {
        let rules = rulesStore.rules
        let workspace = self.workspace
        metadataStore.fillMissingFields(of: outdatedBookIDs) { bookID in
            guard let preset = workspace?.presetName(for: bookID) else {
                return BookMetadataValues(MetadataRulesStore.reading(forBookID: bookID, rules: rules).metadata)
            }
            return BookMetadataValues(MetadataRulesStore.reading(forBookID: bookID, rules: rules, preset: preset).metadata)
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
    /// - Returns: 付け替えた本(古いパス)。一覧の行は付け替えの知らせで新しいパスへ移る(`followRelocation`)。
    private func relocateMovedBooks(_ located: [(String, (result: BookExistenceProbe.Result, movedTo: String?))]) async -> Set<String> {
        guard let relocator else { return [] }
        let moved = located.compactMap { bookID, location -> FileSystemChange.Relocation? in
            guard let movedTo = location.movedTo else { return nil }
            return FileSystemChange.Relocation(from: URL(fileURLWithPath: bookID), to: URL(fileURLWithPath: movedTo))
        }
        // ビューアで開いている本は見送る(ExternalMoveSweeper.excludingOpenBooks)。
        let relocations = ExternalMoveSweeper.excludingOpenBooks(moved, openBookIDs: ViewerViewModel.openBookIDs)
            .filter { relocationAttempted.insert($0.from.path).inserted }
        guard !relocations.isEmpty else { return [] }
        await relocator.apply(FileSystemChange.foundOutsideTheApp(relocations)).value
        return Set(relocations.map(\.from.path))
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
    ///
    /// - Parameters:
    ///   - only: 確かめ直す本(窓を開いた後のファイルの変化。MD-3)。nil なら一覧の全冊(開いたとき・ボリュームの着脱)。
    ///   - change: 一部の確かめの契機になったアプリの中の変更(`handleFileSystemChange`)。
    private func checkExistence(of workspace: MetadataWorkspace, only: Set<String>? = nil, after change: FileSystemChange? = nil) {
        let bookIDs = only.map { ids in workspace.bookIDs.filter(ids.contains) } ?? workspace.bookIDs
        guard !bookIDs.isEmpty else { return }
        // 全冊の確かめは、走っている確かめを**すべて**取り消して始め直す(R4-4)。一部の確かめは、最後に始めた確かめの後に並べる
        // (取り消すと、全冊ぶんの答えが届かなくなる)。
        if only == nil { cancelExistenceChecks() }
        let previous = lastExistenceTask
        existenceSerial &+= 1
        let serial = existenceSerial
        let task = Task { [weak self, weak workspace] in
            defer { self?.existenceTasks[serial] = nil }
            // 前の確かめを待つのは期限まで(2026-10-05 の監査 A6-F3)。前の確かめが応答しない共有(hard の NFS)で戻らないと、以前は後から
            // 並んだ確かめが全部いつまでも待ち、ファイルの変更のたびに 1 つずつ積もって、灰色の行も直らなくなった。期限を過ぎたら
            // 並びを諦めて自分の確かめを進める(遅れて届く前の答えが後から当たっても、次の確かめで直る)。
            if let previous {
                _ = try? await FileIO.withDeadline(Self.previousExistenceCheckWait) { await previous.value }
            }
            // 確かめの材料(本ごとに 5 つのストアのブックマークとアクセス権の判定)は、この Task の中で作る(表示の切り替えの
            // 監査の 17、2026-09-27)。以前は open の中でメインのまま全冊ぶん作ってから返っていたので、組み上がった一覧を
            // 描くのがその分遅れた。確かめ自体はもともと画面の外で、結果が届くのは後なので、材料を作る時が少し後になるだけ。
            await Task.yield()
            guard !Task.isCancelled, let probes = self?.makeProbes(bookIDs) else { return }
            let located = await FileIO.perform(qos: .utility) {
                probes.map { ($0.bookID, $0.locateAtRecordedPath()) }
            }
            guard !Task.isCancelled, let self else { return }
            if let change {
                // アプリの中の変更が契機の確かめは、**保存データを付け替えない**(2026-10-04 のレビューの R4-3)。旧 → 新は分かっていて、
                // 付け替えは `AppStores` が起きた順に当てる(`BookRecordRelocator`)。以前はここでもブックマークが指す先を「外での移動」
                // (同時の写し)として改めて当てていたので、調べている間に次のアプリの中の操作(⌘Z で戻す・入れ替え)の付け替えが先に
                // 並ぶと、古い写しが後から当たり、元のパスへ戻った保存データを実在しない先へ ―― 入れ替えでは別の本へ ―― 移した。
                // 灰色だけを合わせる。この変更で移った本は灰色にしない(行は付け替えの知らせで新しいパスへ移る ―― 灰色にすると、
                // 移した先の行まで灰色で運ばれる)。アプリの外で動いていた本は灰色のまま残る(窓を開き直したときの全冊の確かめが付け替える)。
                let missing = Set(located.filter { bookID, location in
                    location.result == .missing && change.relocatedPath(for: bookID) == nil
                }.map(\.0))
                guard let workspace else { return }
                workspace.setMissing(missing.filter(workspace.contains), among: Set(bookIDs))
                return
            }
            // 登録済みの本のうち、アプリの外で名前を変えた本は付け替える(existingOrRegistered と同じ)。一覧の行は付け替えの知らせで
            // 新しいパスへ移る(2026-10-04 の監査 MD-2。以前はここで中身を作り直し、選択・絞り込み・打ちかけのセルが消えた)。
            let relocated = await self.relocateMovedBooks(located)
            guard !Task.isCancelled else { return }
            let missing = Set(located.filter { $0.1.result == .missing && !relocated.contains($0.0) }.map(\.0))
            workspace?.setMissing(missing, among: Set(bookIDs))
        }
        existenceTasks[serial] = task
        lastExistenceTask = task
    }

    /// 一部の確かめが、前に始めた確かめを待つ上限(`checkExistence` のコメント)。
    private static let previousExistenceCheckWait: Duration = .seconds(10)

    /// 走っている実在の確かめをすべて取り消す(全冊の確かめを始め直すとき・閉じるとき。R4-4)。
    private func cancelExistenceChecks() {
        for task in existenceTasks.values { task.cancel() }
        existenceTasks = [:]
        lastExistenceTask = nil
    }

    /// 走っている実在の確かめがすべて終わるまで待つ(テスト用)。
    func waitForExistenceChecks() async {
        while let task = existenceTasks.values.first {
            await task.value
        }
    }

    /// 走っている実在の確かめ(テスト用: 閉じた後も待てるように控える)。
    var runningExistenceChecks: [Task<Void, Never>] { Array(existenceTasks.values) }

    /// 窓を開いた後にアプリの中で本が消えた・戻った・動いた(2026-10-04 の監査 MD-3。`FileSystemChangeCenter`)。関わる本だけを
    /// 確かめ直す。以前は確かめるのが開いたときだけで、一覧にある本をファイルブラウザでゴミ箱へ入れても灰色にならず、「本が見つからない」
    /// の絞り込みにも出ず、右クリックの「開く」「Finder で表示」が有効なまま何も起きなかった(アプリの中でゴミ箱へ送った本の保存データは
    /// 元のパスに残るので、メタデータの知らせも作り直しも起きない)。
    private func handleFileSystemChange(_ change: FileSystemChange) {
        guard let workspace else { return }
        let touched = change.touchedPathSet
        guard !touched.isEmpty else { return }
        // 本そのもの、または本の入ったフォルダが変わった本(本の中の項目の変化は、あるかどうかに関わらない)。
        let affected = workspace.bookIDs.filter { MountTable.path(MountTable.normalized($0), isAtOrUnderAnyOf: touched) }
        guard !affected.isEmpty else { return }
        checkExistence(of: workspace, only: Set(affected), after: change)
    }

    /// この窓の外で DB が変わったら(1 冊ぶんのシート・保存データの読み込み・ビューアの取り込み)、その本を合わせる。
    /// **この窓が書いた知らせは読まない**(`isWritingBack`)。
    private func observeStoreChanges(of workspace: MetadataWorkspace) {
        // 本の付け替え(MD-2): 一覧の行・選択などを新しい bookID へ移す。付け替えで行が消えたために頼んでいた作り直しは取りやめる
        // (`goneAwaitingRelocation`。ストアの知らせはこの知らせより先に届く)。
        observers.append(NotificationCenter.default.addObserver(forName: .booksDidRelocate, object: nil, queue: .main) {
            [weak self, weak workspace] notification in
            guard let notice = BookRelocationNotice(notification) else { return }
            MainActor.assumeIsolated {
                guard let self, let workspace else { return }
                workspace.followRelocation(notice)
                if !self.goneAwaitingRelocation.isEmpty,
                   self.goneAwaitingRelocation.isSubset(of: workspace.relocatingBookIDs) {
                    self.goneAwaitingRelocation = []
                    self.reopenTask?.cancel()
                    self.reopenTask = nil
                }
            }
        })
        // 窓を開いた後のファイルの変化(MD-3): アプリの中の変化は関わる本だけ、ボリュームの着脱は全冊を確かめ直す。
        fileSystemChangeSubscription = fileSystemChanges.changes.sink { [weak self] change in
            MainActor.assumeIsolated { self?.handleFileSystemChange(change) }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self, weak workspace] _ in
                MainActor.assumeIsolated {
                    guard let self, let workspace, workspace === self.workspace else { return }
                    self.checkExistence(of: workspace)
                }
            })
        }
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
                let gone = Set(changes.filter {
                    $0.value == nil && workspace.row($0.key) != nil && self.metadataStore.deletedThisSession.contains($0.key) == false
                }.keys)
                if notification.userInfo?["bookID"] == nil, !gone.isEmpty {
                    // 付け替えなら、続いて届く付け替えの知らせで行が移る(作り直さない。MD-2)。届かなければ作り直す。
                    if gone.isSubset(of: workspace.relocatingBookIDs) { return }
                    self.goneAwaitingRelocation.formUnion(gone)
                    self.scheduleReopen()
                    return
                }
                workspace.applyExternalChanges(changes)
            }
        }
        observers.append(observer)
    }

    @ObservationIgnored private var reopenTask: Task<Void, Never>?
    /// 行が消えたので作り直しを頼んだ本のうち、付け替えの知らせを待っているもの(付け替えなら作り直さない。MD-2)。
    @ObservationIgnored private var goneAwaitingRelocation: Set<String> = []
    @ObservationIgnored private var fileSystemChangeSubscription: AnyCancellable?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    /// 一覧の作り直しを頼む(続けて頼まれても 1 回)。付け替えの知らせで取りやめることがある(取り消されたら作り直さない)。
    private func scheduleReopen() {
        guard reopenTask == nil else { return }
        reopenTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.goneAwaitingRelocation = []
            await self?.reopen()
            self?.reopenTask = nil
        }
    }

    /// シークレットフォルダが変わったら、一覧を作り直す(外した本を並べ直すため。取り消しの歩みは捨てる)。
    func reopen() async {
        close()
        await open(reregistersDeletedBooks: false)
    }


    func close() {
        openGeneration += 1
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        fileSystemChangeSubscription = nil
        goneAwaitingRelocation = []
        cancelExistenceChecks()
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
    /// 窓のツールバーのボタンからの頼み(ツールバーは窓の側にある。MetadataEditorWindow の body のコメント)。
    let toolbarRequests: MetadataEditorToolbarRequests
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var confirmsReparseAll = false

    var body: some View {
        VStack(spacing: 0) {
            MetadataFilterBar(workspace: workspace)
            Divider()
            MetadataBookTableView(model: model, workspace: workspace, rulesStore: rulesStore,
                                  openParsingSettings: openParsingSettings)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ListWindowStatusBar {
                Text(verbatim: "%1$lld / %2$lld books".ui(workspace.visibleCount, workspace.books.count))
                // 数えるのは操作が効く本(見えている行のうち選んでいるもの。監査 MD-4)。
                if !workspace.selectedBooks.isEmpty {
                    ListWindowStatusSeparator()
                    Text(verbatim: "%lld selected".ui(workspace.selectedBooks.count))
                }
            }
        }
        .hardTopScrollEdgeEffect()
        // 一覧の行が変わったら、規則の窓の名前の読めぐあいへ渡し直す(本ごとのルールセットが変わりうる。監査 MD-5)。
        .onChange(of: workspace.booksRevision) { model.publishNamesForRules(of: workspace) }
        // ツールバーの「メタデータを再生成」(窓の側。MetadataEditorToolbarItems)。頼みの番号が進んだら出す。
        // 作り直された中身は、それより前の頼みには応えない(onChange は最初の値では呼ばれない)。
        .onChange(of: toolbarRequests.regenerateSerial) { confirmsReparseAll = true }
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
        // シークレットフォルダが変わったら一覧を作り直す(その中の本は並べない。SecretFolderStore)。2026-10-03 までは、
        // この窓のツールバーの「除外フォルダ設定」のシートで変えていた(環境設定の「シークレットフォルダ」へ移した)。
        .onReceive(NotificationCenter.default.publisher(for: SecretFolderStore.didChange)) { note in
            guard (note.object as? SecretFolderStore)?.isAppWideStore == true else { return }
            Task { await model.reopen() }
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
        Self.openParsingSettings(workspace: workspace, openWindow: openWindow)
    }

    /// 上の本体(窓の側のツールバーからも呼ぶ)。
    static func openParsingSettings(workspace: MetadataWorkspace, openWindow: OpenWindowAction) {
        let picked = workspace.selectedBooks.first.map { workspace.presetName(for: $0.id) }
        MetadataRulesPicked.shared.open(ruleSet: picked ?? workspace.formats.defaultName)
        openWindow(id: FileNameRulesView.windowID)
    }
}

/// ツールバーのボタンから、中身(MetadataEditorContent)の確かめの窓・シートを出すための頼み(窓に 1 つ)。
/// 番号を進めるだけで、中身が `onChange` で受ける(同じ頼みを 2 度出せるよう、値ではなく通し番号)。
@MainActor @Observable
final class MetadataEditorToolbarRequests {
    private(set) var regenerateSerial = 0

    func requestRegenerate() { regenerateSerial += 1 }
}

/// 「メタデータの編集」ウインドウのツールバーの項目(表示の切り替えの監査の 17、2026-09-27)。
///
/// 窓の側(MetadataEditorWindow)で、中身ができる前から出す。中身(`workspace`)が無い間は同じ項目を淡色で出す ―― 項目の数と
/// 並びが変わらないので、読み終えてもツールバーとタイトルバーの形は動かない。項目と並びは以前 MetadataEditorContent にあったものと同じ。
enum MetadataEditorToolbarItems {
    @MainActor @ToolbarContentBuilder
    static func items(
        workspace: MetadataWorkspace?,
        requestRegenerate: @escaping () -> Void,
        openParsingSettings: @escaping () -> Void,
        openExtractionSettings: @escaping () -> Void
    ) -> some ToolbarContent {
        if let workspace, workspace.isWorking {
            ToolbarItem { ProgressView().controlSize(.small) }
        }
        // 並びは利用者の指示(2026-09-21): すべて選択・メタデータを再生成・ロック・解析の設定・抽出の設定・対象外のフォルダ。
        ToolbarItem {
            Button { workspace?.toggleSelectAll() } label: {
                Label(workspace?.isEveryVisibleBookSelected == true ? "Deselect All" : "Select All",
                      systemImage: "checkmark.rectangle.stack")
            }
            // ほかのボタンと同じく文字も出す(絵だけでは何のボタンか分からない)。
            .labelStyle(.titleAndIcon)
            .disabled((workspace?.visibleCount ?? 0) == 0)
            .help("Select All / Deselect All")
        }
        ToolbarItem {
            Button { requestRegenerate() } label: {
                Label("Regenerate Metadata", systemImage: "arrow.triangle.2.circlepath")
            }
            .labelStyle(.titleAndIcon)
            .disabled(workspace?.regenerationTargets.isEmpty ?? true)
            .help("Parses and extracts the selected unlocked books again from their file names, throwing away the values you edited")
        }
        ToolbarItem {
            // 選んだ本のロック。全部ロック済みなら外す、そうでなければ掛ける(右クリックと同じ)。
            let selected = workspace?.selectedBooks ?? []
            let allLocked = !selected.isEmpty && selected.allSatisfy(\.isLocked)
            Button { workspace?.setLocked(Set(selected.map(\.id)), !allLocked) } label: {
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
            // 選んでいる本のルールセットを選んで開くので、中身ができるまでは押せない。
            .disabled(workspace == nil)
            .help("Look at and correct the rule sets that read file names: the formats, the author separators and the words that choose a rule set")
        }
        ToolbarItem {
            Button { openExtractionSettings() } label: {
                Label("Extraction Settings", systemImage: "list.bullet.indent")
            }
            .labelStyle(.titleAndIcon)
            .disabled(workspace == nil)
            .help("Look at and correct the rules that derive the series and volume: policies, word rules and word lists")
        }
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
            MetadataLineMoveButtons(workspace: workspace)
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

/// 選んだ段を、その本の中で上 / 下へ動かすボタン(qooMeta 0.3.0 の `LineMoveButtons`。段は一覧のセルを押して選ぶ)。
/// 動かせない段(主のシリーズの段・端の段・ロックした本)を選んでいるときと、段を選んでいないときは淡色。
struct MetadataLineMoveButtons: View {
    @Bindable var workspace: MetadataWorkspace

    var body: some View {
        let line = workspace.lineSelection
        ControlGroup {
            Button { workspace.moveLine(up: true) } label: { Label("Move Up", systemImage: "chevron.up") }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .disabled(line.map { !workspace.canMoveLine($0, up: true) } ?? true)
                .help("Moves the selected line up within its book (Option-Command-Up Arrow)")
            Button { workspace.moveLine(up: false) } label: { Label("Move Down", systemImage: "chevron.down") }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .disabled(line.map { !workspace.canMoveLine($0, up: false) } ?? true)
                .help("Moves the selected line down within its book (Option-Command-Down Arrow)")
        }
        .labelStyle(.iconOnly)
        .fixedSize()
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
    /// 右クリックの「開く」「ファイルブラウザで表示」「コレクションに登録」(2026-09-23、利用者の指示)。
    @EnvironmentObject private var launchCoordinator: LaunchCoordinator
    @EnvironmentObject private var directory: HomeMenuDirectoryStore
    @Environment(\.collectionAdding) private var collectionAdding
    @Environment(\.openWindow) private var openWindow
    /// 「コレクションに登録」の結果の知らせ(一覧の下に浮かべる)。
    @State private var toastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    /// 出している確かめの窓(1 つの `.alert` で出す。body のコメント)。
    @State private var tableAlert: TableAlert?

    /// `.alert(_:isPresented:presenting:)` へ渡すだけなので `Identifiable` にしない(2026-10-05 の監査 A6-F2。以前は id を選んだ全件の
    /// パスの並べ替えと連結で作っていて、5 万冊を選んだ確かめでは数 MB の文字列を描き直しのたびにメインで作った)。
    enum TableAlert {
        /// メタデータを削除する。
        case delete(Set<String>)
        /// メタデータを再生成する(ロックしていない本。ツールバーのボタンと同じ確かめ ―― 2026-10-04 の監査 MD-10。以前は
        /// 右クリックだけ確かめずに直した欄を捨てていた。どちらも取り消せる)。
        case regenerate(Set<String>)
    }

    private var alertTitle: String {
        switch tableAlert {
        case .delete?: "Delete the metadata of these books?".ui
        case .regenerate?: "Regenerate the metadata?".ui
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
                          lineSelection: $workspace.lineSelection, isEditingCell: $workspace.isEditingCell,
                          canEdit: canEdit, isEdited: isEdited, help: help, commit: commit, insert: insert,
                          contextMenu: contextMenu,
                          toggleLock: { [workspace] id in workspace.setLocked([id], !workspace.isLocked(id)) },
                          coverView: { [preferences] id in
                              AnyView(ExportCoverCell(bookID: id, controller: controller, showsCropAnchor: true)
                                  .environmentObject(preferences))
                          },
                          registerCellCommit: { [workspace] commit in workspace.commitEditingCell = commit })
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
            case .regenerate(let ids):
                Button("Cancel", role: .cancel) {}
                // 確かめの間にロックされた本は外す(ツールバーの `regenerationTargets` と同じく、ロックしていない本だけ)。
                Button("Regenerate", role: .destructive) {
                    workspace.reparseFromFileNames(ids.filter { !workspace.isLocked($0) })
                }
            }
        } message: { alert in
            switch alert {
            case .delete(let ids):
                Text(verbatim: "The metadata of %lld books is deleted and they are removed from this list. The books themselves are not deleted. This can't be undone.".ui(ids.count))
            case .regenerate(let ids):
                Text(verbatim: "%lld unlocked books are parsed and extracted again from their file names, and the values you edited are thrown away. Locked books are left alone. You can undo this with Undo.".ui(ids.count))
            }
        }
        .overlay(alignment: .bottom) {
            ZStack {
                if let toastMessage {
                    OverlayToast(message: toastMessage)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.2), value: toastMessage)
        }
        .onDisappear { toastDismissTask?.cancel() }
    }

    private func showToast(_ message: String) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: FileBrowserState.toastDuration)
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }

    /// 巻数(表記・並べ替え用とも)は、シリーズ名の決まっている本にしか入らない(シリーズの中の番号なので)。
    /// 巻数(並べ替え用)は巻の表記が空の本でも入る(2026-09-22、利用者の要望)。ロック(登録)した本は直せない。
    private func canEdit(_ column: MetadataBookTable.Column, _ book: MetadataBookRow, _ line: Int) -> Bool {
        guard !book.isLocked else { return false }
        switch column {
        case .field(.volume), .volumeSort: return !MetadataWorkspace.currentSeriesName(book).isEmpty
        case .field: return true
        case .lock, .fileName, .cover: return false
        }
    }

    /// 青く出す段: 直したが、まだロック(登録)していない値(案 A。ロックした本の値はふつうの色)。値をいくつも持てる欄は
    /// 欄ごと(直すと並び全体が直した値になる)。
    private func isEdited(_ column: MetadataBookTable.Column, _ book: MetadataBookRow, _ line: Int) -> Bool {
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
        guard canEdit(column, book, 0) else { return "Give the book a series name first".ui }
        guard case .field(let field) = column else {
            return "Double-click to set this book’s position in the series. Empty goes back to the number read from the volume".ui
        }
        switch field {
        case .series: return "Double-click to settle the series for this book. Empty puts it in no series".ui
        case .volume: return "Double-click to settle the volume for this book. Empty clears it".ui
        case .authors: return "Double-click to edit. Several authors are separated by 、".ui
        case .source, .info: return "Double-click a line to edit it. Option-Return adds a line below".ui
        default: return "Double-click to edit this book’s value".ui
        }
    }

    /// 直した値の入れ先は、右クリックと同じ口(取り消しも同じ 1 手)。**押した 1 冊だけ**に入る。
    private func commit(_ column: MetadataBookTable.Column, _ line: Int, _ value: String, original: String,
                        for book: MetadataBookRow) {
        let text = value.trimmingCharacters(in: .whitespaces)
        switch column {
        case .lock, .fileName, .cover:
            return
        case .volumeSort:
            // 全角の数字・小数点でも入るように、揃えてから読む。数に読めなければ何もしない(元の値のまま)。
            let number = text.isEmpty ? nil : MetadataWorkspace.volumeSortNumber(text)
            if !text.isEmpty, number == nil { return NSSound.beep() }
            workspace.setVolumeSort(number, for: [book.id])
        case .field(.series):
            guard !text.isEmpty else { return workspace.removeFromSeries([book.id]) }
            applySeriesName(text, to: [book.id])
        case .field(.volume):
            if text.isEmpty { workspace.clearVolumes([book.id]) } else { workspace.setVolumes(text, for: [book.id]) }
        case .field(let field) where field.holdsSeveralInQooViewer:
            // 書き換えを始めた段が、確定の時点でもう無ければ(裏で並びが変わって消えた)何もしない(監査 MD-9)。
            if !workspace.setLine(field, of: book.id, at: line, to: text, replacing: original) { NSSound.beep() }
        case .field(let field):
            workspace.set(field, to: [text], for: [book.id])
        }
    }

    /// 段を足した(Option+Return・右クリックの「段を足す」。著者・原作・情報だけ)。
    private func insert(_ column: MetadataBookTable.Column, _ line: Int, _ value: String, for book: MetadataBookRow) {
        switch column {
        case .field(let field) where field.holdsSeveralInQooViewer:
            workspace.setLine(field, of: book.id, at: line, to: value, inserting: true)
        default: break
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
            WindowSheet.begin(alert) { response in
                if response == .alertFirstButtonReturn { apply() }
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
            tableAlert = .regenerate(editable)
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
        // ほかの機能へ(2026-09-23、利用者の指示)。開く・ファイルブラウザで表示は 1 冊だけ、見つからない本では淡色。
        // 「コレクションに登録」は見つかる本だけを入れる。相手の機能が OFF なら出さない。
        let found = books.filter { !$0.isMissing }
        let single = books.count == 1 ? found.first : nil
        items.append(Item(title: "Open".ui, isEnabled: single != nil) { if let single { openBook(single) } })
        if preferences.fileBrowserFeatureEnabled {
            items.append(Item(title: "Show in File Browser".ui, isEnabled: single != nil) {
                if let single { showInFileBrowser(single) }
            })
        }
        if preferences.libraryFeatureEnabled {
            let libraries = CollectionMenuLibrary.libraries(from: directory.directory, locale: preferences.effectiveLocale)
            items.append(Item(title: "Add to Collection".ui, isEnabled: !found.isEmpty,
                              children: collectionItems(libraries) { addToCollection(found, collectionID: $0) }))
        }
        items.append(.separator)
        // どこにある本かを辿れるように(2026-09-22、利用者の要望)。見つからない本は、残っているいちばん近いフォルダを開く。
        items.append(Item(title: "Show in Finder".ui) { showInFinder(books) })
        items.append(Item(title: "Copy File Name".ui) {
            let names = ids.sorted().map { URL(fileURLWithPath: $0, isDirectory: false).lastPathComponent }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
        })
        return items
    }
}

extension MetadataBookTableView {
    /// 本の実体の URL。保存データのブックマークから解決し、無ければパス(対象フォルダなど、読む許可のある場所の本)。
    fileprivate func bookURL(_ book: MetadataBookRow) -> URL {
        model.resolveURL(book.id) ?? URL(fileURLWithPath: book.id)
    }

    /// 「開く」。本のウインドウの外なので、新しいノーマルウインドウで開く(「お気に入りの編集」ウインドウから開くのと同じ)。
    /// 場所はメインの外で期限つきに解決し、見つからなければ開かずに知らせる(2026-10-04 の監査 O-12。ブックマーク・レイアウトの
    /// 編集ウインドウと同じ StoredBookLocator。以前は解決できないと素のパスで新しい窓を開き、窓の中でエラーにした)。
    fileprivate func openBook(_ book: MetadataBookRow) {
        let material = model.locatorMaterial(forBookID: book.id)
        let name = URL(fileURLWithPath: book.id, isDirectory: false).lastPathComponent
        let locale = preferences.effectiveLocale
        Task { @MainActor in
            switch await StoredBookLocator.resolve(material) {
            case .found(let url):
                BookWindowOpener.open(
                    BookOpenRequest(url), to: .newNormalWindow, from: nil,
                    launchCoordinator: launchCoordinator, openWindow: openWindow
                )
            case .notFound:
                showToast(String(format: String(localized: "“%@” could not be found.", language: locale), name))
            case .timedOut:
                NSSound.beep()
            }
        }
    }

    fileprivate func showInFileBrowser(_ book: MetadataBookRow) {
        FileBrowserReveal.revealWithoutWindow(bookURL(book), preferences: preferences, openWindow: openWindow)
    }

    /// 「コレクションに登録」▸ コレクション。結果は一覧の下に知らせる。
    fileprivate func addToCollection(_ books: [MetadataBookRow], collectionID: UUID) {
        let urls = books.map(bookURL)
        collectionAdding.add(urls, to: collectionID) { [self] message in showToast(message) }
    }

    /// 「コレクションに登録」のサブメニュー(ライブラリが 1 つなら 1 段。CollectionMenuLibrary.addMenuNodes と同じ形)。
    fileprivate func collectionItems(
        _ libraries: [CollectionMenuLibrary], add: @escaping (UUID) -> Void
    ) -> [MetadataBookTable.MenuItem] {
        typealias Item = MetadataBookTable.MenuItem
        func items(_ library: CollectionMenuLibrary) -> [Item] {
            guard !library.collections.isEmpty else { return [Item(title: "No Collections".ui, isEnabled: false)] }
            return library.collections.map { collection in Item(title: collection.name) { add(collection.id) } }
        }
        if libraries.count == 1, let only = libraries.first { return items(only) }
        return libraries.map { Item(title: $0.name, children: items($0)) }
    }

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
            for: [String(localized: "Cancel", language: locale), String(localized: "Apply", language: locale)],
            minWidth: 60, chrome: 0
        )
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: title).font(.headline)
            content
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button(role: .cancel) { dismiss() } label: { Text("Cancel").frame(width: buttonWidth) }
                    .keyboardShortcut(.cancelAction)
                // 確定のボタンは何をするかの動詞(2026-09-27、監査の 14。以前は「OK」)。
                Button { apply(); dismiss() } label: { Text("Apply").frame(width: buttonWidth) }
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
            if field.holdsSeveralInQooViewer {
                // 1 行に 1 つの値(値をいくつも持てる欄 ―― 著者・原作・情報。qooMeta 0.3.0)。
                TextEditor(text: $text)
                    .font(.body)
                    .frame(height: 90)
                    .border(.separator)
                Text("Write one value per line.").font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
            }
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
        if values.count == 1, let value = values.first { text = value.joined(separator: field.holdsSeveralInQooViewer ? "\n" : "、") }
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
            // 1 行に 1 つ。著者は、前からの癖で「、」で区切っても分かれる。
            let values = text.split(whereSeparator: \.isNewline).flatMap { MetadataWorkspace.linePieces(field, String($0)) }
            workspace.set(field, to: values, for: ids)
        }
    }
}


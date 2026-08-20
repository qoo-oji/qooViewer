import Foundation
import SwiftUI
import SwiftData
import Combine

/// 「本ごとの保存データを削除」ウインドウのロジック。
///
/// ユーザー要望: 検証用に開いただけの本など、DBに残ったままの不要なデータが煩わしいので、
/// 任意の本だけを選んでDBから削除できるようにしたい。ファイルパス・ファイルが実在するか
/// どうか・どの種類のデータが登録されているかのインジケータ・削除ボタンを持つ専用ウインドウ
/// として用意する(環境設定「リセット」タブからのみ開ける)。
///
/// 環境設定「リセット」タブの一括削除(ResetDataSettingsView)がストアの実ファイルごと消す
/// 「最後の手段」なのに対して、こちらは日常的な掃除のための、本1冊単位の操作にあたる。
@MainActor
final class LibraryCleanupViewModel: ObservableObject {

    /// 元のファイル/フォルダが今も存在するかどうか。
    ///
    /// サンドボックス環境では、アクセス権を持たないパスに対する存在確認そのものが失敗しうる。
    /// 「無い」と「確認できない」を同じ表示にまとめてしまうと、外部ボリュームを外している
    /// だけの本を「消えた」と誤解して削除してしまうおそれがあるため、3値で区別する。
    enum FileExistence: Sendable {
        case exists
        case missing
        /// アクセス権が無く判定できない(外付けボリュームが未接続の場合などもここに入る)。
        case unknown
        /// まだ確認できていない(非同期スキャンの結果待ち)。
        ///
        /// 実在判定はセキュリティスコープ付きブックマークの解決を伴い、対象が未接続の外付け/
        /// ネットワークボリュームを指していると1件あたり秒単位ブロックしうる。以前はこれを
        /// reload()の中で登録済みの全件ぶん同期実行しており、ウインドウを開いた瞬間に
        /// メインスレッドが長時間止まっていた。現在はパス・件数などDBだけで分かる情報を先に
        /// 表示し、実在判定はメインアクターの外で走らせて後から差し込む。その待ち状態がこれ。
        case checking
    }

    /// 一覧の1行。
    struct Row: Identifiable, Equatable {
        /// MangaBook.id(フォルダ/アーカイブファイルのパス)。
        let bookID: String
        let fileName: String
        let existence: FileExistence
        let favoriteCount: Int
        let bookmarkCount: Int
        let hasLayout: Bool
        let hasMetadata: Bool

        var id: String { bookID }
        /// ファイルパス列に表示する文字列(bookIDそのもの)。
        var path: String { bookID }
    }

    /// 一覧の絞り込み。掃除が目的の機能なので、「元ファイルが見つからない本」だけを
    /// すぐ抜き出せるようにしてある。
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case missingOnly

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .all: return "All Books"
            case .missingOnly: return "Missing Files Only"
            }
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var totalRowCount = 0
    /// 実在判定の非同期スキャンが進行中かどうか(ヘッダーに進捗表示を出すために使う)。
    @Published private(set) var isCheckingExistence = false
    @Published var searchText: String = "" {
        didSet { guard oldValue != searchText else { return }; rebuildRows() }
    }
    @Published var filter: Filter = .all {
        didSet { guard oldValue != filter else { return }; rebuildRows() }
    }

    private let favoritesStore: FavoritesStore
    private let bookmarkStore: BookmarkStore
    private let layoutStore: LayoutStore
    private let metadataStore: BookMetadataStore
    private let folderAccess: FolderAccessStore
    private let modelContext: ModelContext

    /// 絞り込み前の全行。
    private var allRows: [Row] = []

    init(
        favoritesStore: FavoritesStore,
        bookmarkStore: BookmarkStore,
        layoutStore: LayoutStore,
        metadataStore: BookMetadataStore,
        folderAccess: FolderAccessStore,
        modelContext: ModelContext
    ) {
        self.favoritesStore = favoritesStore
        self.bookmarkStore = bookmarkStore
        self.layoutStore = layoutStore
        self.metadataStore = metadataStore
        self.folderAccess = folderAccess
        self.modelContext = modelContext
        reload()
    }

    // MARK: - 一覧の構築

    /// 「このアプリが何らかの保存データを持っている本」をすべて集め直す。
    ///
    /// 通知(bookmarksDidChange等)は購読していない。このウインドウ自身が唯一の変更源であり、
    /// 削除のたびに自分でreload()するため。ウインドウを開いたまま他のウインドウで本を開いた
    /// 場合に一覧へ即座に反映されないが、掃除のための画面であり、開き直せば最新になる
    /// (逆に、削除操作の最中に一覧が勝手に組み変わるほうが扱いにくい)。
    func reload() {
        var bookIDs = metadataStore.registeredBookIDs
        bookIDs.formUnion(layoutStore.layoutBookIDs)
        bookIDs.formUnion(layoutStore.coverOverrideBookIDs())
        bookIDs.formUnion(bookmarkStore.groups.map(\.bookID))
        bookIDs.formUnion(favoritesStore.allRegisteredBookIDs())
        let readingStates = (try? modelContext.fetch(FetchDescriptor<BookReadingState>())) ?? []
        bookIDs.formUnion(readingStates.map(\.bookID))

        allRows = bookIDs
            .map { bookID in
                Row(
                    bookID: bookID,
                    fileName: URL(fileURLWithPath: bookID).lastPathComponent,
                    // 実在判定はここでは行わない(下のscheduleExistenceScanが後から埋める)。
                    // 既に判定済みならその結果を引き継ぎ、再スキャン中に表示が
                    // 「確認中」へ巻き戻らないようにする。
                    existence: existenceByBookID[bookID] ?? .checking,
                    favoriteCount: favoritesStore.favoriteCount(forBookID: bookID),
                    bookmarkCount: bookmarkStore.bookmarks(forBookID: bookID).count,
                    hasLayout: layoutStore.bookLayoutSettings(forBookID: bookID) != nil
                        || !layoutStore.pageOverrides(forBookID: bookID).isEmpty,
                    hasMetadata: metadataStore.isRegistered(bookID: bookID)
                )
            }
            // 一覧に出すのはフルパス1列だけになったため、並び順もパス基準にする
            // (同じフォルダの本が固まって並ぶため、「この検証用フォルダの分は丸ごと不要」と
            // いった掃除がしやすい)。
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        totalRowCount = allRows.count
        rebuildRows()
        scheduleExistenceScan(for: allRows.map(\.bookID))
    }

    private func rebuildRows() {
        var filtered = allRows
        if filter == .missingOnly {
            filtered = filtered.filter { $0.existence == .missing }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            filtered = filtered.filter {
                $0.fileName.localizedCaseInsensitiveContains(query)
                    || $0.path.localizedCaseInsensitiveContains(query)
            }
        }
        rows = filtered
    }

    /// 見つからないと判定された本の件数(絞り込み前の全体に対して)。
    var missingCount: Int {
        allRows.filter { $0.existence == .missing }.count
    }

    // MARK: - 実在判定(非同期)

    /// メインアクターの外へ渡す判定材料。SwiftDataのモデルはそのまま渡せないため、
    /// メインアクターにいるうちにSendableな値へ写し取る。
    private struct ExistenceProbe: Sendable {
        let bookID: String
        /// この本を指すセキュリティスコープ付きブックマークの候補(各ストアから集めた順)。
        let bookmarkCandidates: [Data]
        /// 環境設定「アクセス権」で許可済みのフォルダ配下かどうか。
        let isPathCovered: Bool
    }

    /// bookIDごとの実在判定の結果。まだ判定できていないものは入っていない。
    private var existenceByBookID: [String: FileExistence] = [:]

    /// 走行中のスキャンの世代番号。スキャンを開始するたびに1増やし、完了時に一致するものだけを
    /// 受け付ける。
    ///
    /// 削除のたびにreload()→スキャンが走るため、前のスキャンが終わらないうちに次が始まりうる。
    /// 世代を見ないと、先に始まった古いスキャンが後から完了して新しい結果を上書きしたり、
    /// まだ走行中なのに進捗表示だけ消えたりする。
    private var existenceScanGeneration = 0

    /// 実在判定を非同期に走らせる。DBから読める材料の収集だけをメインアクターで行い、
    /// 重いブックマーク解決と存在確認はメインアクターの外で実行する。
    ///
    /// 判定済みの本は対象から外す。1件あたりのブックマーク解決は、未接続の外付け/ネットワーク
    /// ボリューム上の本だと秒単位ブロックしうる。以前は削除のたびのreload()が残り全冊を
    /// 無条件に再判定していたため、1冊消すだけで全件のスキャンをやり直していた。
    private func scheduleExistenceScan(for bookIDs: [String]) {
        let pending = bookIDs.filter { existenceByBookID[$0] == nil }
        guard !pending.isEmpty else {
            isCheckingExistence = false
            return
        }
        let probes = pending.map { bookID in
            ExistenceProbe(
                bookID: bookID,
                bookmarkCandidates: [
                    metadataStore.metadata(forBookID: bookID)?.bookmarkData,
                    layoutStore.bookLayoutSettings(forBookID: bookID)?.bookmarkData,
                    bookmarkStore.anyBookmarkData(forBookID: bookID),
                    favoritesStore.anyBookmarkData(forBookID: bookID)
                ].compactMap { $0 },
                isPathCovered: folderAccess.isPathCovered(URL(fileURLWithPath: bookID))
            )
        }
        existenceScanGeneration &+= 1
        let generation = existenceScanGeneration
        isCheckingExistence = true
        // [weak self]で受けたselfを、awaitをまたぐ前にguard letで強参照へ変換しておく
        // (理由はRecentFilesStore.scheduleRefresh()の同種のコメント参照)。
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.evaluateAll(probes)
            guard let self else { return }
            await self.applyExistence(result, generation: generation)
        }
    }

    /// スキャン結果を一覧へ差し込む。自分より新しいスキャンが既に始まっている場合は破棄する。
    private func applyExistence(_ result: [String: FileExistence], generation: Int) {
        guard generation == existenceScanGeneration else { return }
        isCheckingExistence = false
        // 今回判定したぶんだけを足す(前回までの判定結果は残す。この呼び出しは一部の本しか
        // 対象にしていないため、丸ごと置き換えると判定済みの本が「確認中…」へ巻き戻る)。
        existenceByBookID.merge(result) { _, new in new }
        let resolvedByBookID = existenceByBookID
        allRows = allRows.map { row in
            let resolved = resolvedByBookID[row.bookID] ?? .unknown
            guard row.existence != resolved else { return row }
            return Row(
                bookID: row.bookID,
                fileName: row.fileName,
                existence: resolved,
                favoriteCount: row.favoriteCount,
                bookmarkCount: row.bookmarkCount,
                hasLayout: row.hasLayout,
                hasMetadata: row.hasMetadata
            )
        }
        rebuildRows()
    }

    private nonisolated static func evaluateAll(_ probes: [ExistenceProbe]) -> [String: FileExistence] {
        var result: [String: FileExistence] = [:]
        for probe in probes {
            result[probe.bookID] = evaluate(probe)
        }
        return result
    }

    /// 元のファイル/フォルダが今も存在するかどうかを判定する。
    ///
    /// 判定の順序:
    /// 1. いずれかのストアが持つセキュリティスコープ付きブックマークからURLを解決できるなら、
    ///    それを開いて確認する(最も確実。環境設定「アクセス権」でフォルダを許可していなくても
    ///    判定できる)。
    /// 2. 解決できない場合でも、環境設定「アクセス権」で許可済みのフォルダ配下のパスなら、
    ///    素のパスに対する存在確認の結果をそのまま信用してよい。
    /// 3. どちらでもない場合、存在確認が成功すれば存在する(見えている以上は確実)。
    ///    失敗した場合は「無い」のか「アクセス権が無くて見えない」のか区別できないため、
    ///    .unknownとして扱う(誤って「消えた」と表示して削除を促さないため)。
    ///
    /// `nonisolated`にしてあるのは、この判定をメインアクターの外(scheduleExistenceScanの
    /// Task.detached)で走らせるため。このプロジェクトの既定のアクター隔離はMainActorなので、
    /// 明示しないとメインアクター限定になってしまう
    /// (Services/ArchiveReading.swift冒頭のコメント参照)。
    private nonisolated static func evaluate(_ probe: ExistenceProbe) -> FileExistence {
        for data in probe.bookmarkCandidates {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            return FileManager.default.fileExists(atPath: url.path) ? .exists : .missing
        }
        let url = URL(fileURLWithPath: probe.bookID)
        if FileManager.default.fileExists(atPath: url.path) { return .exists }
        return probe.isPathCovered ? .missing : .unknown
    }

    // MARK: - 削除

    /// 指定した本に関する保存データを、種類を問わずすべて削除する。
    /// 1冊だけの削除(行の削除ボタン)と、一覧に出ている全件の削除(「表示中をすべて削除」)の
    /// どちらもこの1つの経路を通る。
    ///
    /// 読書履歴(BookReadingState)まで消すのは、これを残すと「メタデータの編集」ウインドウにも
    /// この掃除ウインドウにも、その本の行が出続けてしまうため(この機能の目的が果たせない)。
    /// お気に入りも対象に含めており、一覧のインジケータで登録の有無が分かるようにしてある
    /// (削除前に確認ダイアログで何が消えるのかを明示する。LibraryCleanupWindow参照)。
    func deleteAllData(forBookIDs bookIDs: [String]) {
        for bookID in bookIDs {
            favoritesStore.removeFavorites(forBookID: bookID)
            bookmarkStore.deleteAllBookmarks(forBookID: bookID)
            layoutStore.discardLayoutData(forBookID: bookID)
            metadataStore.delete(forBookID: bookID)
        }
        // 読書履歴だけは、本ごとではなく最後にまとめて消す(deleteReadingStates参照)。
        deleteReadingStates(forBookIDs: Set(bookIDs))
        // 消した本の実在判定の結果は用済み。残しておくと、同じパスの本が後からまた
        // 現れたときに古い判定を引き継いでしまう。
        for bookID in bookIDs {
            existenceByBookID.removeValue(forKey: bookID)
        }
        reload()
    }

    /// 読書履歴の削除。BookReadingStateは専用のストアクラスを持たず(ViewerViewModelが直接
    /// ModelContextを操作している)、ここでも同じくModelContext経由で削除する。
    ///
    /// #Predicateによる絞り込みフェッチは使わず、全件フェッチしてSwift側で選別する
    /// (LayoutStore.bookLayoutSettings(forBookID:)のコメントと同じ理由: 絞り込みフェッチが
    /// 誤って0件を返す事象を踏んでいるため、このプロジェクトでは一貫して避けている)。
    ///
    /// 全件フェッチが必要という制約があるからこそ、本1冊ごとではなく**まとめて**受け取る。
    /// 以前は1冊ごとにこのメソッドを呼んでいたため、「表示中をすべて削除」でN冊消すと
    /// 全件フェッチとsave()がN回ずつ走り、メインアクター上でN×(履歴の件数)の比較が発生していた
    /// (FavoritesStore.removeFavorites(forBookID:)が1件ずつのsave()を避けているのと同じ理由)。
    private func deleteReadingStates(forBookIDs bookIDs: Set<String>) {
        guard !bookIDs.isEmpty else { return }
        let states = (try? modelContext.fetch(FetchDescriptor<BookReadingState>())) ?? []
        let matched = states.filter { bookIDs.contains($0.bookID) }
        guard !matched.isEmpty else { return }
        for state in matched {
            modelContext.delete(state)
        }
        try? modelContext.save()
    }
}

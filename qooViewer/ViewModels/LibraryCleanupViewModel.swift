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
    enum FileExistence {
        case exists
        case missing
        /// アクセス権が無く判定できない(外付けボリュームが未接続の場合などもここに入る)。
        case unknown
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
                    existence: existence(forBookID: bookID),
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

    // MARK: - 実在判定

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
    private func existence(forBookID bookID: String) -> FileExistence {
        if let url = resolveBookmarkURL(forBookID: bookID) {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            return FileManager.default.fileExists(atPath: url.path) ? .exists : .missing
        }

        let url = URL(fileURLWithPath: bookID)
        if FileManager.default.fileExists(atPath: url.path) { return .exists }
        return folderAccess.isPathCovered(url) ? .missing : .unknown
    }

    /// この本を指すセキュリティスコープ付きブックマークを、各ストアから順に探して解決する。
    /// どのストアも持っていなければnil。
    private func resolveBookmarkURL(forBookID bookID: String) -> URL? {
        let candidates: [Data?] = [
            metadataStore.metadata(forBookID: bookID)?.bookmarkData,
            layoutStore.bookLayoutSettings(forBookID: bookID)?.bookmarkData,
            bookmarkStore.anyBookmarkData(forBookID: bookID),
            favoritesStore.anyBookmarkData(forBookID: bookID)
        ]
        for case let data? in candidates {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }
        return nil
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
            deleteReadingStates(forBookID: bookID)
        }
        reload()
    }

    /// 読書履歴の削除。BookReadingStateは専用のストアクラスを持たず(ViewerViewModelが直接
    /// ModelContextを操作している)、ここでも同じくModelContext経由で削除する。
    ///
    /// #Predicateによる絞り込みフェッチは使わず、全件フェッチしてSwift側で選別する
    /// (LayoutStore.bookLayoutSettings(forBookID:)のコメントと同じ理由: 絞り込みフェッチが
    /// 誤って0件を返す事象を踏んでいるため、このプロジェクトでは一貫して避けている)。
    private func deleteReadingStates(forBookID bookID: String) {
        let states = (try? modelContext.fetch(FetchDescriptor<BookReadingState>())) ?? []
        let matched = states.filter { $0.bookID == bookID }
        guard !matched.isEmpty else { return }
        for state in matched {
            modelContext.delete(state)
        }
        try? modelContext.save()
    }
}

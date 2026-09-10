import Combine
import Foundation

/// コレクション表紙をzipへ書き出す画面の状態(ユーザー要望 2026-09-11)。
///
/// **読み込み側(ShelfCoverImportViewModel)と対になる画面**なので、持ちものの形・並べ方・
/// 件数の数え方をそちらと揃えてある ―― 一覧・検索文字列・チェックの付いている本・
/// 結果の文言。ユーザー指摘「書き出しと読み込みでウインドウ構成がまったく違うのは気になる」を
/// 受けて、小さなダイアログから一覧ウインドウへ作り替えた際に用意したもの。
@MainActor
final class ShelfCoverExportViewModel: ObservableObject {
    /// 一覧の1行 = 書き出す表紙1枚 = 本1冊。
    struct Row: Identifiable, Sendable {
        /// bookIDがそのままid(本1冊につき表紙は高々1枚)。
        var id: String { bookID }
        let bookID: String
        /// zipの中で付くファイル名。
        let fileName: String
        /// 保管庫の中の実体。
        let sourceURL: URL
    }

    @Published private(set) var rows: [Row] = []
    @Published var searchText: String = ""
    /// チェックの付いている本。既定は全部(書き出しは「全部出す」が普通の使い方)。
    @Published var selectedBookIDs: Set<String> = []
    @Published private(set) var isExporting = false
    @Published private(set) var resultMessage: String?
    @Published private(set) var didSucceed = false
    /// 保管庫の実体が読めずに飛ばした本(ステータスバーに件数、一覧では出さない)。
    @Published private(set) var skippedBookIDs: [String] = []

    private let layoutStore: LayoutStore
    private let preferences: AppPreferences

    init(layoutStore: LayoutStore, preferences: AppPreferences) {
        self.layoutStore = layoutStore
        self.preferences = preferences
        reload()
    }

    /// 対象を集め直す(ウインドウを開いたとき・書き出したあと)。
    ///
    /// ファイル名の連番はbookID順で決まる(LayoutStore.shelfCoverArchiveEntries参照)。
    /// **一部だけを選んで書き出しても名前は変えない** ―― 一覧に出ている名前と、実際にzipへ
    /// 入る名前が食い違わないほうが分かりやすい(同じ名前の本が複数ある場合に、選ばなかった
    /// ぶんの番号が飛ぶことはある)。
    func reload() {
        rows = layoutStore.shelfCoverArchiveEntries().map {
            Row(bookID: $0.bookID, fileName: $0.fileName, sourceURL: $0.sourceURL)
        }
        selectedBookIDs = Set(rows.map(\.bookID))
    }

    var shownRows: [Row] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.fileName.localizedCaseInsensitiveContains(query)
                || $0.bookID.localizedCaseInsensitiveContains(query)
        }
    }

    var isEveryShownRowSelected: Bool {
        let shown = shownRows
        return !shown.isEmpty && shown.allSatisfy { selectedBookIDs.contains($0.bookID) }
    }

    func setAllShownSelected(_ isSelected: Bool) {
        let shown = shownRows.map(\.bookID)
        if isSelected {
            selectedBookIDs.formUnion(shown)
        } else {
            selectedBookIDs.subtract(shown)
        }
    }

    func setSelected(_ isSelected: Bool, bookID: String) {
        if isSelected {
            selectedBookIDs.insert(bookID)
        } else {
            selectedBookIDs.remove(bookID)
        }
    }

    // MARK: - 書き出し

    /// 選ばれている行をzipへ書き出す。
    ///
    /// 複製とzipの書き込みは`Task.detached`でメインアクターの外へ出す(数百件のファイル複製が
    /// 画面を止めないように。ShelfCoverArchive.writeの約束)。
    func export(to url: URL) async {
        let entries = rows
            .filter { selectedBookIDs.contains($0.bookID) }
            .map {
                ShelfCoverArchive.Entry(
                    fileName: $0.fileName, bookID: $0.bookID, sourceURL: $0.sourceURL
                )
            }
        guard !entries.isEmpty else { return }
        isExporting = true
        resultMessage = nil
        skippedBookIDs = []
        defer { isExporting = false }

        let locale = preferences.effectiveLocale
        let outcome = await Task.detached {
            Result { try ShelfCoverArchive.write(entries: entries, to: url) }
        }.value
        switch outcome {
        case .success(let result):
            didSucceed = result.skipped.isEmpty
            resultMessage = String(
                format: String(localized: "Exported %lld collection covers.", language: locale),
                Int64(result.written)
            )
            skippedBookIDs = result.skipped
        case .failure(let error):
            didSucceed = false
            resultMessage = String(
                format: String(localized: "Export failed: %@", language: locale),
                error.localizedDescription
            )
        }
    }
}

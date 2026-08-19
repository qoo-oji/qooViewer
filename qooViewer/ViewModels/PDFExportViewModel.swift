import Foundation
import SwiftUI
import Combine

/// PDF出力ウインドウのロジックを担当する。EpubExportViewModelのPDF版だが、カバー画像の
/// 選択機能は持たない(PDFExportInputのコメント、ユーザーの意向参照)。それ以外の対象一覧・
/// 出力オプション・実際の出力処理(進捗・キャンセル・同名確認・失敗集約)の構成はEPUB出力と
/// 揃えてある。
@MainActor
final class PDFExportViewModel: ObservableObject {
    /// 対象一覧の1行。EpubExportViewModel.Rowと同じ条件(pdf/epub形式以外で、レイアウトまたは
    /// ブックマーク情報を持つ本)。
    struct Row: Identifiable {
        let bookID: String
        let hasLayout: Bool
        let hasBookmarks: Bool
        let hasMetadata: Bool
        var id: String { bookID }
        var displayName: String {
            URL(fileURLWithPath: bookID).deletingPathExtension().lastPathComponent
        }
    }

    struct FailureReport: Identifiable {
        let id = UUID()
        let displayName: String
        let message: String
    }

    enum OverwriteDecision {
        case overwrite
        case skip
    }

    private struct ExportSkippedByUser: Error {}
    private struct SimpleError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published private(set) var rows: [Row] = []
    @Published var selectedBookIDs: Set<String> = []

    // MARK: - タイトル・著者名(EpubExportViewModelと同じ考え方。ファイル名/フォルダ名から
    // 推測した値を初期値にし、この画面で変更できるようにする)

    @Published var titleOverrides: [String: String] = [:]
    @Published var authorOverrides: [String: String] = [:]

    func titleBinding(forBookID bookID: String) -> Binding<String> {
        Binding(
            get: { self.titleOverrides[bookID] ?? "" },
            set: { self.titleOverrides[bookID] = $0 }
        )
    }

    func authorBinding(forBookID bookID: String) -> Binding<String> {
        Binding(
            get: { self.authorOverrides[bookID] ?? "" },
            set: { self.authorOverrides[bookID] = $0 }
        )
    }

    /// 出力オプション。除外ページを含めるかは既定OFF(EpubExportViewModel.includeExcludedPagesと
    /// 同じ既定)。連番リネームに相当する項目はPDF出力には無い(PDFExportOptions参照)。
    @Published var includeExcludedPages = false

    // 実行中の状態
    @Published private(set) var isExporting = false
    @Published private(set) var currentBookDisplayName: String?
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    private var isCancelled = false

    // 同名ファイルの確認
    @Published private(set) var pendingOverwriteBookDisplayName: String?
    private var overwriteDecisionContinuation: CheckedContinuation<OverwriteDecision, Never>?
    private var rememberedOverwriteDecision: OverwriteDecision?

    // 結果
    @Published private(set) var failures: [FailureReport] = []
    @Published private(set) var successCount = 0
    @Published private(set) var didFinish = false

    private let bookmarkStore: BookmarkStore
    private let layoutStore: LayoutStore
    private let metadataStore: BookMetadataStore

    /// この画面はWindow(id: "pdfExport")という単一インスタンスのシーンで開くため、EpubExport
    /// ViewModelと同じ理由(コメント参照)でbookmarksDidChange/layoutDataDidChange通知を
    /// 受けてreload()し直す。
    private var bookmarksChangeObserver: NSObjectProtocol?
    private var layoutDataChangeObserver: NSObjectProtocol?
    private var metadataChangeObserver: NSObjectProtocol?

    init(bookmarkStore: BookmarkStore, layoutStore: LayoutStore, metadataStore: BookMetadataStore) {
        self.bookmarkStore = bookmarkStore
        self.layoutStore = layoutStore
        self.metadataStore = metadataStore
        reload()

        // queue: .mainを指定しているため実行時には必ずMainActor上で呼ばれるが、クロージャ自体の
        // 型はMainActorに分離されていないため、コンパイラは静的にそれを保証できない
        // (EpubExportViewModel.initの同種のコメント参照)。
        bookmarksChangeObserver = NotificationCenter.default.addObserver(
            forName: .bookmarksDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
            }
        }
        layoutDataChangeObserver = NotificationCenter.default.addObserver(
            forName: .layoutDataDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
            }
        }
        metadataChangeObserver = NotificationCenter.default.addObserver(
            forName: .bookMetadataDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
            }
        }
    }

    deinit {
        if let bookmarksChangeObserver {
            NotificationCenter.default.removeObserver(bookmarksChangeObserver)
        }
        if let layoutDataChangeObserver {
            NotificationCenter.default.removeObserver(layoutDataChangeObserver)
        }
        if let metadataChangeObserver {
            NotificationCenter.default.removeObserver(metadataChangeObserver)
        }
    }

    /// 対象一覧を読み直す。EpubExportViewModel.reload()とほぼ同じ条件だが、PDF出力は
    /// カバー画像の指定機能を持たないため、カバー上書きだけを持つ本(layoutStore.
    /// coverOverrideBookIDs())まで対象に含める必要はない。
    func reload() {
        var bookIDs = layoutStore.layoutBookIDs
        bookIDs.formUnion(bookmarkStore.groups.map(\.bookID))
        // ユーザー要望: メタデータの登録がある本も対象に含める。レイアウトのみの本も
        // 引き続き対象に残す(ユーザー選択。ページ除外・並べ替えは出力に反映されるため)。
        bookIDs.formUnion(metadataStore.registeredBookIDs)
        // ユーザー要望: 元のファイル形式による制限を撤廃し、
        // zip/cbz・rar/cbr・7z/cb7・pdf・epub・フォルダのすべてを対象にする。
        let eligibleIDs = bookIDs.filter { resolveURL(forBookID: $0) != nil }
        let bookIDsWithBookmarks = Set(bookmarkStore.groups.map(\.bookID))
        rows = eligibleIDs
            .map { bookID in
                Row(
                    bookID: bookID,
                    hasLayout: layoutStore.layoutBookIDs.contains(bookID),
                    hasBookmarks: bookIDsWithBookmarks.contains(bookID),
                    hasMetadata: metadataStore.isRegistered(bookID: bookID)
                )
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        selectedBookIDs.formIntersection(Set(rows.map(\.bookID)))

        // タイトル・著者名の初期値。EpubExportViewModelと同じく、メタデータDBに登録がある本は
        // そちらを優先する(ユーザー要望)。
        for row in rows where titleOverrides[row.bookID] == nil {
            if let metadata = metadataStore.metadata(forBookID: row.bookID), !metadata.title.isEmpty {
                titleOverrides[row.bookID] = metadata.title
                authorOverrides[row.bookID] = metadata.author
                continue
            }
            let parsed = TitleAuthorFilenameParser.parse(baseName: row.displayName)
            titleOverrides[row.bookID] = parsed.title.isEmpty ? row.displayName : parsed.title
            authorOverrides[row.bookID] = parsed.author
        }
    }

    // MARK: - 一括選択

    func selectAll() { selectedBookIDs = Set(rows.map(\.bookID)) }
    func deselectAll() { selectedBookIDs.removeAll() }

    // MARK: - 空き容量チェック(EpubExportViewModelと同じ考え方)

    func totalSourceSize() -> Int64 {
        let targets = rows.filter { selectedBookIDs.contains($0.bookID) }
        var total: Int64 = 0
        for row in targets {
            guard let url = resolveURL(forBookID: row.bookID) else { continue }
            total += sourceSize(of: url)
        }
        return total
    }

    private func sourceSize(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if isDirectory.boolValue {
            var total: Int64 = 0
            if let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    if values?.isDirectory != true, let size = values?.fileSize {
                        total += Int64(size)
                    }
                }
            }
            return total
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// EpubExportViewModel.availableCapacity(at:)と同じ(volumeAvailableCapacityKeyを優先し、
    /// 取得できなければForImportantUsage版へフォールバックする理由もそちらのコメント参照)。
    func availableCapacity(at folderURL: URL) -> Int64? {
        let values = try? folderURL.resourceValues(
            forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        )
        if let plain = values?.volumeAvailableCapacity {
            return Int64(plain)
        }
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// 出力先の空き容量が合計サイズの1.2倍未満なら警告(false)。EpubExportViewModelと同じ基準。
    /// PDFは画像を再圧縮せずそのまま埋め込むため、EPUB(zip再圧縮)とおおむね近いサイズになる
    /// 想定で、同じ倍率をそのまま使う。
    func hasSufficientDiskSpace(at folderURL: URL) -> Bool {
        guard let available = availableCapacity(at: folderURL) else { return true }
        let required = Double(totalSourceSize()) * 1.2
        return Double(available) >= required
    }

    // MARK: - bookIDからのURL解決

    private func resolveURL(forBookID bookID: String) -> URL? {
        bookmarkStore.resolvedURLFromBookmarkData(forBookID: bookID) ?? layoutStore.resolvedURL(forBookID: bookID)
    }

    // MARK: - 出力実行

    func cancel() {
        isCancelled = true
    }

    func acknowledgeFinish() {
        didFinish = false
    }

    func resolveOverwrite(_ decision: OverwriteDecision, applyToRemaining: Bool) {
        if applyToRemaining {
            rememberedOverwriteDecision = decision
        }
        pendingOverwriteBookDisplayName = nil
        overwriteDecisionContinuation?.resume(returning: decision)
        overwriteDecisionContinuation = nil
    }

    private func askOverwriteDecision(for displayName: String) async -> OverwriteDecision {
        if let remembered = rememberedOverwriteDecision {
            return remembered
        }
        pendingOverwriteBookDisplayName = displayName
        return await withCheckedContinuation { continuation in
            overwriteDecisionContinuation = continuation
        }
    }

    func startExport(destinationFolder: URL) async {
        let targets = rows.filter { selectedBookIDs.contains($0.bookID) }
        guard !targets.isEmpty else { return }

        isExporting = true
        isCancelled = false
        failures = []
        successCount = 0
        completedCount = 0
        totalCount = targets.count
        rememberedOverwriteDecision = nil
        didFinish = false

        for row in targets {
            guard !isCancelled else { break }
            currentBookDisplayName = row.displayName
            do {
                try await exportOne(row: row, destinationFolder: destinationFolder)
                successCount += 1
            } catch is ExportSkippedByUser {
                // ユーザーがこの本のスキップを選んだ場合。失敗としては扱わない。
            } catch {
                failures.append(FailureReport(displayName: row.displayName, message: error.localizedDescription))
            }
            completedCount += 1
        }

        isExporting = false
        currentBookDisplayName = nil
        didFinish = true
    }

    private func exportOne(row: Row, destinationFolder: URL) async throws {
        guard let sourceURL = resolveURL(forBookID: row.bookID) else {
            throw SimpleError(message: String(localized: "The original file/folder couldn't be found."))
        }
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let book = try await BookLoader.load(from: sourceURL)
        let settings = layoutStore.bookLayoutSettings(forBookID: row.bookID)
        var overrides: [String: PageLayoutState] = [:]
        for override in layoutStore.pageOverrides(forBookID: row.bookID) {
            overrides[override.pageKey] = override.state
        }

        let pageOrderOverride = settings?.pageOrderOverride
        let excludedKeys = includeExcludedPages
            ? []
            : Set(overrides.filter { $0.value == .excluded }.map(\.key))
        let orderedKeys = EffectivePageOrder.pageKeys(
            for: book, pageOrderOverride: pageOrderOverride, excludedKeys: excludedKeys
        )

        let bookmarksSorted = bookmarkStore.bookmarks(forBookID: row.bookID).sorted { $0.pageIndex < $1.pageIndex }
        var exportBookmarks: [PDFExportBookmark] = []
        for bookmark in bookmarksSorted {
            guard orderedKeys.indices.contains(bookmark.pageIndex) else { continue }
            exportBookmarks.append(PDFExportBookmark(pageKey: orderedKeys[bookmark.pageIndex], name: bookmark.name))
        }

        let input = PDFExportInput(
            book: book,
            pageOrderOverride: pageOrderOverride,
            pageOverrides: overrides,
            bookmarks: exportBookmarks,
            titleOverride: titleOverrides[row.bookID],
            author: authorOverrides[row.bookID],
            series: metadataStore.metadata(forBookID: row.bookID)?.series,
            seriesIndex: metadataStore.metadata(forBookID: row.bookID)?.seriesIndex
        )
        let options = PDFExportOptions(includeExcludedPages: includeExcludedPages)

        let destinationFileURL = destinationFolder.appendingPathComponent("\(row.displayName).pdf")
        if FileManager.default.fileExists(atPath: destinationFileURL.path) {
            let decision = await askOverwriteDecision(for: row.displayName)
            guard decision == .overwrite else { throw ExportSkippedByUser() }
        }

        try await PDFExporter.export(input, options: options, to: destinationFileURL)
    }
}

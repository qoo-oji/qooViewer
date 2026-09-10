import Combine
import Foundation
import SwiftUI

/// zipから読み込んだコレクション表紙を、DB上の本へ結び付ける画面の状態
/// (ユーザー要望 2026-09-11)。
///
/// ■ 結び付け方は2段
/// 1. zipに`qooViewer-covers.json`(manifest)が入っていて、そのエントリ名がそのまま残っていれば、
///    そこに書かれたbookIDで**正確に**結び付ける。このアプリが書き出したzipを読み戻す場合はこれ
/// 2. manifestに無い/名前を付け替えられているエントリは、**ファイル名で照合する**。手で作った
///    zipも、意図的にリネームして別の本へ付け替える操作も、これで通る
///
/// 名前の照合はNFCへ揃えて小文字に畳んで行う(KnownBooks.matchKeyのコメント参照)。
///
/// ■ 曖昧なものは既定で取り込まない
/// 別々のフォルダに同じ名前の本があると、1つの画像に候補が複数ぶら下がる。**選ばれていない
/// 状態で出して、利用者に選ばせる** ―― 黙ってどれかに入れて、後から気づけないほうが困る。
@MainActor
final class ShelfCoverImportViewModel: ObservableObject {
    /// 一覧の1行。zipの中の画像1枚に対応する。
    struct Row: Identifiable, Sendable {
        let id = UUID()
        /// zipの中でのファイル名(表示と照合にだけ使う。ディスクのパスには絶対に流さない)。
        let entryName: String
        let data: Data
        let verdict: ImageIntegrityCheck.Verdict
        /// 名前/manifestから見つかった本。0件・1件・複数件。
        var candidates: [String]
        /// 実際に結び付ける本。nilなら取り込まない。
        var selectedBookID: String?
        /// manifestで確定したか(利用者が選び直した場合はfalseになる)。
        var isFromManifest: Bool

        /// この行を取り込めるか(画像として通っていて、行き先が決まっている)。
        var isImportable: Bool {
            guard selectedBookID != nil else { return false }
            if case .rejected = verdict { return false }
            return true
        }
    }

    @Published private(set) var rows: [Row] = []
    /// 中身を見るまでもなく飛ばしたエントリ(大きすぎる・読めない)。
    @Published private(set) var ignoredEntryNames: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isApplying = false
    @Published var searchText: String = ""
    /// 読み込み後の結果表示。
    @Published private(set) var resultMessage: String?
    @Published private(set) var didSucceed = false
    /// 読み込んだzipの名前(ウインドウ下部に出す)。
    @Published private(set) var loadedFileName: String?

    private let sources: KnownBooks.Sources
    private let preferences: AppPreferences

    init(sources: KnownBooks.Sources, preferences: AppPreferences) {
        self.sources = sources
        self.preferences = preferences
    }

    /// 検索で絞り込んだ後の行。
    var shownRows: [Row] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            row.entryName.localizedCaseInsensitiveContains(query)
                || (row.selectedBookID?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var importableCount: Int { rows.filter(\.isImportable).count }

    // MARK: - 読み込み

    func load(zipAt url: URL) async {
        isLoading = true
        resultMessage = nil
        loadedFileName = url.lastPathComponent
        defer { isLoading = false }

        // 展開・復号・検査はメインアクターの外(ShelfCoverArchive.readの約束)。
        let maxPixelSize = CollectionCoverSourceStore.maxPixelSize
        let didAccess = url.startAccessingSecurityScopedResource()
        let outcome = await Task.detached {
            Result { try ShelfCoverArchive.read(zipAt: url, maxPixelSize: maxPixelSize) }
        }.value
        if didAccess { url.stopAccessingSecurityScopedResource() }

        switch outcome {
        case .failure(let error):
            rows = []
            ignoredEntryNames = []
            didSucceed = false
            resultMessage = String(
                format: String(localized: "Couldn't read the zip file: %@", language: preferences.effectiveLocale),
                error.localizedDescription
            )
        case .success(let read):
            let known = KnownBooks.collect(from: sources)
            let index = KnownBooks.index(of: known)
            rows = read.entries.map { entry in
                // manifestが指す本が、この環境にも居るときだけ採用する
                // (別の環境で作られたzipなら、名前での照合へ落ちる)。
                if let bookID = entry.bookIDFromManifest, known.contains(bookID) {
                    return Row(
                        entryName: entry.entryName, data: entry.data, verdict: entry.verdict,
                        candidates: [bookID], selectedBookID: bookID, isFromManifest: true
                    )
                }
                let candidates = index[KnownBooks.matchKey(entry.baseName)] ?? []
                return Row(
                    entryName: entry.entryName, data: entry.data, verdict: entry.verdict,
                    candidates: candidates,
                    // 候補が1つに定まるときだけ、初めから選んでおく(型コメント参照)。
                    selectedBookID: candidates.count == 1 ? candidates[0] : nil,
                    isFromManifest: false
                )
            }
            ignoredEntryNames = read.ignored
            didSucceed = true
            resultMessage = nil
        }
    }

    func setSelection(_ bookID: String?, for rowID: Row.ID) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].selectedBookID = bookID
        rows[index].isFromManifest = false
    }

    /// 取り込める行をすべて選ぶ/すべて外す(ツールバーの「すべて選択」)。
    func setAllSelected(_ isSelected: Bool) {
        for index in rows.indices {
            if isSelected {
                // 候補が複数ある行は、どれか1つを勝手に選ばない(型コメント参照)。
                guard rows[index].candidates.count == 1 else { continue }
                rows[index].selectedBookID = rows[index].candidates[0]
            } else {
                rows[index].selectedBookID = nil
            }
        }
    }

    // MARK: - 取り込み

    /// 選ばれている行を実際にDBへ書き込む。
    func apply() async {
        isApplying = true
        defer { isApplying = false }
        let locale = preferences.effectiveLocale
        var imported = 0
        var reencoded = 0
        var failed = 0
        for row in rows where row.isImportable {
            guard let bookID = row.selectedBookID else { continue }
            do {
                let wasReencoded = try await sources.layoutStore.setShelfCoverImage(
                    forBookID: bookID, sourceURL: resolveURL(forBookID: bookID), data: row.data
                )
                imported += 1
                if wasReencoded { reencoded += 1 }
            } catch {
                failed += 1
            }
        }
        didSucceed = failed == 0
        var message = String(
            format: String(localized: "Imported %lld collection covers.", language: locale),
            Int64(imported)
        )
        if reencoded > 0 {
            message += " " + String(
                format: String(
                    localized: "%lld were larger than the limit and were reduced.", language: locale
                ), Int64(reencoded)
            )
        }
        if failed > 0 {
            message += " " + String(
                format: String(localized: "%lld couldn't be imported.", language: locale), Int64(failed)
            )
        }
        resultMessage = message
        // 取り込んだ行は選択を外す(同じzipを二度当てて同じ絵を書き直さないため)。
        for index in rows.indices { rows[index].selectedBookID = nil }
    }

    /// 行を作り直すときの本のURL(BookLayoutSettingsの行がまだ無い本のため)。
    /// 手がかりの並びはMetadataEditorViewModel.resolveURL(forBookID:)と同じ。
    private func resolveURL(forBookID bookID: String) -> URL? {
        sources.bookmarkStore.resolvedURLFromBookmarkData(forBookID: bookID)
            ?? sources.layoutStore.resolvedURL(forBookID: bookID)
            ?? sources.metadataStore.resolvedURL(forBookID: bookID)
    }

    // MARK: - 表示用

    /// 行の状態を1語で表す文字列(一覧の「状態」列)。
    func statusText(for row: Row) -> String {
        let locale = preferences.effectiveLocale
        if case .rejected(let reason) = row.verdict {
            return Self.reasonText(reason, locale: locale)
        }
        if row.candidates.isEmpty {
            return String(localized: "No matching book", language: locale)
        }
        if row.candidates.count > 1, row.selectedBookID == nil {
            return String(localized: "Several books match", language: locale)
        }
        if case .reencode(let reason) = row.verdict {
            return Self.reasonText(reason, locale: locale)
        }
        return row.isFromManifest
            ? String(localized: "Matched by the zip's own list", language: locale)
            : String(localized: "Matched by file name", language: locale)
    }

    static func reasonText(_ reason: ImageIntegrityCheck.Reason, locale: Locale) -> String {
        switch reason {
        case .unreadable:
            return String(localized: "Not a readable image", language: locale)
        case .unsupportedFormat:
            return String(localized: "Unsupported image format", language: locale)
        case .multipleFrames:
            return String(localized: "Contains more than one frame", language: locale)
        case .dimensionMismatch:
            return String(localized: "The image's size doesn't match its header", language: locale)
        case .trailingData:
            return String(localized: "Extra data follows the image", language: locale)
        case .tooLarge:
            return String(localized: "Larger than the limit — will be reduced", language: locale)
        case .formatNotVerifiable:
            return String(localized: "Will be converted to JPEG", language: locale)
        }
    }
}

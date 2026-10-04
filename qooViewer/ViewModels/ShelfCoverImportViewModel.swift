import AppKit
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
        /// zipの中でのパス。取り込むときに読み直すためだけに使う(ShelfCoverArchive.ImportedEntryの
        /// コメント参照 ―― 行は画像のバイト列を持たない)。
        let entryPath: String
        /// zipの中でのファイル名(表示と照合にだけ使う。ディスクのパスには絶対に流さない)。
        let entryName: String
        /// 読み込んだ時点のバイト数(取り込むときに読み直す量の見積もり)。
        let byteCount: Int
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
    /// 読み込んだzipの場所。取り込むときに画像を読み直す(Row.entryPathのコメント参照)。
    private var loadedZipURL: URL?

    private let sources: KnownBooks.Sources
    private let preferences: AppPreferences
    /// シークレットフォルダの一覧(呼ぶたびに今の値)。既定はアプリの一覧の写し。**テストは自分の一覧を渡す**(アプリの一覧は共有の状態)。
    private let secretFolders: () -> SecretFolderStore.Matcher

    init(
        sources: KnownBooks.Sources, preferences: AppPreferences,
        secretFolders: @escaping () -> SecretFolderStore.Matcher = { SecretFolderStore.currentAppWideMatcher }
    ) {
        self.sources = sources
        self.preferences = preferences
        self.secretFolders = secretFolders
    }

    /// 照合の母体にする本(知っている本から、シークレットフォルダの本を除いたもの)。
    ///
    /// **シークレットフォルダの本には表紙を書かない**(2026-10-04 の監査 TW-13。CLAUDE.md「a new such path must check it too」)。知っている本
    /// (`KnownBooks`)にはシークレットにする前の記録が残っているので、以前はその本も候補に出て、取り込むと表紙の行を作った。ほかの表紙の
    /// 入口は `allowsCoverChanges` で断っている。読み込むときと取り込む直前の両方で作る(開いている間にシークレットフォルダが増えても書かない)。
    private func matchableBooks() -> (books: Set<String>, secret: Set<String>) {
        let secret = secretFolders()
        let known = KnownBooks.collect(from: sources)
        guard !secret.isEmpty else { return (known, []) }
        let hidden = known.filter { secret.contains(path: $0) }
        return (known.subtracting(hidden), hidden)
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

    // MARK: - 開き直し

    /// ウインドウが出ているか(`setPresented`)。ViewModel を作るのは最初に出たときなので、「出ている」から始める。
    private var isPresented = true
    /// 閉じたときに読み込み・取り込みの途中だったので、終わってから捨てる(次に出たときに見る)。
    private var resetsWhenIdle = false

    /// ウインドウが出た・閉じた(ShelfCoverImportWindow の `auxiliaryWindowPresence` ―― 補助ウインドウの共通の決まり)。
    ///
    /// **閉じたら、読み込んだ zip と一覧・結果を捨てる**(2026-10-04 の監査 TW-22)。ViewModel は閉じても残る(`Window` シーン)ので、
    /// 以前は取り込まずに閉じた一覧が次に開いたときもそのまま出ていた。行の行き先(`selectedBookID`)は読み込んだ時点の本の bookID
    /// なので、その間に本が移動・改名されると、「取り込む」が**古いパスに表紙の行を新しく作った**(今の本には付かない)。
    /// 読み込み・取り込みの途中で閉じたときは、その処理が一覧を使い終わるまで待ち、次に出たときに捨てる(途中で開き直したなら、
    /// 続いている処理の結果を見せる)。
    func setPresented(_ presented: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented
        if presented {
            if resetsWhenIdle, !isLoading, !isApplying { reset() }
            resetsWhenIdle = false
        } else if isLoading || isApplying {
            resetsWhenIdle = true
        } else {
            reset()
        }
    }

    private func reset() {
        rows = []
        ignoredEntryNames = []
        searchText = ""
        resultMessage = nil
        didSucceed = false
        loadedFileName = nil
        loadedZipURL = nil
    }

    // MARK: - 読み込み

    func load(zipAt url: URL) async {
        // 取り込み・読み込みの最中は読み直さない(行と読み込んだ zip を差し替えると、取り込みが読み終えていない行の中身が別の zip から
        // 来る。「ファイルを選ぶ」はその間淡色だが、選ぶパネルが出ている間に始まった場合のために入口でも断る。2026-10-04 の
        // レビューの R8a-4)。
        guard !isApplying, !isLoading else { return NSSound.beep() }
        isLoading = true
        resultMessage = nil
        loadedFileName = url.lastPathComponent
        loadedZipURL = url
        defer { isLoading = false }

        // 展開・復号・検査はメインアクターの外(ShelfCoverArchive.readの約束)。ブロッキングする読み出しなので FileIO の上で
        // (CLAUDE.md の FileIO の約束。取り込み側の `readEntries` と揃えた ―― 以前は Task.detached で協調スレッドを塞いだ。
        // 2026-10-04 のレビューの R8a-4)。
        let maxPixelSize = CollectionCoverSourceStore.maxPixelSize
        let didAccess = url.startAccessingSecurityScopedResource()
        let outcome = await FileIO.perform {
            Result { try ShelfCoverArchive.read(zipAt: url, maxPixelSize: maxPixelSize) }
        }
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
            let known = matchableBooks().books
            let index = KnownBooks.index(of: known)
            rows = read.entries.map { entry in
                // manifestが指す本が、この環境にも居るときだけ採用する
                // (別の環境で作られたzipなら、名前での照合へ落ちる)。
                if let bookID = entry.bookIDFromManifest, known.contains(bookID) {
                    return Row(
                        entryPath: entry.path, entryName: entry.entryName,
                        byteCount: entry.byteCount, verdict: entry.verdict,
                        candidates: [bookID], selectedBookID: bookID, isFromManifest: true
                    )
                }
                let candidates = index[KnownBooks.matchKey(entry.baseName)] ?? []
                return Row(
                    entryPath: entry.path, entryName: entry.entryName,
                    byteCount: entry.byteCount, verdict: entry.verdict,
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
        // 取り込みの最中は行き先を変えさせない(画面でも淡色。2026-10-04 の監査 TW-19 ―― 以前は触れたうえ、終わると全行の選択が消えた)。
        guard !isApplying, let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].selectedBookID = bookID
        rows[index].isFromManifest = false
    }

    /// 取り込める行をすべて選ぶ/すべて外す(ツールバーの「すべて選択」)。
    func setAllSelected(_ isSelected: Bool) {
        guard !isApplying else { return }
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
        guard !isApplying else { return }
        isApplying = true
        // ⌘Q の確認のために数える(RunningWorkRegistry。2026-10-04 の監査 TW-18・決定 9 ―― 書き出しと保存データの読み込みは数えて
        // いたのに、こちらは数えていなかった。1 枚ずつ保存するので途中で切れても整うが、選んだ表紙の一部しか入らない)。
        let workToken = RunningWorkRegistry.forCurrentProcess?.begin()
        defer {
            isApplying = false
            if let workToken { RunningWorkRegistry.forCurrentProcess?.end(workToken) }
        }
        let locale = preferences.effectiveLocale
        var imported = 0
        var importedRowIDs: Set<Row.ID> = []
        var reencoded = 0
        var failed = 0
        // 行き先がもう「知っている本」でない行は取り込まない(2026-10-04 の監査 TW-22)。行き先は zip を読み込んだ時点の bookID
        // なので、その後で本が移動・改名される(保存データは新しいパスへ付け替わる)と、古いパスに表紙だけの行を作っていた。
        // 読み込み直せば今の本と照合し直せる。
        // シークレットフォルダの本も取り込まない(`matchableBooks` のコメント。読み込んだ後でシークレットにした本は、ここで外れて別に知らせる)。
        let (known, secretBooks) = matchableBooks()
        let importable = rows.filter(\.isImportable)
        let targets = importable.filter { $0.selectedBookID.map(known.contains) ?? false }
        let secret = importable.filter { $0.selectedBookID.map(secretBooks.contains) ?? false }.count
        let stale = importable.count - targets.count - secret
        // 画像はここで**少しずつ**読み直す(ShelfCoverArchive.readEntriesのコメント参照)。
        // 読んだぶんを取り込み終えてから次を読むので、メモリに載るのは1回ぶんだけ。
        var batches: [[Row]] = []
        var batchBytes = 0
        for row in targets {
            if batches.isEmpty || batchBytes + row.byteCount > ShelfCoverArchive.maxBatchBytes {
                batches.append([])
                batchBytes = 0
            }
            batches[batches.count - 1].append(row)
            batchBytes += row.byteCount
        }
        for batch in batches {
            let paths = batch.map(\.entryPath)
            var dataByPath: [String: Data] = [:]
            if let zipURL = loadedZipURL {
                let didAccess = zipURL.startAccessingSecurityScopedResource()
                // ブロッキングする読み出しは FileIO の上で(CLAUDE.md の FileIO の約束。以前は Task.detached で協調スレッドを塞いだ ――
                // 決定 18 と同じ根で、監査 TW-18・TW-19 を直したときに一緒に移した)。
                dataByPath = (try? await FileIO.perform {
                    try ShelfCoverArchive.readEntries(zipAt: zipURL, paths: paths)
                }) ?? [:]
                if didAccess { zipURL.stopAccessingSecurityScopedResource() }
            }
            for row in batch {
                // 読み込んだ後にzipが消された・差し替えられた場合は読めない(失敗として数える)。
                guard let bookID = row.selectedBookID, let data = dataByPath[row.entryPath] else {
                    failed += 1
                    continue
                }
                do {
                    let wasReencoded = try await sources.layoutStore.setShelfCoverImage(
                        forBookID: bookID, sourceURL: resolveURL(forBookID: bookID), data: data
                    )
                    imported += 1
                    importedRowIDs.insert(row.id)
                    if wasReencoded { reencoded += 1 }
                } catch {
                    failed += 1
                }
            }
        }
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
        if stale > 0 {
            message += " " + String(
                format: String(
                    localized: "%lld weren't imported because their books have moved since the zip was loaded. Choose the zip again to match them anew.",
                    language: locale
                ), Int64(stale)
            )
        }
        if secret > 0 {
            message += " " + String(
                format: String(localized: "%lld weren't imported because their books are in secret folders.", language: locale),
                Int64(secret)
            )
        }
        didSucceed = failed == 0 && stale == 0 && secret == 0
        resultMessage = message
        // 取り込んだ行は選択を外す(同じzipを二度当てて同じ絵を書き直さないため)。**取り込めた行だけ**(監査 TW-19 ―― 以前は全行を
        // 外し、失敗した行・取り込まなかった行の選び直しまで消えた。失敗した行はそのままもう一度押せる)。
        for index in rows.indices where importedRowIDs.contains(rows[index].id) { rows[index].selectedBookID = nil }
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

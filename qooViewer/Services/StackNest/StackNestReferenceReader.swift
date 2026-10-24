import Foundation
import StackNestViewerKit

/// StackNest の本の参照ファイル(`.stacknestbook`)の拡張子か(大文字小文字は区別しない。判定は StackNestViewerKit)。
///
/// **書庫の拡張子の一覧(`archiveExtensions`)には入れない。** あの一覧は、フォルダの本の走査・書庫の中の入れ子の書庫の判定・
/// サイドパネルの本の中身・Info.plist の書類の型の検査(scripts/ci/check-extensions.sh)が共通に見る「中にページが詰まった
/// ファイル」の集合で、参照ファイルは中身が JSON の「本の在りか」でしかない。書庫の中に紛れ込んだ参照ファイルを入れ子の書庫と
/// して開くと、中の鍵で知らない宛先へ要求を出すことになる。
///
/// 名前だけで決め、ファイルシステムには問い合わせない(`isDirectory` を渡さない `URL(fileURLWithPath:)` はフォルダかどうかを
/// 確かめに行く)。本のパスの一覧をまとめて振り分ける呼び出し側があり、応答しないボリュームの上のパスで待たせないため。
/// この名前のフォルダ(まず無い)は BookLoader ではフォルダの本として開くが、名前だけで判断する守り(書き出し・コレクション・
/// メタデータ)からは参照ファイルの本と同じく外れる(docs/10)。
nonisolated func isStackNestReferenceFile(_ path: String) -> Bool {
    StackNestBookReference.isReferenceFile(URL(fileURLWithPath: path, isDirectory: false))
}

/// 網越しのページを読む順番(StackNestRequestGate の列と、部品へ渡す優先度を決める)。
nonisolated enum RemotePageReadPriority: Sendable {
    /// いま表示するページ・利用者の操作(1 ページの書き出し・情報を見る・原寸大など)。
    case display
    /// 先読み。
    case prefetch
    /// ページ一覧・進み具合のバーのサムネイル。
    case thumbnail
    /// 寸法の下調べ(横長の判定)。
    case probe

    var lane: StackNestRequestGate.Lane { self == .display ? .display : .background }
    var kitPriority: StackNestRequestPriority { self == .display ? .display : .prefetch }
}

/// StackNest の本の参照ファイル(`.stacknestbook`)の本を読む reader。ページは StackNestViewerKit のセッションで、1 枚ずつ
/// StackNest から取る(つなぐ宛先の制限・鍵の付与・期限・リダイレクトの拒否・本文の上限・同じページの二重取得の防止・直近の
/// ページの短期キャッシュは部品が持つ)。
///
/// ■ 一覧と名前
/// `listFilePaths()` は manifest のページ数から仮の名前(`000041.jpg`。`StackNestPageNaming`)を作る。書庫のエントリのパスの役を
/// そのまま担わせるので、PageLoader・書き出しの判定は書庫の本と同じ道を通る。作るのは `makeArchiveReader(for:)` の先頭
/// (書庫の分類には入れない)と、開いた本が持つ参照から作る `PageLoader.stackNestReader(for:at:)` の 2 か所。
///
/// ■ ページは async で待つ(2026-10-18 のレビュー)
/// ページの取り寄せは `pageData(at:priority:)` で、部品の async の口を使う(スレッドを塞がない)。要求の同時数は本ごとの門
/// (`StackNestRequestGate`)が絞る。`ArchiveReading` の同期の口(`data(at:)` など)は残してあるが、応答が返るまでその場で
/// 待つ(部品の `StackNestBlockingReader`)ので、必ず `FileIO.perform` の中から呼ぶ ―― メインスレッド・`Task` の中から呼ぶと、
/// Debug では部品が誤りとして止める。今これを呼ぶのは、本を開くときの manifest の問い合わせ(BookLoader)だけ。
/// `init(referenceFileURL:)` は参照ファイルを読み(ブロックしうるので FileIO などの上で)、`init(reference:at:)` はもう読んだ参照から
/// 作る(ファイルにも触れない。PageLoader は actor の上で reader を作るのでこちら)。
///
/// ■ セッションは本ごとに 1 つ
/// 同じ参照ファイルから作る reader は、`StackNestSessions` で 1 つのセッション(ページのキャッシュと門)を使い回す。
nonisolated final class StackNestReferenceReader: RemoteArchiveReading {
    let book: StackNestSessions.Book

    /// 参照ファイルを読む(呼んだスレッドで同期に。数百バイト)。読めない・つないでよい宛先でないときは部品のエラーを投げる。
    init(referenceFileURL: URL) throws {
        book = try StackNestSessions.shared.book(forReferenceAt: referenceFileURL)
    }

    /// 読んだ参照ファイルの中身から(ファイルは読まない)。つないでよい宛先でないときは部品のエラーを投げる。
    init(reference: StackNestBookReference, at referenceFileURL: URL) throws {
        book = try StackNestSessions.shared.book(for: reference, at: referenceFileURL)
    }

    /// 開いている参照ファイルの中身。
    var reference: StackNestBookReference { book.reference }

    /// 呼んだスレッドで待つ読み手。取り消しは FileIO の旗(借りたスレッドでは `Task.isCancelled` が常に false のため)。
    private var blocking: StackNestBlockingReader {
        StackNestBlockingReader(session: book.session, isCancelled: { Cancellation.isRequestedInCurrentScope })
    }

    /// manifest(ページ数と読み方向の正。同期。FileIO の上で呼ぶ)。`refresh` が真なら覚えた manifest を使わずに StackNest へ
    /// 問い合わせる(本を開くとき。StackNest は manifest の要求で「読み込まれた」と知る)。
    func manifest(refresh: Bool = false) throws -> StackNestBookManifest {
        try recordingFailure { try blocking.manifest(refresh: refresh) }
    }

    // MARK: - 網越しの読み出し(async)

    /// 1 ページのバイト列。門の許可を取ってから部品の async の口で待つ(スレッドを塞がない)。取り消されたら `CancellationError`。
    /// 仮の名前でないもの・範囲外のページは `ArchiveReaderError.entryNotFound`。
    func pageData(at path: String, priority: RemotePageReadPriority) async throws -> Data {
        let permit = try await book.gate.acquire(priority.lane)
        defer { permit.release() }
        return try await pageDataHoldingPermit(at: path, priority: priority)
    }

    /// 門の許可を呼び出し側が持っているときの `pageData(at:priority:)`(PageLoader は背景の列の許可をデコードが終わるまで持つ)。
    func pageDataHoldingPermit(at path: String, priority: RemotePageReadPriority) async throws -> Data {
        guard let index = StackNestPageNaming.pageIndex(fromEntryName: path) else { throw ArchiveReaderError.entryNotFound }
        if let failure = book.permanentFailure { throw failure }
        do {
            let page = try await book.session.page(index, priority: priority.kitPriority)
            book.noteReceivedPage(index)
            return page.data
        } catch let error as StackNestViewerError {
            if error.code == .pageOutOfRange { throw ArchiveReaderError.entryNotFound }
            book.record(error, page: index)
            throw error
        }
    }

    // MARK: - ArchiveReading(同期。FileIO の上でだけ呼ぶ)

    func listFilePaths() throws -> [String] {
        StackNestPageNaming.entryNames(pageCount: try manifest().pageCount)
    }

    func data(at path: String) throws -> Data {
        // 仮の名前でないもの(ComicInfo.xml を探しに来た等)は、問い合わせずに「無い」。
        guard let index = StackNestPageNaming.pageIndex(fromEntryName: path) else { throw ArchiveReaderError.entryNotFound }
        do {
            let data = try recordingFailure(page: index) { try blocking.page(index).data }
            book.noteReceivedPage(index)
            return data
        } catch let error as StackNestViewerError where error.code == .pageOutOfRange {
            // 範囲外(部品は manifest を 1 度だけ読み直して確かめ、要求を出さずに返す)は、書庫の「エントリが無い」と同じ扱い。
            throw ArchiveReaderError.entryNotFound
        }
    }

    /// この本に恒久的な失敗が記録されていれば、問い合わせずにそれを投げる。部品の失敗は記録してから投げ直す
    /// (`StackNestSessions.Book.permanentFailure` のコメント)。
    private func recordingFailure<T>(page: Int? = nil, _ body: () throws -> T) throws -> T {
        if let failure = book.permanentFailure { throw failure }
        do {
            return try body()
        } catch let error as StackNestViewerError {
            book.record(error, page: page)
            throw error
        }
    }

    func entryDates(at path: String) -> (created: Date?, modified: Date?) {
        (nil, nil)
    }

    func entriesInArchiveOrder() throws -> [ArchiveEntryDescriptor] {
        try listFilePaths().map { ArchiveEntryDescriptor(path: $0, kind: .file, uncompressedSize: 0, modified: nil) }
    }

    func readEntry(at path: String, _ body: (Data) throws -> Void) throws {
        try body(data(at: path))
    }
}

extension StackNestReferenceReader {
    var requestGate: StackNestRequestGate { book.gate }
}

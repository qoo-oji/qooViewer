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
nonisolated func isStackNestReferenceFile(_ path: String) -> Bool {
    StackNestBookReference.isReferenceFile(URL(fileURLWithPath: path, isDirectory: false))
}

/// StackNest の本の参照ファイル(`.stacknestbook`)の本を読む reader。ページは StackNestViewerKit のセッションで、1 枚ずつ
/// StackNest から取る(つなぐ宛先の制限・鍵の付与・期限・リダイレクトの拒否・本文の上限・同じページの二重取得の防止・直近の
/// ページの短期キャッシュは部品が持つ)。
///
/// ■ 一覧と名前
/// `listFilePaths()` は manifest のページ数から仮の名前(`000041.jpg`。`StackNestPageNaming`)を作る。書庫のエントリのパスの役を
/// そのまま担わせるので、PageLoader・書き出しの判定は書庫の本と同じ道を通る。作るのは `makeArchiveReader(for:)` の先頭だけ
/// (書庫の分類には入れない)。
///
/// ■ ブロックする
/// どの読み出しも応答が返るまで待つ(部品の `StackNestBlockingReader`。`Task` を作らず協調スレッドを使わないで待つ)。必ず
/// `FileIO.perform` の中から呼ぶ ―― メインスレッド・`Task` の中から呼ぶと、Debug では部品が誤りとして止める。
/// `RemoteArchiveReading` の印を持つので、PageLoader はこの reader だけを `FileIO.perform` で待つ。作るとき(init)は参照ファイルを
/// 読むだけで通信しない。
///
/// ■ セッションは本ごとに 1 つ
/// 同じ参照ファイルから作る reader は、`StackNestSessions` で 1 つのセッション(ページのキャッシュ)を使い回す。
nonisolated final class StackNestReferenceReader: RemoteArchiveReading {
    let book: StackNestSessions.Book

    /// 参照ファイルを読む(呼んだスレッドで同期に。数百バイト)。読めない・つないでよい宛先でないときは部品のエラーを投げる。
    init(referenceFileURL: URL) throws {
        book = try StackNestSessions.shared.book(forReferenceAt: referenceFileURL)
    }

    /// 開いている参照ファイルの中身。
    var reference: StackNestBookReference { book.reference }

    /// 呼んだスレッドで待つ読み手。取り消しは FileIO の旗(借りたスレッドでは `Task.isCancelled` が常に false のため)。
    private var blocking: StackNestBlockingReader {
        StackNestBlockingReader(session: book.session, isCancelled: { Cancellation.isRequestedInCurrentScope })
    }

    /// manifest(ページ数と読み方向の正)。`refresh` が真なら覚えた manifest を使わずに StackNest へ問い合わせる(本を開くとき。
    /// StackNest は manifest の要求で「読み込まれた」と知る)。
    func manifest(refresh: Bool = false) throws -> StackNestBookManifest {
        try recordingFailure { try blocking.manifest(refresh: refresh) }
    }

    func listFilePaths() throws -> [String] {
        StackNestPageNaming.entryNames(pageCount: try manifest().pageCount)
    }

    func data(at path: String) throws -> Data {
        // 仮の名前でないもの(ComicInfo.xml を探しに来た等)は、問い合わせずに「無い」。
        guard let index = StackNestPageNaming.pageIndex(fromEntryName: path) else { throw ArchiveReaderError.entryNotFound }
        do {
            return try recordingFailure { try blocking.page(index).data }
        } catch let error as StackNestViewerError where error.code == .pageOutOfRange {
            // 範囲外(部品は manifest を 1 度だけ読み直して確かめ、要求を出さずに返す)は、書庫の「エントリが無い」と同じ扱い。
            throw ArchiveReaderError.entryNotFound
        }
    }

    /// この本に恒久的な失敗が記録されていれば、問い合わせずにそれを投げる。部品の失敗は記録してから投げ直す
    /// (`StackNestSessions.Book.permanentFailure` のコメント)。
    private func recordingFailure<T>(_ body: () throws -> T) throws -> T {
        if let failure = book.permanentFailure { throw failure }
        do {
            return try body()
        } catch let error as StackNestViewerError {
            book.record(error)
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

import Foundation
import StackNestViewerKit

/// StackNest の参照ファイルの本の、1 冊に 1 つのセッション(StackNestViewerKit の `StackNestBookSession`)の表。
///
/// ■ なぜ共有するか
/// `makeArchiveReader(for:)` は URL だけから reader を作り、同じ本の reader はいくつも作られる(ビューアの PageLoader・
/// ブックマークとレイアウトの編集・本を開くときの BookLoader)。reader ごとにセッションを作ると、ページの短期キャッシュと
/// 同じページの二重取得の防止が reader ごとに別になる。同じ参照ファイルから作る reader は、ここで 1 つのセッションを使い回す。
///
/// ■ 中身が変わったら作り直す
/// StackNest は開き直すたびに、同じパスへ新しい鍵・新しい中継の URL で参照ファイルを書き直す。パスだけで探すと、開いたままの
/// ビューアの古いセッション(古い鍵)を新しく開いた本に渡してしまう。読んだ中身が今のセッションの参照と同じときだけ使い回し、
/// 違えば新しいセッションで置き換える(古いセッションは、それを持つ reader とビューアが手放すまで生きる)。
///
/// ■ 持ち主
/// 表は弱い参照しか持たない。セッションを生かすのは reader(PageLoader が持つ)と、開いている本のビューア(ViewerViewModel)と
/// 書き戻しの役。最後の持ち主が手放すと、セッションは URLSession を畳む(部品の約束)。
nonisolated final class StackNestSessions: @unchecked Sendable {
    /// アプリで 1 つの表。
    static let shared = StackNestSessions()

    /// 開いている本 1 冊ぶん(セッションと、この本で起きた恒久的な失敗の記録)。
    ///
    /// `@unchecked Sendable` の根拠: 変わる状態(`failure`)は `lock` の中でだけ読み書きする。
    final class Book: @unchecked Sendable {
        let session: StackNestBookSession
        private let lock = NSLock()
        private var failure: StackNestViewerError?

        init(session: StackNestBookSession) {
            self.session = session
        }

        /// 開いている参照ファイルの中身。
        var reference: StackNestBookReference { session.reference }

        /// この本で起きた恒久的な失敗(期限切れ・認証の失敗・施錠・本が無い・宛先の制限。StackNest から開き直すまで直らない)。
        /// 起きた後は、この本のページも manifest も StackNest へ問い合わせない(reader が要求の前に見る)。
        ///
        /// 部品のセッションは恒久的な失敗の後に先読みの指示だけを止め、表示の要求は毎回出す。qooViewer はページを先読みも
        /// 寸法の読み取りもサムネイルも同じ `data(at:)` で読むので、ここで止めないと、StackNest で施錠を変えた後にページを
        /// 送るたびに、1 枚につき寸法・表示・先読み・サムネイルの要求が重なって何度も出る(すべて 403 で返る)。
        var permanentFailure: StackNestViewerError? { lock.withLock { failure } }

        /// 失敗を記録する。恒久的な失敗だけを、最初の 1 つだけ覚える(一時的な失敗は次の要求で直りうる)。
        func record(_ error: StackNestViewerError) {
            guard error.isPermanent else { return }
            lock.withLock {
                if failure == nil { failure = error }
            }
        }
    }

    private struct WeakBook {
        weak var book: Book?
    }

    private let lock = NSLock()
    /// 参照ファイルのパス(`MountTable.normalized`)→ 本。`lock` の中でだけ読み書きする。
    private var books: [String: WeakBook] = [:]
    /// 試験の差し込み: フォルダ(`MountTable.normalized`)→ そのフォルダの下の参照ファイルから作るセッションの設定。
    private var testConfigurations: [String: StackNestBookSession.Configuration] = [:]

    init() {}

    /// 参照ファイルを読み(呼んだスレッドで同期に。応答しないボリュームの上ではブロックしうるので、FileIO などブロックしてよい
    /// スレッドで呼ぶ)、その本のセッションを返す。読めないファイルは部品の `.invalidReference`・`.unsupportedVersion`。
    func book(forReferenceAt url: URL) throws -> Book {
        try book(for: StackNestBookReference.load(contentsOf: url), at: url)
    }

    /// 読んだ参照ファイルの中身から(ファイルは読まない)。中身が今のセッションと同じなら使い回し、違えば作り直す。
    /// つないでよい宛先(既定は 127.0.0.1 と ::1)でなければ、要求を出さずに `.hostNotAllowed`。
    func book(for reference: StackNestBookReference, at url: URL) throws -> Book {
        let key = MountTable.normalized(url.path)
        return try lock.withLock {
            let configuration = configurationLocked(forPath: key)
            guard configuration.allowedHosts.allows(reference.bookURL) else {
                throw StackNestViewerError(.hostNotAllowed)
            }
            if let existing = books[key]?.book, existing.reference == reference { return existing }
            let book = Book(session: StackNestBookSession(reference: reference, configuration: configuration))
            books = books.filter { $0.value.book != nil }
            books[key] = WeakBook(book: book)
            return book
        }
    }

    // MARK: - 試験の差し込み

    /// `folder` の下の参照ファイルから作るセッションに、`configuration`(部品の `StackNestStubServer.configuration()`)を使う。
    /// フォルダごとの登録なので、並行して走るほかの試験には効かない。**必ず `endUsingConfigurationForTesting(under:)` で外す。**
    func useConfigurationForTesting(_ configuration: StackNestBookSession.Configuration, under folder: URL) {
        lock.withLock { testConfigurations[MountTable.normalized(folder.path)] = configuration }
    }

    func endUsingConfigurationForTesting(under folder: URL) {
        lock.withLock { testConfigurations[MountTable.normalized(folder.path)] = nil }
    }

    private func configurationLocked(forPath path: String) -> StackNestBookSession.Configuration {
        guard !testConfigurations.isEmpty,
              let match = testConfigurations.first(where: { MountTable.path(path, isAtOrUnder: $0.key) })
        else { return StackNestBookSession.Configuration() }
        return match.value
    }
}

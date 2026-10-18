import Foundation
import StackNestViewerKit

/// StackNest の参照ファイルの本の、1 冊に 1 つのセッション(StackNestViewerKit の `StackNestBookSession`)の表。
///
/// ■ なぜ共有するか
/// 同じ本の reader はいくつも作られる(ビューアの PageLoader・ブックマークとレイアウトの編集の PageLoader)。reader ごとに
/// セッションを作ると、ページの短期キャッシュ・同じページの二重取得の防止・要求の同時数の門(`StackNestRequestGate`)が
/// reader ごとに別になる。同じ参照ファイルから作る reader は、ここで 1 つのセッションを使い回す。
/// 本を開くときの BookLoader が manifest を問い合わせるセッションは、そのあと誰も持たなければ表から消える(表は弱い参照)。
/// ビューアはその後で作り直す(manifest の控えは持ち越さないが、ページ数は参照ファイルの値で足りる)。
///
/// ■ 中身が変わったら作り直す
/// StackNest は開き直すたびに、同じパスへ新しい鍵・新しい中継の URL で参照ファイルを書き直す。パスだけで探すと、開いたままの
/// ビューアの古いセッション(古い鍵)を新しく開いた本に渡してしまう。読んだ参照の接続先と鍵(`StackNestReferenceIdentity`)が
/// 今のセッションと同じときだけ使い回し、違えば新しいセッションで置き換える(古いセッションは、それを持つ reader とビューアが
/// 手放すまで生きる)。`startPage`・題名だけが違う書き直しは同じセッションのまま(2026-10-18 のレビュー: 以前は参照の全項目で
/// 比べていて、開く位置だけ違うファイルでもビューアを作り直していた)。
///
/// ■ 持ち主
/// 表は弱い参照しか持たない。セッションを生かすのは reader(PageLoader が持つ)と、開いている本のビューア(ViewerViewModel)と
/// 書き戻しの役。最後の持ち主が手放すと、セッションは URLSession を畳む(部品の約束)。
///
/// ■ 通信の道
/// セッションの URLSession には `StackNestConnectorURLProtocol` だけを差し込む(既定の設定)。要求は XPC サービス
/// StackNestConnector が出し、アプリ本体はソケットを開かない(StackNestConnectorWire.swift)。
nonisolated final class StackNestSessions: @unchecked Sendable {
    /// アプリで 1 つの表。
    static let shared = StackNestSessions()

    /// 開いている本 1 冊ぶん(セッションと、要求の門と、この本で起きた恒久的な失敗の記録)。
    ///
    /// `@unchecked Sendable` の根拠: 変わる状態は `lock` の中でだけ読み書きする。
    final class Book: @unchecked Sendable {
        let session: StackNestBookSession
        /// 要求の同時数の門(表示の列と背景の列。StackNestRequestGate)。
        let gate = StackNestRequestGate()
        private let lock = NSLock()
        private var failure: StackNestViewerError?
        private var cacheEstimate: PageCacheEstimate
        /// 部品のページのキャッシュの大きさを届け出ている持ち主(PageLoader の `memoryOwnerID`)。2 つの PageLoader が同じ
        /// セッションを使っても、届けるのは最初の 1 つだけ(二重に数えない)。
        private var memoryReporter: UUID?

        init(session: StackNestBookSession, configuration: StackNestBookSession.Configuration) {
            self.session = session
            cacheEstimate = PageCacheEstimate(
                capacity: configuration.pageCacheCount, byteBudget: configuration.pageCacheBytes)
        }

        /// 開いている参照ファイルの中身。
        var reference: StackNestBookReference { session.reference }

        /// この本で起きた恒久的な失敗(期限切れ・認証の失敗・施錠・本が無い・宛先の制限。StackNest から開き直すまで直らない)。
        /// 起きた後は、この本のページも manifest も StackNest へ問い合わせない(reader が要求の前に見る)。
        ///
        /// 部品のセッションは恒久的な失敗の後に先読みの指示だけを止め、表示の要求は毎回出す。qooViewer はページを先読みも
        /// 寸法の読み取りもサムネイルも同じ reader で読むので、ここで止めないと、StackNest で施錠を変えた後にページを
        /// 送るたびに、1 枚につき寸法・表示・先読み・サムネイルの要求が重なって何度も出る(すべて 403 で返る)。
        var permanentFailure: StackNestViewerError? { lock.withLock { failure } }

        /// 失敗を記録する。恒久的な失敗だけを、最初の 1 つだけ覚える(一時的な失敗は次の要求で直りうる)。
        func record(_ error: StackNestViewerError) {
            guard error.isPermanent else { return }
            lock.withLock {
                if failure == nil { failure = error }
            }
        }

        /// 部品のセッションから受け取ったページ(部品のキャッシュに入ったかを、同じ決まりで見積もる)。
        func noteReceivedPage(_ index: Int, byteCount: Int) {
            lock.withLock { cacheEstimate.note(index, byteCount: byteCount) }
        }

        /// リソースモニタへ届ける項目。届けるのは最初に名乗った持ち主だけ(ほかの持ち主には空)。
        func memoryUsageItems(for ownerID: UUID) -> [MemoryUsageItem] {
            lock.withLock {
                if memoryReporter == nil { memoryReporter = ownerID }
                guard memoryReporter == ownerID else { return [] }
                return [MemoryUsageItem(
                    kind: .stackNestPages, usedBytes: cacheEstimate.totalBytes, limitBytes: cacheEstimate.byteBudget,
                    count: cacheEstimate.count)]
            }
        }

        /// 持ち主が読み込みを手放した(次の持ち主が名乗れるように)。
        func endMemoryReport(for ownerID: UUID) {
            lock.withLock { if memoryReporter == ownerID { memoryReporter = nil } }
        }
    }

    /// 部品のページのキャッシュ(StackNestViewerKit の `PageCache`: 枚数と合計の大きさで絞り、予算の半分を超えるページは
    /// 持たない)を、同じ決まりでなぞった見積もり。部品は持っている量を外へ出さないので(0.1.0)、受け取ったページから数える。
    /// 部品の側で古いものから捨てる順も同じ(使ったものを新しい側へ回す)。
    struct PageCacheEstimate {
        let capacity: Int
        let byteBudget: Int
        private var entries: [(index: Int, bytes: Int)] = []
        private(set) var totalBytes = 0

        init(capacity: Int, byteBudget: Int) {
            self.capacity = max(capacity, 0)
            self.byteBudget = max(byteBudget, 0)
        }

        var count: Int { entries.count }

        mutating func note(_ index: Int, byteCount: Int) {
            if let position = entries.firstIndex(where: { $0.index == index }) {
                totalBytes -= entries.remove(at: position).bytes
            }
            guard byteCount <= byteBudget / 2 else { return }
            entries.append((index, byteCount))
            totalBytes += byteCount
            while entries.count > capacity || totalBytes > byteBudget {
                totalBytes -= entries.removeFirst().bytes
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

    /// 読んだ参照ファイルの中身から(ファイルは読まない)。接続先と鍵が今のセッションと同じなら使い回し、違えば作り直す。
    /// つないでよい宛先(既定は 127.0.0.1 と ::1)でなければ、要求を出さずに `.hostNotAllowed`。
    func book(for reference: StackNestBookReference, at url: URL) throws -> Book {
        let key = MountTable.normalized(url.path)
        return try lock.withLock {
            let configuration = configurationLocked(forPath: key)
            guard configuration.allowedHosts.allows(reference.bookURL) else {
                throw StackNestViewerError(.hostNotAllowed)
            }
            if let existing = books[key]?.book,
               StackNestReferenceIdentity(existing.reference) == StackNestReferenceIdentity(reference)
            {
                return existing
            }
            let book = Book(
                session: StackNestBookSession(reference: reference, configuration: configuration),
                configuration: configuration)
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
        if !testConfigurations.isEmpty,
           let match = testConfigurations.first(where: { MountTable.path(path, isAtOrUnder: $0.key) })
        {
            return match.value
        }
        return Self.productionConfiguration
    }

    /// 本番の設定: 要求は XPC サービスへ回す(StackNestConnectorURLProtocol)。
    static var productionConfiguration: StackNestBookSession.Configuration {
        var configuration = StackNestBookSession.Configuration()
        configuration.makeURLSessionConfiguration = { StackNestConnectorURLProtocol.makeSessionConfiguration() }
        return configuration
    }
}

/// 参照ファイルが「同じ本の同じ受け渡し」か(セッションとビューアを使い回してよいか)を決める値。接続先・鍵・形式の版だけ。
/// 開くページ(`startPage`)・題名・ページ数・期限は、同じ受け渡しの中で書き直されても使い回しを妨げない。
/// **鍵を含むのでメモリの中だけで比べる**(保存しない・ログに出さない)。
nonisolated struct StackNestReferenceIdentity: Hashable, Sendable {
    let version: Int
    let bookURL: URL
    let token: String

    init(_ reference: StackNestBookReference) {
        version = reference.version
        bookURL = reference.bookURL
        token = reference.token
    }
}

extension StackNestReferenceIdentity: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "StackNestReferenceIdentity(version: \(version), token: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["version": version, "token": "<redacted>"], displayStyle: .struct) }
}

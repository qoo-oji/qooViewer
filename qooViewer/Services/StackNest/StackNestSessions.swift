import Foundation
import StackNestViewerKit

/// StackNest の参照ファイルの本の、1 冊に 1 つのセッション(StackNestViewerKit の `StackNestBookSession`)の表。
///
/// ■ なぜ共有するか
/// 同じ本の reader はいくつも作られる(開くときの BookLoader・ビューアの PageLoader・同じ本を開いたほかのウインドウ ―― ノーマルと
/// シークレット ―― のビューア)。reader ごとに
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
        /// 要求の同時数の門(表示の列と背景の列。StackNestRequestGate)。**接続先(StackNest の 127.0.0.1 のポート)ごとに 1 つ**で、
        /// 同じ StackNest の本どうしは共有する(2026-10-18 のレビュー: 本ごとに持つと、2 冊を開いたときに接続数(6)を超えて XPC
        /// サービスの URLSession の中で待ち、表示のページがよその本の先読みの後ろで時間切れになりえた)。
        let gate: StackNestRequestGate
        private let lock = NSLock()
        private var failure: StackNestViewerError?
        /// ページごとの一時的な失敗(そのページを次に受け取るまで)。
        private var transientFailures: [Int: StackNestViewerError] = [:]
        /// 部品のページのキャッシュの上限(リソースモニタの「上限」)。
        private let pageCacheBytes: Int
        /// 部品のページのキャッシュの大きさを届け出ている持ち主(PageLoader の `memoryOwnerID`)。2 つの PageLoader が同じ
        /// セッションを使っても、届けるのは最初の 1 つだけ(二重に数えない)。
        private var memoryReporter: UUID?
        /// このセッションで最後に読んだ manifest の、名前と番号の表(StackNestPageMap)。開いた本の表を持たない reader
        /// (サムネイル・表紙の下調べ)が、ページを読むたびに manifest を問い合わせずに番号を引くため。
        private var lastPageMap: StackNestPageMap?
        private var lastPageMapSource: (pageCount: Int, names: [String]?)?

        init(session: StackNestBookSession, configuration: StackNestBookSession.Configuration, gate: StackNestRequestGate) {
            self.session = session
            self.gate = gate
            pageCacheBytes = configuration.pageCacheBytes
        }

        /// 開いている参照ファイルの中身。
        var reference: StackNestBookReference { session.reference }

        /// このセッションで最後に読んだ manifest の名前と番号の表。まだ読んでいなければ nil。
        var knownPageMap: StackNestPageMap? { lock.withLock { lastPageMap } }

        /// 読んだ manifest を覚える(名前とページ数が前と同じなら表を作り直さない)。
        func noteManifest(_ manifest: StackNestBookManifest) {
            lock.withLock {
                if let source = lastPageMapSource, source.pageCount == manifest.pageCount, source.names == manifest.pageNames {
                    return
                }
                lastPageMapSource = (manifest.pageCount, manifest.pageNames)
                lastPageMap = StackNestPageMap(manifest)
            }
        }

        /// この本で起きた恒久的な失敗(期限切れ・認証の失敗・施錠・本が無い・宛先の制限。StackNest から開き直すまで直らない)。
        /// 起きた後は、この本のページも manifest も StackNest へ問い合わせない(reader が要求の前に見る)。
        ///
        /// 部品のセッションは恒久的な失敗の後に先読みの指示だけを止め、表示の要求は毎回出す。qooViewer はページを先読みも
        /// 寸法の読み取りもサムネイルも同じ reader で読むので、ここで止めないと、StackNest で施錠を変えた後にページを
        /// 送るたびに、1 枚につき寸法・表示・先読み・サムネイルの要求が重なって何度も出る(すべて 403 で返る)。
        var permanentFailure: StackNestViewerError? { lock.withLock { failure } }

        /// 失敗を記録する。恒久的な失敗は、最初の 1 つだけ覚える。ページの一時的な失敗(StackNest が応答しない・リモートの
        /// ライブラリにつながらない・想定外の応答)は、そのページを次に受け取るまで、ページごとに覚える ―― 次の要求で直りうるので
        /// 要求は止めないが、読めなかったページで理由を知らせるため(2026-10-19 の監査: 以前は「このページを表示できません」だけで
        /// 理由が出なかった)。ページごとなのは、見開きの相方や先読みのページが届いたことで、読めなかったページの理由を消さないため。
        /// 取り消し(`CancellationError`)はここへ来ない。
        /// - Parameter page: 失敗した要求のページ番号(StackNest の番号)。manifest・書き戻しは nil(一時的なら覚えない)。
        func record(_ error: StackNestViewerError, page: Int? = nil) {
            lock.withLock {
                if error.isPermanent {
                    if failure == nil { failure = error }
                } else if let page {
                    transientFailures[page] = error
                }
            }
        }

        /// ページ(StackNest の番号)が読めなかったときに知らせる理由: 恒久的な失敗があればそれ、無ければそのページの一時的な失敗。
        func pageFailureToShow(page: Int?) -> StackNestViewerError? {
            lock.withLock { failure ?? page.flatMap { transientFailures[$0] } }
        }

        /// 部品のセッションから受け取ったページ。届いたので、そのページの一時的な失敗は忘れる。
        func noteReceivedPage(_ index: Int) {
            lock.withLock { transientFailures[index] = nil }
        }

        /// リソースモニタへ届ける項目。届けるのは最初に名乗った持ち主だけ(ほかの持ち主には空)。量は部品が数えたもの
        /// (部品 0.2.0 の `cachedPageBytes`。受け取りの途中の本文 `bufferedResponseBytes` も足す)。0.1.0 は量を外へ出さなかったので、
        /// 受け取ったページから部品のキャッシュの決まりをなぞって見積もっていた(枚数も出していたが、部品は枚数を出さない)。
        func memoryUsageItems(for ownerID: UUID) -> [MemoryUsageItem] {
            let reports = lock.withLock { () -> Bool in
                if memoryReporter == nil { memoryReporter = ownerID }
                return memoryReporter == ownerID
            }
            guard reports else { return [] }
            return [MemoryUsageItem(
                kind: .stackNestPages, usedBytes: session.cachedPageBytes + session.bufferedResponseBytes,
                limitBytes: pageCacheBytes)]
        }

        /// 持ち主が読み込みを手放した(次の持ち主が名乗れるように)。
        func endMemoryReport(for ownerID: UUID) {
            lock.withLock { if memoryReporter == ownerID { memoryReporter = nil } }
        }
    }

    private struct WeakBook {
        weak var book: Book?
    }

    private let lock = NSLock()
    /// 参照ファイルのパス(`MountTable.normalized`)→ 本。`lock` の中でだけ読み書きする。
    private var books: [String: WeakBook] = [:]
    /// 接続先(`scheme://host:port`)→ 要求の門。`lock` の中でだけ読み書きする(接続先の数は StackNest の起動の回数ほどで、小さい)。
    private var gates: [String: StackNestRequestGate] = [:]
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
            let (configuration, testFolder) = configurationLocked(forPath: key)
            guard configuration.allowedHosts.allows(reference.bookURL) else {
                throw StackNestViewerError(.hostNotAllowed)
            }
            if let existing = books[key]?.book,
               StackNestReferenceIdentity(existing.reference) == StackNestReferenceIdentity(reference)
            {
                return existing
            }
            // 試験はフォルダごとに別の門(見立ての宛先はどの試験も同じなので、共有すると並行して走る試験が混ざる)。
            let origin = (testFolder.map { "test:\($0)|" } ?? "") + Self.origin(of: reference.bookURL)
            let gate = gates[origin] ?? StackNestRequestGate()
            gates[origin] = gate
            let book = Book(
                session: StackNestBookSession(reference: reference, configuration: configuration),
                configuration: configuration, gate: gate)
            books = books.filter { $0.value.book != nil }
            books[key] = WeakBook(book: book)
            return book
        }
    }

    /// 門を分ける単位(接続先)。
    static func origin(of url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host(percentEncoded: false)?.lowercased() ?? ""):\(url.port ?? -1)"
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

    /// その参照ファイルのセッションの設定と、試験の差し込みに当たったならそのフォルダ。
    private func configurationLocked(forPath path: String) -> (StackNestBookSession.Configuration, String?) {
        if !testConfigurations.isEmpty,
           let match = testConfigurations.first(where: { MountTable.path(path, isAtOrUnder: $0.key) })
        {
            return (match.value, match.key)
        }
        return (Self.productionConfiguration, nil)
    }

    /// 本番の設定: 要求は XPC サービスへ回す(StackNestConnectorURLProtocol)。
    static var productionConfiguration: StackNestBookSession.Configuration {
        var configuration = StackNestBookSession.Configuration()
        configuration.makeURLSessionConfiguration = { StackNestConnectorURLProtocol.makeSessionConfiguration() }
        // ページの名前(書庫の中のパス)を manifest で頼む(StackNestPageMap)。名前を知らない StackNest は問い合わせを読み飛ばす。
        configuration.requestsPageNames = true
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

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// ページサムネイル(ImageDecoder.progressBarThumbnailMaxPixelSize = 240px)を、アプリの
/// キャッシュディレクトリへ永続化しておくための保管庫。
///
/// なぜ必要か: PageLoaderのthumbnailCache(NSCache)は開いている本ごと・メモリ上だけのもので、
/// 本を閉じるかウインドウを閉じると失われる。「ブックマーク・レイアウトの編集」ウインドウは
/// 左ペインで本を選ぶたびにBookLoader.load()とPageLoaderの生成をやり直すため、同じ本を
/// 行き来するだけで毎回アーカイブを開き直してサムネイルをデコードし直していた。本体が
/// 未接続の外付け/ネットワークボリューム上にあると、これがそのまま描画待ちになる。
///
/// サムネイルはローカルの~/Library/Caches配下へ置くため、本体が低速なボリュームにあっても
/// 2回目以降はローカルディスクから読める。キャッシュディレクトリなので、容量が逼迫すれば
/// OSに削除されうるし、Time Machineのバックアップ対象にもならない(消えても再生成できる
/// 情報しか置かない)。
///
/// ただし、これは**既定では無効**である(環境設定「キャッシュ」でONにする)。
/// 速くなるぶんディスクを確実に消費する機能であり、黙って数百MBを使ってよいものではない
/// ―― 導入当初は黙って作り続けていて、ユーザーから「数日で数百MBになっていて驚いた」という
/// 報告を受けた。ON/OFFと合計上限はConfigurationとしてAppPreferencesから押し込まれる。
///
/// actorそのものは(このプロジェクトの既定のMainActor隔離とは無関係に)固有の隔離を持つため、
/// `nonisolated`の指定は不要かつ書けない。複数の本・複数のウインドウから同時に触っても安全。
actor ThumbnailDiskCache {
    static let shared = ThumbnailDiskCache()

    /// このキャッシュの振る舞いを決める設定。環境設定「キャッシュ」画面の2項目そのもので、
    /// AppPreferencesがconfigure(isEnabled:maxTotalBytes:)で押し込む。
    ///
    /// ■ なぜON/OFFできるようにしたか
    /// ユーザー報告: 数日使っただけでキャッシュフォルダが数百MBに膨れていて驚いた。
    /// 以前はこのキャッシュを黙って作り続けており(上限200MB固定、ユーザーには存在も
    /// 止める手段も見えない)、ディスクを食っていることに気づく機会が無かった。
    ///
    /// ここの初期値を「無効」にしてあるのは意図的で、configure()が届くまでのごく短い間
    /// (起動直後)に1枚でも書いてしまうことを防ぐ。設定を読む前に書き始めることはない。
    struct Configuration: Sendable, Equatable {
        var isEnabled: Bool
        var maxTotalBytes: Int
    }

    /// 上限の既定値(200MB)。240pxのPNGは1枚あたりおおむね数十KBなので、200MBでも
    /// 数千ページ分に相当する。値そのものの正典はAppPreferences側
    /// (defaultThumbnailDiskCacheLimitMB)で、ここはconfigure()が届くまでの置き値。
    private static let defaultMaxTotalBytes: Int = 200 * 1024 * 1024

    private var configuration = Configuration(
        isEnabled: false, maxTotalBytes: ThumbnailDiskCache.defaultMaxTotalBytes
    )

    /// 保存先(~/Library/Caches/<bundle id>/PageThumbnails)。作成に失敗した場合はnilになり、
    /// このキャッシュは「常にミスする」だけの無害な存在になる。
    ///
    /// `nonisolated let`にしてあるのは、読み書きの本体(デコード・PNGエンコード・ファイルI/O)を
    /// このactorの**外**で実行するため。actor上で実行すると、1枚のサムネイルの書き込みや
    /// 容量点検のあいだ、他の本・他のウインドウからの読み出しがすべて待たされる
    /// (このactorはsharedの1インスタンスしか無く、全ての本のサムネイルがここを通る)。
    /// 実際にactorの隔離が要るのは、設定(configuration)と刈り込みの帳簿(hasTrimmed /
    /// bytesWrittenSinceTrim / hasConfigured)の読み書きだけなので、そこだけをactor上に残す。
    /// サムネイルの置き場所。`nil`ならディスクキャッシュ自体が使えない(Cachesが取れなかった)。
    /// privateでないのは、リソースモニタ(StorageUsageScanner)がコンテナの容量内訳で
    /// 「サムネイルキャッシュ」を切り分けるため。書き込みはこの型だけが行う。
    nonisolated let directory: URL?
    /// 起動後に一度でも容量の刈り込みを行ったか。
    private var hasTrimmed = false
    /// 前回の刈り込み以降に書き込んだバイト数。
    ///
    /// 以前は「起動後の最初の書き込みで一度だけ」点検していた。上限が固定200MBで、
    /// そもそもユーザーからは見えない存在だったころはそれで足りたが、上限をユーザーが
    /// 決めるようになった以上、「設定した値をはっきり超えたまま次の起動まで放置される」のは
    /// 設定として破綻している。かといって書き込みのたびにディレクトリ全走査をするのは重いので、
    /// 前回の点検から一定量(trimThreshold(for:))書き足したら、もう一度点検する。
    private var bytesWrittenSinceTrim = 0
    /// configure(isEnabled:maxTotalBytes:)を一度でも受け取ったか。
    ///
    /// 起動後の最初の1回だけは、設定が「初期値と同じ」であっても必ず後始末を走らせるために
    /// 見ている。既定はOFFなので、この版を初めて起動したユーザーには
    /// 「初期値(OFF)がそのまま届く」= 値が変わらない。そこで何もしないと、
    /// **以前の版が黙って作った数百MBがいつまでも残る**ことになる。
    private var hasConfigured = false
    /// 最後に受け取ったconfigure(generation:...)の世代番号。
    ///
    /// AppPreferencesはdidSetのたびに独立した`Task`で設定を送ってくる。スライダーのドラッグ中は
    /// それが連続し、Swiftは非構造化Task同士の到着順を保証しないため、理論上「OFF→ONと
    /// 素早く切り替えたのにOFFが後から届き、UIはONのまま実体は無効化されてディレクトリも
    /// 消える」が起こりうる(監査で指摘)。世代番号が既知のものより古い呼び出しは捨てる。
    private var lastConfigurationGeneration: UInt64 = 0

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let base else {
            directory = nil
            return
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "qooViewer"
        let url = base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("PageThumbnails", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            directory = url
        } catch {
            directory = nil
        }
    }

    // MARK: - キー

    /// 1冊分の識別子。サムネイルの中身が変わりうる要素をすべて含める。
    ///
    /// - bookID: 本のパス
    /// - modificationDate / fileSize: 本体が差し替えられたら別物として扱うための指紋
    ///   (BookReadingStateのrecordedSourceModificationDate/recordedSourceFileSizeと同じ考え方)
    /// - contrastCorrectionEnabled: 補正の有無でデコード結果が変わる
    ///   (PageLoader.setContrastCorrectionEnabledがNSCacheを捨てるのと同じ理由)
    /// - maxPixelSize: サムネイルの寸法
    struct BookKey: Hashable, Sendable {
        let bookID: String
        let modificationDate: Date?
        let fileSize: Int64?
        let contrastCorrectionEnabled: Bool
        let maxPixelSize: CGFloat

        /// 本体の更新日時・サイズを実際に読み取ってキーを組み立てる。ファイル1つに対する
        /// 属性の問い合わせ1回だけなので、本を開く時点で1度呼ぶぶんには軽い。
        init(sourceURL: URL, bookID: String, contrastCorrectionEnabled: Bool, maxPixelSize: CGFloat) {
            let values = try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            self.bookID = bookID
            self.modificationDate = values?.contentModificationDate
            self.fileSize = values?.fileSize.map(Int64.init)
            self.contrastCorrectionEnabled = contrastCorrectionEnabled
            self.maxPixelSize = maxPixelSize
        }

        var fingerprint: String {
            let date = modificationDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "-"
            let size = fileSize.map(String.init) ?? "-"
            return "\(bookID)|\(date)|\(size)|\(contrastCorrectionEnabled)|\(maxPixelSize)"
        }
    }

    /// 1ページ分のファイル名。PageRef.idは本の中でのパス相当で、そのままではファイル名に
    /// できない(区切り文字・長さ・大文字小文字の扱い)ため、本の指紋と合わせてハッシュ化する。
    private static func fileName(bookKey: BookKey, pageID: String) -> String {
        let digest = SHA256.hash(data: Data("\(bookKey.fingerprint)\u{0}\(pageID)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".png"
    }

    /// ファイルの置き場所を求めるだけの純粋な計算(ディスクには触れない)。
    private nonisolated func fileURL(bookKey: BookKey, pageID: String) -> URL? {
        guard let directory else { return nil }
        let name = Self.fileName(bookKey: bookKey, pageID: pageID)
        // 1つのディレクトリにファイルが集中しないよう、先頭2文字でサブディレクトリを切る。
        let sub = directory.appendingPathComponent(String(name.prefix(2)), isDirectory: true)
        return sub.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: - 読み書き

    /// キャッシュ済みのサムネイルを返す。無ければnil。
    ///
    /// `nonisolated`: ファイルの読み出しとデコードをactorの上で行わないため(directoryの
    /// コメント参照)。`async`のまま残してあるのは、呼び出し側の`await`をそのまま有効に
    /// しておくためと、将来actorの状態が要るようになったときに呼び出し側を変えずに済むため。
    nonisolated func thumbnail(bookKey: BookKey, pageID: String) async -> CGImage? {
        // 無効のあいだはディスクに何も残っていないので読んでも無駄だが、それ以上に、
        // 読むだけでもヒットしたファイルの更新日時を触ってしまう(下記)ため、必ず先に弾く。
        guard await isEnabled,
              let url = fileURL(bookKey: bookKey, pageID: pageID),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        // 最終アクセス日時を更新しておく(trimIfNeededがこれを基準に捨てる)。書き込みに
        // 失敗しても実害は無いので結果は見ない。
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return image
    }

    /// キャッシュ済みかどうかだけを答える(読み込まず、更新日時も触らない)。
    /// 本全体の下調べ(PageLoader.scanPage)が「まだ無いページだけ作る」ために使う。
    nonisolated func hasThumbnail(bookKey: BookKey, pageID: String) async -> Bool {
        guard await isEnabled, let url = fileURL(bookKey: bookKey, pageID: pageID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// デコード済みのサムネイルを保存する。失敗しても呼び出し側には影響しない
    /// (次回もキャッシュミスになるだけ)。`nonisolated`の理由はthumbnail(bookKey:pageID:)と同じ。
    nonisolated func store(_ image: CGImage, bookKey: BookKey, pageID: String) async {
        guard await isEnabled, let url = fileURL(bookKey: bookKey, pageID: pageID) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            return
        }
        // 一度メモリ上でPNGにしてから、Data.write(options: .atomic)で書き出す。
        // CGImageDestinationCreateWithURLは対象のファイルへ直接書き込むため、読み書きを
        // actorの外へ出した今は、書き込み途中のファイルを他のタスクが読んでしまいうる。
        // .atomicは一時ファイルへ書いてからリネームするので、読み手は常に「以前の内容」か
        // 「完成した内容」のどちらかしか見ない。
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        let data = output as Data
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }

        // 容量の点検。毎回走らせるほどの頻度は不要(点検自体がディレクトリ全走査になる)なので、
        // 起動後の1回目と、そこから一定量を書き足したときだけ走らせる。
        // 「走らせてよいか」の判定はactorの状態の読み書きを伴うのでactor上で行い、実際の走査は
        // その外で行う(走査中に他のサムネイル読み出しを待たせないため)。
        guard let limit = await claimTrim(afterWriting: data.count), let directory else { return }
        Self.trimIfNeeded(in: directory, maxTotalBytes: limit)
    }

    // MARK: - 設定

    /// 環境設定「キャッシュ」の内容を受け取る。AppPreferencesが、起動時に一度と、
    /// ユーザーがトグル/スライダーを動かすたびに呼ぶ。
    ///
    /// ■ OFFにされたら「速やかに」消す
    /// これは単に書き込みを止めるだけでは足りない。この設定を入れる前のqooViewerは
    /// 黙ってキャッシュを作り続けていたので、**この版を初めて起動した時点で既に数百MBが
    /// 溜まっている**ユーザーがいる(まさにこの機能の発端になった報告)。既定はOFFなので、
    /// 起動直後にここへOFFが届き、そのぶんが自動的に片付く。
    ///
    /// ■ 上限を下げたときもその場で刈り込む
    /// 「次にサムネイルを1枚書いたら効く」では、設定した本人には効いていないように見える。
    /// 有効化された瞬間と、上限が下がった瞬間には、書き込みを待たずに点検する。
    ///
    /// - Parameter generation: 呼び出し側が単調増加させる世代番号。これより新しい設定を
    ///   既に受け取っていれば、この呼び出しは無視する(lastConfigurationGenerationのコメント参照)。
    func configure(isEnabled: Bool, maxTotalBytes: Int, generation: UInt64) {
        guard generation > lastConfigurationGeneration else { return }
        lastConfigurationGeneration = generation
        let previous = configuration
        let isFirstConfiguration = !hasConfigured
        hasConfigured = true
        configuration = Configuration(isEnabled: isEnabled, maxTotalBytes: maxTotalBytes)
        // 起動後の1回目は、値が変わっていなくても素通りさせない(hasConfiguredのコメント参照)。
        guard let directory, isFirstConfiguration || previous != configuration else { return }

        guard isEnabled else {
            hasTrimmed = false
            bytesWrittenSinceTrim = 0
            // 削除の完了は待たない(呼び出し元は環境設定のトグルで、待たせる意味が無い)。
            // 走査と削除をactorの上で行わないのは、読み書きと同じ理由(directoryのコメント参照)。
            Task.detached(priority: .utility) { Self.removeDirectory(directory) }
            return
        }

        guard isFirstConfiguration || !previous.isEnabled || maxTotalBytes < previous.maxTotalBytes
        else { return }
        // ここで点検したぶんを「起動後の1回目」として数える(直後の書き込みで全走査が
        // もう一度走らないように)。
        hasTrimmed = true
        bytesWrittenSinceTrim = 0
        Task.detached(priority: .utility) {
            Self.trimIfNeeded(in: directory, maxTotalBytes: maxTotalBytes)
        }
    }

    /// 読み書きの入口(thumbnail/store)が最初に見る値。
    /// actorの状態のうち、`nonisolated`な読み書きから参照する必要があるのはこれだけ。
    /// 設定でONかどうか(PageLoader.scanPageが「作っても捨てられるだけ」の判定に使う)。
    var isEnabled: Bool { configuration.isEnabled }

    // MARK: - 容量の管理

    /// 前回の点検からこれだけ書き足したら、もう一度点検する。
    ///
    /// 上限の5%を目安にしつつ、上下に歯止めを置いてある。上限が小さいときに全走査が
    /// 頻発しないよう最低1MB、上限が大きいときに上限からの超過が広がりすぎないよう最大16MB。
    /// 実際の使用量は「上限の8割(刈り込みの目標値)〜上限 + この値」の範囲に収まる。
    ///
    /// privateでないのは、リソースモニタの異常判定(ResourceAnomalyDetector)が「上限を
    /// 超えている」の境目をここと同じ式で引くため(刈り込みの余裕ぶんを誤報にしない)。
    nonisolated static func trimThreshold(for maxTotalBytes: Int) -> Int {
        min(max(maxTotalBytes / 20, 1024 * 1024), 16 * 1024 * 1024)
    }

    /// いま容量の点検を行ってよければ、そのときの上限を返す(不要ならnil)。
    /// 走査そのものはこの外(actorの外)で行う。
    private func claimTrim(afterWriting bytes: Int) -> Int? {
        guard configuration.isEnabled else { return nil }
        bytesWrittenSinceTrim += bytes
        let shouldTrim =
            !hasTrimmed || bytesWrittenSinceTrim >= Self.trimThreshold(for: configuration.maxTotalBytes)
        guard shouldTrim else { return nil }
        hasTrimmed = true
        bytesWrittenSinceTrim = 0
        return configuration.maxTotalBytes
    }

    /// 上限を超えていたら、最終アクセスが古いものから削除する。
    /// `nonisolated static`: ディレクトリ全走査をactorの上で行わないため。
    private nonisolated static func trimIfNeeded(in directory: URL, maxTotalBytes: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }

        var files: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            let size = values.fileSize ?? 0
            let date = values.contentModificationDate ?? .distantPast
            files.append((url, size, date))
            total += size
        }
        guard total > maxTotalBytes else { return }

        // 上限の8割まで落とす(削除のたびにすぐ上限へ戻らないようにするため)。
        let target = maxTotalBytes * 8 / 10
        for file in files.sorted(by: { $0.date < $1.date }) {
            guard total > target else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    /// いまキャッシュが使っているディスク容量。環境設定「キャッシュ」画面が、
    /// 「どれだけ溜まっているのか」を実際の数字で見せるために使う
    /// (この機能の発端が「気づかないうちに数百MB」だったので、見えること自体に意味がある)。
    ///
    /// `nonisolated`: ディレクトリ全走査をactorの上で行わないため(trimIfNeededと同じ)。
    nonisolated func totalBytes() async -> Int {
        guard let directory else { return 0 }
        return Self.totalBytes(in: directory)
    }

    /// 走査の本体。`async`な関数から直接`DirectoryEnumerator`を回すことはできない
    /// (`makeIterator`が非同期文脈では使えず、Swift 6モードではエラーになる)ため、
    /// 同期の関数へ切り出してある。trimIfNeededが同じ書き方でよいのも同じ理由。
    private nonisolated static func totalBytes(in directory: URL) -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys
        ) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }

    /// キャッシュを丸ごと捨てる(環境設定の「キャッシュ」画面と「リセット」画面から使う)。
    /// 削除が終わってから戻る(呼び出し側が使用量を測り直すため)。
    ///
    /// 削除そのものはactorの外で行う。上限は2000MBまで設定でき、数秒かかりうる削除を
    /// actorの上で行うと、そのあいだ全ての本のthumbnail()/store()が`await isEnabled`で
    /// 待たされてページ一覧のサムネイルが止まる(監査で指摘)。`await`で待つあいだは
    /// actorが解放されるので、他の読み書きは通る。
    func removeAll() async {
        guard let directory else { return }
        await Task.detached(priority: .utility) { Self.removeDirectory(directory) }.value
        hasTrimmed = false
        bytesWrittenSinceTrim = 0
    }

    /// 保存先ごと消す。
    ///
    /// 空のフォルダを作り直さないのは、OFFにしたユーザーの~/Library/Caches配下に、
    /// 使われない殻だけが残り続けるのを避けるため。store()はサブディレクトリを毎回
    /// `withIntermediateDirectories: true`で作るので、親が無くてもそのまま再開できる。
    private nonisolated static func removeDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

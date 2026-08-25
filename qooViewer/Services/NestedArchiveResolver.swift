import Foundation

/// `ArchiveLocator`が指す書庫を、必要になった時にだけ開く解決役。
///
/// ■ 何を解決したかったのか
/// 以前は、入れ子になった書庫を**本を開く瞬間にすべてディスクへ書き出し**、本を閉じるまで
/// 置き続けていた(BookLoaderが一時ファイルのURLをPageRefへ埋め込んでいた)。そのため
/// 1冊ぶんの書庫がまるごとテンポラリに常駐し(実測で8.4GBの残骸。TemporaryFileStore参照)、
/// 開く瞬間に全部の伸長と書き出しを一括で払っていた。ここはその2つを、
/// 「使う書庫だけを、使う時に、予算の範囲で開く」に置き換えるための場所。
///
/// ■ ディスクに出るかどうかは形式で決まる
/// zip/cbzはZIPFoundationがData版のAPIを持つためメモリのまま開ける(=ディスクに一切出ない)。
/// rar/7zはライブラリの公開APIがファイルパスしか受け付けないため、一時ファイルへ書き出す
/// ほかない(ArchiveKind.opensFromMemory参照)。それでも、同時に開いておくぶんだけに
/// 減るので、従来の「本1冊ぶん全部」とは桁が変わる。
///
/// ■ 一時ファイルの寿命は「readerの寿命」に一致させてある
/// 一時ファイルのURLを持つのは`TemporaryArchiveFile`(参照型)ただ1つで、削除はその`deinit`
/// だけが行う。LRUからの追い出しは辞書から参照を外すだけなので、**まだ誰かがreaderを
/// 握っている書庫のファイルが消える経路が、型の上で存在しない**。
/// 逆に、`makeArchiveReader`が途中で失敗した場合も、所有権を先に`TemporaryArchiveFile`へ
/// 渡してあるおかげで書きかけのファイルが取り残されることがない。
///
/// ■ スレッド安全性は持たせない(意図的)
/// 内部に排他制御を持たず、**所有者ごとに1インスタンス**を持つ約束にしている
/// (PageLoaderはactor隔離、BookContentsBrowserStateはMainActor隔離、BookLoaderは
/// 読み込みタスク内のローカル)。共有してロックで守る形にすると、PageLoaderが守っている
/// 「アーカイブのハンドルはactorに閉じる」という不変条件(CLAUDE.md)が崩れるため。
///
/// nonisolated: BookLoader(Task.detached内)とPageLoader(actor)の両方から使うため
/// (詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated final class NestedArchiveResolver {

    /// 使ってよい資源の上限。
    ///
    /// メモリ側だけを環境設定に出し(「キャッシュ」画面)、ディスク側と安全弁はここから導く。
    /// 上限を2つも3つもユーザーに見せても意味が伝わらないため。
    struct Limits: Sendable, Equatable {
        /// 開いたままにするreaderの総数(ルートの書庫も含む)。ファイルハンドルの上限。
        ///
        /// この上限はPageLoaderが持っていたmaxCachedReaders(=8)を引き継いだもので、
        /// 元は次の予防的な修正で入った ―― 以前は一度作ったReaderを本を閉じるまで一切
        /// 解放していなかった。通常の本(1冊=1つの書庫、またはフォルダ内の画像だけ)なら
        /// Readerはたかだか1つなので問題にならないが、BookLoaderは「フォルダの中に並んだ
        /// 大量の書庫」も「書庫の中の入れ子の書庫」も統合して1冊として開けるため、そうした
        /// 本ではページを読み進めるだけで開いたままのファイルハンドルが際限なく増えていく。
        /// 直近に使ったものだけを残す。追い出したReaderは、次にその書庫のページへ戻ったときに
        /// 作り直されるだけで動作は変わらない(通常の本では追い出し自体が起きない)。
        var maxOpenReaders: Int
        /// メモリ上に載せておく入れ子書庫の合計バイト数。
        var maxInMemoryBytes: Int
        /// 1本がこれを超えるzipはメモリに載せず一時ファイルへ倒す。
        var spillToDiskThresholdBytes: Int
        /// 一時ファイルの合計バイト数。
        var maxTemporaryBytes: Int
        /// 1本の書庫として受け付ける上限。伸長爆弾(小さな書庫が展開すると天文学的な大きさに
        /// なる細工)への安全弁で、`BookLoader.maxNestedArchiveDepth`(深さの上限)と併用する。
        var maxSingleArchiveBytes: Int

        /// 環境設定のメモリ上限から、他の値を導く。
        ///
        /// - spillToDiskThreshold: メモリ上限**そのもの**。予算に収まる書庫は載せ、収まらない
        ///   ものだけディスクへ倒す、という素直な線引き。当初はここを「上限の1/4」にして
        ///   いたが、実在する漫画の章の書庫は50〜200MBあり、既定(128MB)の1/4=32MBでは
        ///   ほとんどの章が弾かれて「zipでもディスクを使う」状態になっていた。
        /// - maxTemporaryBytes: メモリ上限の2倍(最低256MB)。ここは「章をまたいで戻ったときに
        ///   取り出し直すか」だけを決める値で、実測では75MBの章の取り出しが約60ms(ローカルSSD)
        ///   だったため、たくさん温めておく利得は小さい。ディスク使用量を減らすことの方を優先する。
        /// - maxSingleArchiveBytes: 4GB。実在する章の書庫がこの大きさになることはない。
        static func standard(inMemoryBytes: Int) -> Limits {
            let inMemory = max(0, inMemoryBytes)
            return Limits(
                maxOpenReaders: 8,
                maxInMemoryBytes: inMemory,
                spillToDiskThresholdBytes: inMemory,
                maxTemporaryBytes: max(256 * 1024 * 1024, inMemory * 2),
                maxSingleArchiveBytes: 4 * 1024 * 1024 * 1024
            )
        }
    }

    /// リソースモニタ(サイドパネル)へ出す、ある時点の状態。
    struct Statistics: Equatable, Sendable {
        var openReaderCount: Int
        var inMemoryArchiveCount: Int
        var inMemoryBytes: Int
        /// 環境設定「メモリに残しておく入れ子の書庫」。実使用量と並べて見せるための分母。
        var inMemoryLimitBytes: Int
        var temporaryArchiveCount: Int
        var temporaryBytes: Int
    }

    enum ResolveError: Error {
        /// `maxSingleArchiveBytes`を超えている(伸長爆弾よけ)。
        case archiveTooLarge
    }

    private var limits: Limits

    init(limits: Limits) {
        self.limits = limits
    }

    // MARK: - 解決

    /// `locator`が指す書庫のreaderを返す。必要なら親から取り出して開く(再帰)。
    ///
    /// 返ったreaderは呼び出し側が使い終わるまで生きている必要がある。LRUから追い出されても
    /// オブジェクト自体はARCが保つため、同期的に使い切る限り安全
    /// (PageLoader.touchReaderUsageのコメントと同じ前提)。
    func reader(for locator: ArchiveLocator) throws -> ArchiveReading {
        try open(locator).reader
    }

    /// `reader(for:)`と同じだが、開いた書庫そのものを返す。
    ///
    /// 呼び出し側が**LRUの追い出しより長く**その書庫を握りたい場合はこちらを使うこと。
    /// readerだけを持っていると、追い出された瞬間に裏付けの一時ファイルが消えてしまう
    /// (サイドパネルの本の中身ブラウザは、戻る/進むのスタックに階層を積んだままにするため
    /// こちらが要る)。
    func open(_ locator: ArchiveLocator) throws -> OpenArchive {
        try materialized(for: locator)
    }

    /// **LRUに載せずに**1回だけ開く。親のreaderは呼び出し側が既に持っている前提。
    ///
    /// 本を開くときの列挙(BookLoader.collectPages)専用。あちらは深さ優先で一度ずつ舐めて
    /// いくだけで、**同じ書庫へ二度と戻らない**ため、LRUに置く意味が無い。それどころか置くと
    /// 害がある ―― 章ごとに書庫化された本では、読み終えた章がバイト予算いっぱいまで
    /// 居座り続け、列挙のあいだじゅう数百MBの一時ファイルがディスクに載ることになる。
    ///
    /// 返した`OpenArchive`を呼び出し側が手放した時点で、裏付けの一時ファイルも消える。
    /// つまり列挙中にディスクへ載るのは「いま潜っている枝の祖先ぶん」だけになる
    /// (通常の本では1本)。親を辿り直さないので、祖先が追い出されて再展開される事故も起きない。
    func openTransient(_ locator: ArchiveLocator, parentReader: ArchiveReading) throws -> OpenArchive {
        guard let entryPath = locator.entryPathInParent else {
            // 入れ子ではない = ディスク上の実ファイル。取り出しは要らない。
            return try openRoot(locator.rootURL)
        }
        return try materialize(entryPath: entryPath, from: parentReader)
    }

    /// ディスク上の書庫をそのまま開く(LRUに載せない)。列挙の起点用。
    func openRoot(_ url: URL) throws -> OpenArchive {
        try Self.openRootArchive(at: url)
    }

    /// ディスク上の書庫を、解決役のインスタンスを持たずに開く。
    ///
    /// 入れ子でない書庫にはLRUも予算も一時ファイルも関係しない ―― ただ開くだけ ―― ので、
    /// 起点となる1本のためだけにインスタンスを用意しなくて済むようにしてある
    /// (BookContentsBrowserStateが本のルート書庫を開くときに使う)。
    static func openRootArchive(at url: URL) throws -> OpenArchive {
        OpenArchive(
            reader: try makeArchiveReader(for: url),
            byteCount: 0, storage: .rootFile, temporaryFile: nil
        )
    }

    /// 「新しい本として開く」など、**このResolverの寿命とは切り離された実ファイル**が要る場面
    /// のために、locatorが指す書庫を独立した一時ファイルへ書き出してURLを返す。
    ///
    /// 内部のLRUが持っている一時ファイルをそのまま渡さないのは、あちらの寿命がLRUの追い出しと
    /// `purgeAll()`に握られており、受け取った側がいつまで使うか分からないため。削除の責任は
    /// 呼び出し側が持つ(BookContentsBrowserState.temporaryFileURLs)。
    func materializeToIndependentFile(_ locator: ArchiveLocator) throws -> URL {
        guard let parentLocator = locator.parent, let entryPath = locator.entryPathInParent else {
            // 入れ子ではない = 既にディスク上の実ファイル。書き出す必要が無い。
            return locator.rootURL
        }
        let parent = try materialized(for: parentLocator)
        let url = TemporaryFileStore.makeFileURL(extension: (entryPath as NSString).pathExtension)
        do {
            // 逐次書き出し。ここも数百MBの書庫を丸ごとメモリに載せない
            // (ArchiveReading.extract(at:to:)のコメント参照)。
            try parent.reader.extract(at: entryPath, to: url)
        } catch {
            // 書きかけを残さない。ここは所有者が呼び出し側に移る前なので自分で片付ける。
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    /// 今開いているものをすべて手放す(本を閉じた・別の本へ移った)。
    ///
    /// ARCのdeinit任せにしないのは、SwiftUIが旧世代のビューを抱えていると解放が遅れ、
    /// その間ずっと一時ファイルとファイルハンドルが残るため
    /// (PageLoader.releaseAllResourcesの型コメントと同じ理由)。
    func purgeAll() {
        entries.removeAll()
        usageOrder.removeAll()
    }

    /// 環境設定の変更を反映する。縮んだぶんはその場で追い出す。
    func setLimits(_ newLimits: Limits) {
        limits = newLimits
        evictIfNeeded()
    }

    func statistics() -> Statistics {
        var stats = Statistics(
            openReaderCount: entries.count, inMemoryArchiveCount: 0, inMemoryBytes: 0,
            inMemoryLimitBytes: limits.maxInMemoryBytes, temporaryArchiveCount: 0, temporaryBytes: 0
        )
        for entry in entries.values {
            switch entry.storage {
            case .rootFile:
                break
            case .inMemory:
                stats.inMemoryArchiveCount += 1
                stats.inMemoryBytes += entry.byteCount
            case .temporaryFile:
                stats.temporaryArchiveCount += 1
                stats.temporaryBytes += entry.byteCount
            }
        }
        return stats
    }

    // MARK: - 内部

    private var entries: [ArchiveLocator: OpenArchive] = [:]
    /// 使用順(古い順)。`maxOpenReaders`と各バイト予算を超えたぶんを先頭から追い出す。
    private var usageOrder: [ArchiveLocator] = []
    /// 再帰の途中かどうか。追い出しは再帰が完全に終わってから1度だけ行う ―― 途中で行うと、
    /// たった今解決したばかりの親を消してしまい、すぐに開き直す無駄が生まれるため
    /// (正しさの問題ではない。親は上位のフレームがローカル変数で強参照している)。
    private var resolutionDepth = 0

    private func materialized(for locator: ArchiveLocator) throws -> OpenArchive {
        if let existing = entries[locator] {
            touch(locator)
            return existing
        }

        resolutionDepth += 1
        defer {
            resolutionDepth -= 1
            if resolutionDepth == 0 { evictIfNeeded() }
        }

        let created: OpenArchive
        if let parentLocator = locator.parent, let entryPath = locator.entryPathInParent {
            // 親を先に解決し、ローカル変数で強参照したまま取り出す。
            let parent = try materialized(for: parentLocator)
            created = try materialize(entryPath: entryPath, from: parent.reader)
        } else {
            created = OpenArchive(
                reader: try makeArchiveReader(for: locator.rootURL),
                byteCount: 0, storage: .rootFile, temporaryFile: nil
            )
        }
        entries[locator] = created
        touch(locator)
        return created
    }

    /// 親から`entryPath`を取り出して、開ける形にする。
    ///
    /// 行き先(メモリか一時ファイルか)は**取り出す前**に決める。展開後のサイズは索引から
    /// 追加のI/O無しで分かるため(ArchiveReading.entryUncompressedSize)、
    /// 「まず全部メモリに読んでから大きすぎたと気づく」を避けられる。サイズを答えられない
    /// 実装が将来現れた場合は、安全側=一時ファイルへ倒す。
    fileprivate func materialize(entryPath: String, from parentReader: ArchiveReading) throws -> OpenArchive {
        guard let kind = archiveKind(forFileName: entryPath) else {
            throw ArchiveReaderError.cannotOpen
        }
        let declaredSize = parentReader.entryUncompressedSize(at: entryPath)
        if let declaredSize, declaredSize > Int64(limits.maxSingleArchiveBytes) {
            throw ResolveError.archiveTooLarge
        }

        let fitsInMemory = kind.opensFromMemory
            && declaredSize.map { $0 <= Int64(limits.spillToDiskThresholdBytes) } == true

        if fitsInMemory {
            // data(at:)は新しいDataを組み立てて返すため、親のバッファを巻き添えで
            // 保持することはない(ZipArchiveReader.init(data:)のコメント参照)。
            let data = try parentReader.data(at: entryPath)
            return OpenArchive(
                reader: try ZipArchiveReader(data: data),
                byteCount: data.count, storage: .inMemory, temporaryFile: nil
            )
        }

        // 一時ファイル経路。**書き出しより先に所有権をTemporaryArchiveFileへ渡す**ことで、
        // この後どこで失敗しても書きかけのファイルが取り残されない。
        let temporaryFile = TemporaryArchiveFile(
            url: TemporaryFileStore.makeFileURL(extension: (entryPath as NSString).pathExtension)
        )
        // 親から一時ファイルへ**逐次**書き出す。data(at:)で受け取ってから書くと、その書庫の
        // 全バイトが一度メモリに載ってしまう(ArchiveReading.extract(at:to:)のコメント参照)。
        try parentReader.extract(at: entryPath, to: temporaryFile.url)
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: temporaryFile.url.path)[.size]
            as? NSNumber)?.intValue ?? Int(declaredSize ?? 0)
        // 索引が申告したサイズを信じて書き出した後、実際の大きさをもう一度確かめる
        // (壊れた・細工された書庫では索引が実際と食い違いうる。サイズを答えられない形式では
        //  ここが唯一の歯止めになる)。ここで投げても、一時ファイルの所有権は既に
        // temporaryFileが持っているので、書きかけのファイルはこの関数を抜けた時点で消える。
        guard byteCount <= limits.maxSingleArchiveBytes else { throw ResolveError.archiveTooLarge }
        return OpenArchive(
            reader: try makeArchiveReader(kind: kind, url: temporaryFile.url),
            byteCount: byteCount, storage: .temporaryFile, temporaryFile: temporaryFile
        )
    }

    private func touch(_ locator: ArchiveLocator) {
        if let existing = usageOrder.firstIndex(of: locator) {
            usageOrder.remove(at: existing)
        }
        usageOrder.append(locator)
    }

    /// 予算を超えているあいだ、最後に使ったもの1つを残して古い順に追い出す。
    ///
    /// 1つは必ず残すのは、1本だけで予算を超える書庫(上限より大きい章)を開いたときに、
    /// 入れた直後に自分自身を追い出して無限に開き直す状態を避けるため
    /// (PagePixelCacheが「1枚が上限より大きい場合はその1枚を残す」としているのと同じ考え方)。
    private func evictIfNeeded() {
        while usageOrder.count > 1, isOverBudget() {
            let victim = usageOrder.removeFirst()
            entries[victim] = nil
        }
    }

    private func isOverBudget() -> Bool {
        if entries.count > limits.maxOpenReaders { return true }
        let stats = statistics()
        return stats.inMemoryBytes > limits.maxInMemoryBytes
            || stats.temporaryBytes > limits.maxTemporaryBytes
    }
}

/// 開いた状態の書庫1つと、その裏付け(ルートの実ファイル / メモリ上のバイト列 / 一時ファイル)。
///
/// **このオブジェクトを手放すと、裏付けの一時ファイルも消える。** 逆に、LRUから追い出されても
/// 誰かがこれを握っているあいだは消えない。一時ファイルの寿命をこの1点に集約してあるおかげで、
/// 「読んでいる最中の書庫のファイルが消える」という事故が型の上で起こらない。
nonisolated final class OpenArchive {
    enum Storage {
        /// ディスク上の実ファイルをそのまま開いたもの(materializeしていない)。
        case rootFile
        /// メモリ上のバイト列から開いたもの(zip/cbzのみ)。
        case inMemory
        /// 一時ファイルへ書き出してから開いたもの(rar/7z、および大きすぎるzip)。
        case temporaryFile
    }

    let reader: ArchiveReading
    /// メモリ経路ならメモリ上のバイト数、一時ファイル経路ならファイルのバイト数。ルートは0。
    let byteCount: Int
    let storage: Storage
    /// 非nilのとき、このオブジェクトが一時ファイルの唯一の所有者
    /// (削除はTemporaryArchiveFile.deinitが行う)。
    private let temporaryFile: TemporaryArchiveFile?

    fileprivate init(reader: ArchiveReading, byteCount: Int, storage: Storage, temporaryFile: TemporaryArchiveFile?) {
        self.reader = reader
        self.byteCount = byteCount
        self.storage = storage
        self.temporaryFile = temporaryFile
    }
}

/// 一時ファイル1つの所有権。**このアプリで一時ファイルを削除するのはここだけ**
/// (起動時・終了時にまとめて掃除するTemporaryFileStoreの網を除く)。
///
/// 参照型にしてあるのは、削除を「誰かが明示的に消す」ではなく「最後の持ち主が居なくなる」に
/// 紐づけるため。LRUからの追い出しは辞書の参照を外すだけになり、まだ読んでいる最中の
/// 書庫のファイルを消してしまう経路が存在しなくなる。
/// nonisolated: このプロジェクトはXcodeの既定で「Default Actor Isolation = MainActor」に
/// なっており、注釈の無い型は暗黙的にMainActor専用になる。ここはnonisolatedなResolverから
/// 生成・破棄されるため明示する(ArchiveReading.swift冒頭のコメント参照)。
nonisolated private final class TemporaryArchiveFile {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    deinit {
        // deinitがどのスレッド/アクターで呼ばれるかは保証されないため、ファイルI/Oを
        // Task.detachedへ逃がす。アプリの終了で
        // このTaskが走らなかった場合は、次回起動時のTemporaryFileStoreの掃除が拾う。
        let url = self.url
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

import Foundation

/// 書庫の reader が読むバイト列の出所(位置を指定して読む)。
///
/// ネットワークボリューム上の書庫は `StagedFileSource`(下)を通して読む。zip は自前の `CentralDirectoryZipReader` が、
/// 7z・rar はフォークの「呼び出し側の関数から読む」入口が、これだけを通して読む。ローカルの書庫はこれを使わず、
/// 従来どおり各ライブラリがファイルを直接開く(docs/plans/network-volume-study.md)。
///
/// nonisolated: BookLoader(Task.detached)・PageLoader(actor)の reader から呼ばれる。
nonisolated protocol RandomAccessSource: AnyObject {
    var size: UInt64 { get }
    /// `offset` から最大 `count` バイト。ファイルの終わりでは短くなる(終わりより後ろなら空)。
    func read(at offset: UInt64, count: Int) throws -> Data
}

nonisolated enum RandomAccessSourceError: Error {
    case cannotOpen
    case readFailed(Int32)
    /// 読み込み層を止めた後の読み(本を閉じた・中止した)。
    case stopped
}

/// ローカルのファイルを pread で読む出所(テスト、および読み込み層を通さないときの比較用)。
nonisolated final class LocalFileSource: RandomAccessSource {
    let size: UInt64
    private let fd: Int32

    init(url: URL) throws {
        fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw RandomAccessSourceError.cannotOpen }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw RandomAccessSourceError.cannotOpen
        }
        size = UInt64(st.st_size)
    }

    deinit { close(fd) }

    func read(at offset: UInt64, count: Int) throws -> Data {
        try preadFully(fd: fd, offset: offset, count: count, size: size)
    }
}

/// `offset` から `count` バイト(ファイルの終わりで短くなる)を、短い読みを繰り返して読み切る。
nonisolated func preadFully(fd: Int32, offset: UInt64, count: Int, size: UInt64) throws -> Data {
    guard count > 0, offset < size else { return Data() }
    let length = Int(min(UInt64(count), size - offset))
    var data = Data(count: length)
    var done = 0
    try data.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        while done < length {
            let n = pread(fd, base + done, length - done, off_t(offset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw RandomAccessSourceError.readFailed(errno)
            }
            if n == 0 { break }
            done += n
        }
    }
    if done < length { data.removeSubrange(done..<length) }
    return data
}

/// ネットワークボリューム上のファイルを、手元の一時ファイルへ写しながら読む「読み込み層」。
///
/// ■ なぜ要るのか(docs/plans/network-volume-study.md)
/// ネットワーク越しの読みは 1 回ごとに往復の待ちがかかる。書庫のライブラリは索引・ヘッダーを小さく飛び飛びに読み
/// (ZIPFoundation の一覧はエントリごとにローカルヘッダーを、unrar はファイルごとのヘッダーを「7 バイト+残り」で)、
/// 中身も 16〜256KB ずつ読むので、200 ページの本で数百〜数千回の往復になっていた。ここでは
/// - 足りない部分だけを**連続する並びごとに 1 回の大きな読み**で取り寄せ、手元に貯めて二度と取りに行かない、
/// - 順に読み進める読み(伸長)には先回りして大きく取り寄せ、
/// - 手が空いたら残りを順に取り寄せる(本を開いたときだけ。`startsBackgroundFill`)、
/// ことで、往復の数を「必要な飛び地の数」まで減らし、転送は帯域いっぱいの大きな読みにまとめる。全部揃えば、以後は
/// ローカルディスクと同じ速さになる。
///
/// ■ ブロックと読み方
/// - ファイルを `blockSize`(64KB)のブロックに分け、手元にあるブロックを覚える。飛び飛びの小さな読み(ヘッダー)は
///   64KB 単位で取る(1MB 単位だと、Quick Open の無い rar の一覧がファイル丸ごとの転送と同じ時間になった)。
/// - 前景(reader)の読みが前の読みの続きなら、**その順読みで実際に読んだ量**まで先読みする(上限 `readAhead`)。
///   呼び出しの回数で数えると、unrar の「7 バイト+残り」のような小さな続き読みのたびに大きく先読みして、一覧が
///   4.6 秒になった(量で数えて 1.7 秒。5ms・40MB/s の模擬、2026-09-24)。
/// - 同じブロックを 2 つのスレッドが同時に取りに行かない(取り寄せ中なら終わるのを待つ)。
///
/// ■ 裏の取り寄せ(`startsBackgroundFill`)
/// - 最初の前景の読みが済むまで始めない(開いた直後の索引の読みを邪魔しない)。
/// - 前景が**飛び飛びに**取り寄せている間(索引・ヘッダーを辿る間)は譲る。取り寄せ中のブロックを前景が待っている
///   ことも前景の需要に数える(数えないと、裏が 2MB ずつ取る後ろで前景のヘッダーの読みが待たされた)。
/// - 前景が**順に流れている**(先読みの幅が上限に達した)間は、その先を取りに行く。7z の伸長(CPU)と転送が重なる
///   (cb7 の通読: 16 秒 → 5.5 秒。ローカルは 4.9 秒)。
/// - 取り寄せる位置は、前景が最後に読んだ位置の先から。
///
/// ■ 寿命
/// - 一時ファイルは `TemporaryFileStore` のセッションのディレクトリ(異常終了しても次の起動で消える)。この層が
///   解放されたときに消す。**読み終えた写しは残さない**(利用者の判断 2026-09-24)。
/// - 全部揃ったらネットワーク上のファイルの記述子を閉じる(SMB のハンドルを握り続けない)。
/// - 裏の取り寄せのスレッドはこの層を**1 回の取り寄せの間だけ**強参照する。利用者が全員手放せば、次の区切りで止まる。
nonisolated final class StagedFileSource: RandomAccessSource, @unchecked Sendable {
    let size: UInt64
    let blockSize: Int
    private let readAhead: Int
    private let backgroundChunk: Int
    /// 手元の一時ファイルの記述子。**最初に取り寄せるときに作る**(一覧の絵のように、開いて索引を読むだけの利用でも
    /// 取り寄せは要るが、開いてすぐ閉じる reader の分まで先に作らない)。`lock` で守る。
    private var cacheFD: Int32 = -1
    /// 手元の一時ファイル(テストが後片付けを確かめるため internal)。
    let cacheURL: URL

    /// 以下は `lock` で守る。
    private let lock = NSCondition()
    private var remoteFD: Int32
    private var present: [Bool]
    private var presentCount = 0
    private var fetching: Set<Int> = []
    private var lastForegroundEnd: UInt64 = .max
    /// 先読みの幅(この順読みの並びで読んだ量。上限 `readAhead`)。飛び飛びの読みで 0 に戻る。
    private var sequentialWindow = 0
    private var sequentialRunBytes = 0
    /// 前景がネットワークから取り寄せている最中の数。
    private var foregroundFetching = 0
    /// 前景が、他のスレッドの取り寄せ中のブロックを待っている数。
    private var foregroundWaiting = 0
    private var lastForegroundFetchEnd = Date.distantPast
    private var hasForegroundRead = false
    private var stopped = false
    private var backgroundStarted = false

    /// 裏が前景に譲ったあと、取り寄せを再開するまでの間(飛び飛びの読みが続く間は割り込まない)。
    private static let idleGap: TimeInterval = 0.02
    /// 一度に取り寄せる並びの上限(前景)。
    private static let maxForegroundRun = 16 << 20

    /// 前景・裏それぞれがネットワークから取り寄せた回数(テスト・計測用)。
    private(set) var foregroundFetchCount = 0
    private(set) var backgroundFetchCount = 0

    init(url: URL, blockSize: Int = 64 << 10, readAhead: Int = 4 << 20, backgroundChunk: Int = 2 << 20,
         cacheDirectory: URL? = nil) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw RandomAccessSourceError.cannotOpen }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw RandomAccessSourceError.cannotOpen
        }
        remoteFD = fd
        size = UInt64(st.st_size)
        self.blockSize = blockSize
        self.readAhead = readAhead
        self.backgroundChunk = max(blockSize, backgroundChunk)
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            cacheURL = cacheDirectory.appendingPathComponent(UUID().uuidString + ".staged")
        } else {
            cacheURL = TemporaryFileStore.makeFileURL(extension: "staged")
        }
        let blocks = Int((size + UInt64(blockSize) - 1) / UInt64(blockSize))
        present = Array(repeating: false, count: blocks)
    }

    deinit {
        if remoteFD >= 0 { close(remoteFD) }
        if cacheFD >= 0 {
            close(cacheFD)
            unlink(cacheURL.path)
        }
    }

    /// 手元の一時ファイル(無ければ作る)。`lock` を持って呼ぶ。
    private func cacheDescriptor() throws -> Int32 {
        if cacheFD >= 0 { return cacheFD }
        let fd = open(cacheURL.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RandomAccessSourceError.readFailed(errno) }
        // 大きさだけ先に決める(APFS ではスパースになり、書いたブロックの分しか場所を取らない)。
        ftruncate(fd, off_t(size))
        cacheFD = fd
        return fd
    }

    var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return presentCount == present.count
    }

    var fractionComplete: Double {
        lock.lock(); defer { lock.unlock() }
        return present.isEmpty ? 1 : Double(presentCount) / Double(present.count)
    }

    /// 取り寄せをやめる。以後、手元に無い部分の読みは失敗する(本を閉じた後など)。
    func stop() {
        lock.lock()
        stopped = true
        lock.broadcast()
        lock.unlock()
    }

    /// 残りを裏で取り寄せ始める(本をビューアで開いたときだけ。何度呼んでもよい)。
    func startBackgroundFill() {
        lock.lock()
        let alreadyStarted = backgroundStarted
        backgroundStarted = true
        lock.unlock()
        guard !alreadyStarted else { return }
        let thread = Thread { [weak self] in
            // 1 回の取り寄せの間だけ強参照する(利用者が全員手放したら、次の区切りで止まる)。
            while let source = self, source.backgroundStep() {}
        }
        thread.name = "qooViewer.StagedFileSource"
        thread.qualityOfService = .utility
        thread.start()
    }

    // MARK: - 前景の読み

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0, offset < size else { return Data() }
        let end = min(size, offset + UInt64(count))
        let firstBlock = block(containing: offset)
        let lastBlock = block(containing: end - 1)

        lock.lock()
        if stopped, !(firstBlock...lastBlock).allSatisfy({ present[$0] }) {
            lock.unlock()
            throw RandomAccessSourceError.stopped
        }
        var fetchLast = lastBlock
        if offset == lastForegroundEnd {
            sequentialRunBytes += Int(end - offset)
            sequentialWindow = min(readAhead, sequentialRunBytes)
            if sequentialWindow >= blockSize {
                fetchLast = min(present.count - 1, block(containing: end - 1 + UInt64(sequentialWindow)))
            }
        } else {
            sequentialRunBytes = Int(end - offset)
            sequentialWindow = 0
        }
        lastForegroundEnd = end
        lock.unlock()

        defer {
            lock.lock()
            hasForegroundRead = true
            lock.broadcast()
            lock.unlock()
        }
        try ensure(blocks: firstBlock...fetchLast, required: firstBlock...lastBlock, isForeground: true)
        lock.lock()
        let fd = cacheFD
        lock.unlock()
        // 揃ったブロックがあるなら一時ファイルはある(作ってから取り寄せる)。
        return try preadFully(fd: fd, offset: offset, count: Int(end - offset), size: size)
    }

    private func block(containing offset: UInt64) -> Int {
        Int(offset / UInt64(blockSize))
    }

    /// `blocks` のうち無いものを取り寄せる。`required` の範囲は、他のスレッドが取り寄せ中なら終わるのを待つ。
    /// 先読みの部分(`blocks` のうち `required` の外)は、誰かが取り寄せ中なら待たない。
    private func ensure(blocks: ClosedRange<Int>, required: ClosedRange<Int>, isForeground: Bool) throws {
        let maxRun = max(1, (isForeground ? Self.maxForegroundRun : backgroundChunk) / blockSize)
        while true {
            lock.lock()
            if stopped {
                let missing = required.contains { !present[$0] }
                lock.unlock()
                if missing { throw RandomAccessSourceError.stopped }
                return
            }
            // 自分が取りに行く並び(無く、誰も取りに行っていないブロック)を先頭から 1 つ。
            var run: ClosedRange<Int>?
            var index = blocks.lowerBound
            while index <= blocks.upperBound {
                if !present[index] && !fetching.contains(index) {
                    var last = index
                    while last + 1 <= blocks.upperBound, last + 1 - index < maxRun,
                          !present[last + 1], !fetching.contains(last + 1) {
                        last += 1
                    }
                    run = index...last
                    break
                }
                index += 1
            }
            if let run {
                for b in run { fetching.insert(b) }
                if isForeground { foregroundFetching += 1 }
                lock.unlock()
                var fetchError: Error?
                do {
                    try fetch(run)
                } catch {
                    fetchError = error
                }
                lock.lock()
                for b in run { fetching.remove(b) }
                if isForeground {
                    foregroundFetching -= 1
                    lastForegroundFetchEnd = Date()
                    foregroundFetchCount += 1
                } else {
                    backgroundFetchCount += 1
                }
                if fetchError == nil {
                    for b in run where !present[b] {
                        present[b] = true
                        presentCount += 1
                    }
                    closeRemoteIfComplete()
                }
                lock.broadcast()
                lock.unlock()
                if let fetchError { throw fetchError }
                continue
            }
            // 取りに行くものは無い。必要な範囲が揃うまで(他のスレッドの取り寄せを)待つ。
            if !required.contains(where: { !present[$0] }) {
                lock.unlock()
                return
            }
            if isForeground { foregroundWaiting += 1 }
            lock.wait()
            if isForeground {
                foregroundWaiting -= 1
                lastForegroundFetchEnd = Date()
            }
            lock.unlock()
        }
    }

    /// 全部揃ったら、ネットワーク上のファイルの記述子を閉じる(`lock` を持って呼ぶ)。
    private func closeRemoteIfComplete() {
        guard presentCount == present.count, remoteFD >= 0 else { return }
        close(remoteFD)
        remoteFD = -1
    }

    private func fetch(_ run: ClosedRange<Int>) throws {
        let start = UInt64(run.lowerBound) * UInt64(blockSize)
        let length = Int(min(size - start, UInt64(run.count) * UInt64(blockSize)))
        lock.lock()
        let fd = remoteFD
        let cfd: Int32
        do {
            cfd = try cacheDescriptor()
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        // 取り寄せ中のブロックがある間は全部揃わないので、ここで記述子が閉じられることは無い。
        guard fd >= 0 else { throw RandomAccessSourceError.stopped }
        let data = try preadFully(fd: fd, offset: start, count: length, size: size)
        // 読んでいる間にファイルが短くなった(サーバ側で書き換えられた)。中途半端なブロックを手元に置かない。
        guard data.count == length else { throw RandomAccessSourceError.readFailed(EIO) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var done = 0
            while done < length {
                let n = pwrite(cfd, base + done, length - done, off_t(start) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw RandomAccessSourceError.readFailed(errno)
                }
                done += n
            }
        }
    }

    // MARK: - 裏の取り寄せ

    /// 裏の取り寄せを 1 回ぶん進める。続けるなら true。
    private func backgroundStep() -> Bool {
        lock.lock()
        while !stopped {
            if !hasForegroundRead {
                lock.wait()
                continue
            }
            // 前景が順に流れている間は、その先を取りに行く(伸長と転送を重ねる)。
            if sequentialWindow >= readAhead { break }
            // 飛び飛びの読みの間は譲る。
            if foregroundFetching > 0 || foregroundWaiting > 0 {
                lock.wait()
                continue
            }
            let quiet = Date().timeIntervalSince(lastForegroundFetchEnd)
            if quiet >= Self.idleGap { break }
            _ = lock.wait(until: Date().addingTimeInterval(Self.idleGap - quiet))
        }
        if stopped || presentCount == present.count {
            lock.unlock()
            return false
        }
        // 前景が最後に読んだ位置の先から、最初の「無く、取り寄せ中でもない」ブロック。
        let cursor = lastForegroundEnd < size ? block(containing: lastForegroundEnd) : 0
        var start: Int?
        for k in 0..<present.count {
            let b = (cursor + k) % present.count
            if !present[b] && !fetching.contains(b) {
                start = b
                break
            }
        }
        guard let start else {
            // 残りは他のスレッドが取り寄せ中。終わるのを待つ。
            lock.wait()
            lock.unlock()
            return true
        }
        let blocksPerChunk = max(1, backgroundChunk / blockSize)
        var end = start
        while end + 1 < present.count, end + 1 - start < blocksPerChunk, !present[end + 1], !fetching.contains(end + 1) {
            end += 1
        }
        lock.unlock()
        do {
            try ensure(blocks: start...end, required: start...start, isForeground: false)
        } catch {
            // 読めなかった(切断など)。裏の取り寄せはやめる(前景の読みは、それぞれの読みで失敗を受け取る)。
            return false
        }
        return true
    }
}

/// ネットワーク上の同じファイルを読む reader どうしで、1 つの `StagedFileSource` を共有する登録簿。
///
/// 1 冊を開くあいだに、BookLoader・PageLoader・サイドパネル下段・ComicInfo の取り込みは、それぞれ自分で書庫を開く。
/// 出所を共有すれば、誰かが一度取り寄せたブロック(一覧の索引など)は全員が手元から読める。
///
/// 最後の利用者が手放しても、`gracePeriod` の間は残す ―― BookLoader が読み終えて reader を手放した直後に PageLoader が
/// 開く、の間で写しを捨てないため。猶予を過ぎたら登録簿は手放し、利用者がいなければそこで一時ファイルが消える。
///
/// **猶予で残すのは直近の `maxHeld` 本だけ**。読み込み層は 1 本につきファイル記述子を 2 つ(ネットワーク上のファイルと
/// 手元の一時ファイル)持つので、ネットワーク上のフォルダを開いて一覧の絵を作るだけで、本の数 × 2 の記述子が猶予の間
/// 残り、ほかの書庫が開けなくなる(記述子の上限。テストを並べて走らせたとき、ほかのテストの書庫の読みがときどき
/// 失敗して見つかった、2026-09-25)。1 冊を開くあいだの受け渡しに要るのは数本なので、それより古いものは手放す。
///
/// 鍵はパス・大きさ・更新日時・ファイル番号(`FileStatKey`)。中身が差し替わった(大きさか更新日時が変わった)ファイルは
/// 別の鍵になり、古い写しは使われない。
nonisolated final class StagedFileRegistry: @unchecked Sendable {
    static let shared = StagedFileRegistry()

    let gracePeriod: TimeInterval

    private let lock = NSLock()
    private final class WeakSource {
        weak var source: StagedFileSource?
        init(_ source: StagedFileSource) { self.source = source }
    }
    private var live: [String: WeakSource] = [:]
    /// 猶予の間だけ持つ強参照と、その期限。
    private var holds: [String: (source: StagedFileSource, expiry: Date)] = [:]
    private var sweepTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "qooViewer.StagedFileRegistry")

    /// 猶予で残す(利用者のいない)読み込み層の本数の上限。
    let maxHeld: Int

    init(gracePeriod: TimeInterval = 30, maxHeld: Int = 4) {
        self.gracePeriod = gracePeriod
        self.maxHeld = maxHeld
    }

    /// ファイルの同一性の鍵。取れなければ nil(呼び出し側は読み込み層を使わずに開く)。
    static func key(for url: URL) -> String? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return "\(url.path)|\(st.st_dev)|\(st.st_ino)|\(st.st_size)|\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
    }

    /// `url` の読み込み層(あれば共有、無ければ作る)。`startsBackgroundFill` なら残りを裏で取り寄せ始める。
    func source(for url: URL, startsBackgroundFill: Bool) throws -> StagedFileSource {
        guard let key = Self.key(for: url) else { throw RandomAccessSourceError.cannotOpen }
        let source: StagedFileSource
        lock.lock()
        if let existing = live[key]?.source {
            source = existing
        } else {
            do {
                source = try StagedFileSource(url: url)
            } catch {
                lock.unlock()
                throw error
            }
            live[key] = WeakSource(source)
        }
        holds[key] = (source, Date().addingTimeInterval(gracePeriod))
        // 上限を超えたら、期限の早い(=古い)ものから手放す。今渡すものは呼び出し側が持つので消えない。
        var released: [StagedFileSource] = []
        while holds.count > maxHeld, let oldest = holds.min(by: { $0.value.expiry < $1.value.expiry }) {
            released.append(oldest.value.source)
            holds[oldest.key] = nil
        }
        scheduleSweepIfNeeded()
        lock.unlock()
        released.removeAll()  // 強参照はロックの外で手放す
        if startsBackgroundFill { source.startBackgroundFill() }
        return source
    }

    /// 今この登録簿が知っている(生きている)読み込み層の数(テスト用)。
    var liveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return live.values.filter { $0.source != nil }.count
    }

    /// 猶予を今すぐ切る(テスト用)。
    func expireAllHolds() {
        lock.lock()
        holds.removeAll()
        live = live.filter { $0.value.source != nil }
        lock.unlock()
    }

    /// `lock` を持って呼ぶ。
    private func scheduleSweepIfNeeded() {
        guard sweepTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + gracePeriod, repeating: gracePeriod / 2)
        timer.setEventHandler { [weak self] in self?.sweep() }
        sweepTimer = timer
        timer.resume()
    }

    private func sweep() {
        lock.lock()
        let now = Date()
        var released: [StagedFileSource] = []
        for (key, hold) in holds where hold.expiry <= now {
            released.append(hold.source)
            holds[key] = nil
        }
        live = live.filter { $0.value.source != nil || holds[$0.key] != nil }
        if holds.isEmpty {
            sweepTimer?.cancel()
            sweepTimer = nil
        }
        lock.unlock()
        // 強参照はここで手放す(利用者がいなければ、ここで一時ファイルが消える)。ロックの外で。
        released.removeAll()
    }
}

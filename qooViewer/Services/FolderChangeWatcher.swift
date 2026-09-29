import CoreServices
import Foundation
import os

/// 指定したフォルダの中身が変わったことを知らせる(FSEvents の薄い包み)。
///
/// 自動登録フォルダ(CollectionAutoFolderScanner)のためだけに作った。**必要になるまで
/// 入れていなかった** ―― 当初は「見にきたときに走査すれば見え方は同じ」と考えて契機を人の操作
/// (アプリのアクティブ化・画面の表示)に寄せていたが、ユーザーの要望は「コピーした瞬間に増えて
/// ほしい」だったため、監視を足した(ユーザー要望 2026-09-09)。
///
/// ■ 作りは qooLibrary の実測に合わせてある
/// 同じ作者の qooLibrary(`Sources/QooInfrastructure/Watch/FileSystemEventStream.swift`)に、
/// サンドボックス下で実際に計測した結果が表にまとめられている。こちらはそれに従っただけで、
/// 自分で測り直してはいない。要点:
/// - **App Sandbox で動く。追加の entitlement は要らない。**
/// - **読み取り権限の無いパスのイベントも届く**(監視のために事前の許可は要らない)。
///   このアプリでは、届いても列挙できなければ何もできないので、許可済みのフォルダだけを渡す。
/// - **存在しないパスを含めて生成しても成功する**(パスが現れた時点で配送が始まる)。
/// - **`FSEventStreamCreate` はブロックしうる。** 到達できない共有上のパスを含めると30秒返って
///   こない。だから`watch(_:)`は`async`で、生成はメインアクターの外で行う ―― さもないと共有が
///   落ちた瞬間にアプリが固まる。
/// - **コールバックは専用のシリアルキューで受ける。** メインキューを指定すると、メインが回って
///   いる場面でしか配送されない。
/// - **C へ渡すコールバックを`@MainActor`の型の内側に置いてはいけない。** メインアクター隔離と
///   みなされて実行アクターの表明が入り、FSEvents 自身のキューから呼ばれた時点で落ちる。
///   このファイルの直下に置いてあるのはそのため。
/// - **`info`には`self`ではなく専用の箱を渡し、retain/release を CF に任せる。**
///   `self`を渡すと「self → stream → self」の循環になり`deinit`が呼ばれない。箱は
///   `passUnretained`で渡す(`retain`を指定した context は CF が自分で+1するので、
///   `passRetained`にすると作り直すたびに1つずつ漏れる)。
///
/// ■ 取りこぼしは前提にしない
/// FSEvents はネットワークボリューム(SMB/AFP)では飛ばず、アプリが止められている間の変更も
/// まとめて1回になる。**これだけに頼らない** ―― 呼び出し側は従来どおり、アプリがアクティブに
/// なったときや画面が出たときにも走査する。監視はあくまで「見ている間の即時反映」のためのもの。
///
/// ■ 履歴の再生は受け取り側へ流さない(2026-09-29)
/// 起点(`sinceWhen`)を渡して張ったストリームには、まず「履歴」が再生され、番兵(`HistoryDone`)が届いてから生の知らせが続く。
/// `FullHistory` は「起点を含むかたまりの変更を、**起点より前のものまで**全部再生する」フラグ(FSEvents.h に明記)で、番兵は
/// 見張っている根のパスを持って届く(ヘッダーは「このパスは無視せよ」)。以前はどちらもそのまま流していたので、**見張るフォルダを
/// 入れ替えるたびに**、見張っている全部の根の古い変更と根そのもののパスが届いた(実測: フォルダ 2 つで 4 件 + 番兵、ホームと `/` では
/// 約 4,000 件)。ファイルブラウザのツリーは行を開閉するたびに入れ替えるので、開いているほかの行がそのたびに読み直され、
/// 開き直したように描き直された(ユーザー報告)。番兵と、番兵より前に届く起点以前の変更は C のコールバックで捨てる
/// (`FolderChangeStreamProgress`)。起点より後の変更(入れ替えの間の空白)は今までどおり届く。
///
/// ■ 何が変わったかは見ない
/// コールバックはイベントの中身を捨てて「何か変わった」とだけ伝える。どの本が増えたかは
/// 走査側がフォルダを一覧して決める(判定を2箇所に分けない)。そのため`UseCFTypes`も要らない。
///
/// @MainActor: 監視するパスの出入りは画面の操作から起きるので、状態はメインアクターに置く。
/// C と行き来する部分だけがこの外(ファイル直下の関数と箱)にある。
@MainActor
final class FolderChangeWatcher {
    /// イベントをまとめる時間(秒)。短くすると反応は早くなるが、コピー中のファイル1つで
    /// 何度も走査が走る。0.3 秒あれば人の感覚では即時で、連続する書き込みはひとまとめになる。
    private static let latency: CFTimeInterval = 0.3

    /// 変わったパス 1 件と、FSEvents が「この下は全部見直せ」と言ってきたか(`init(onEvents:)`)。
    nonisolated struct Event: Sendable, Equatable {
        let path: String
        /// `kFSEventStreamEventFlagMustScanSubDirs`(イベントがあふれて個別に列挙できなかった)か、取りこぼし
        /// (`UserDropped` / `KernelDropped`)。この下は全部変わったものとして扱う。
        let mustScanSubdirectories: Bool
        /// フォルダが作られた・名前が変わった(移ってきた)。同じボリュームの中でフォルダごと移ってきたときは中身のイベントが来ない
        /// (docs/plans/auto-rename-study.md §9.1)ので、受けた側が配下を読む目印。フラグは積み重なって届くので、消えた側でも立ちうる。
        var isDirectoryCreatedOrRenamed: Bool = false
        /// 項目が作られた・消えた・名前が変わった(中身の書き換えだけではない)。入っているフォルダの変更日が変わる種類の変化
        /// (ファイルブラウザの右ペインが、直下のフォルダの行の日付と並びを直すために見る。2026-09-19 の監査の L1)。
        var isStructuralChange: Bool = false
    }

    private let onChange: @Sendable ([Event]) -> Void
    /// 変わったパスを集めて渡すか(`init(onChangedPaths:)` / `init(onEvents:)`)。false なら中身を捨てる(型コメント「何が変わったかは見ない」)。
    private let reportsPaths: Bool
    /// FSEvents の配送先。**メインキューにはしない**(型コメント参照)。
    private let deliveryQueue = DispatchQueue(label: "jp.qooViewer.folderChangeWatcher", qos: .utility)
    /// いま監視しているパス(同じ顔ぶれなら張り直さないための照合用)。
    private var watchedPaths: Set<String> = []
    /// `deinit`(nonisolated)から破棄するため`nonisolated(unsafe)`。書き換えはメインアクター上の
    /// メソッドからだけで、`deinit`の時点では他に参照が無いため競合しない。
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    /// いまのストリームの進み具合(起点と、最後にコールバックが呼ばれた時刻)。`stopStream` が次の起点を決めるのに使う。
    private var streamProgress: FolderChangeStreamProgress?
    /// 直前のストリームを止めた時点のイベントID。パスを差し替えるときに`sinceWhen`として
    /// 渡し、止めてから始めるまでの空白を埋める(その間の変更を取りこぼさない)。
    private(set) var lastEventID = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    /// 生成を待っている間にパスが変わったかを見分けるための世代番号。
    private var generation = 0

    /// - Parameter onChange: 変更を検知したときに呼ぶ。**任意のキューから呼ばれる**ので、
    ///   受け取る側がメインアクターへ渡し直すこと。
    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = { _ in onChange() }
        reportsPaths = false
    }

    /// パスとフラグを受け取る版(2026-09-15、自動リネーム用)。自動リネームは、あふれたときに届く `MustScanSubDirs` を受けて
    /// 配下を走査し直す必要がある(docs/plans/auto-rename-study.md §7)。**任意のキューから呼ばれる**。
    init(onEvents: @escaping @Sendable ([Event]) -> Void) {
        onChange = onEvents
        reportsPaths = true
    }

    /// 変わったパス(ファイル単位。作られた・消えた・名前が変わった項目そのもの)を受け取る版(2026-09-14、
    /// ファイルブラウザのツリー用)。ツリーは開いている行が多く、「何か変わった」だけでは全部の行を読み直すことになるので、
    /// 変わった項目の親の行だけを読み直す。**任意のキューから呼ばれる**。
    init(onChangedPaths: @escaping @Sendable ([String]) -> Void) {
        onChange = { events in onChangedPaths(events.map(\.path)) }
        reportsPaths = true
    }

    deinit {
        // **待たない。** 破棄も相手が居なければ待たされうるので、解放だけを別の実行先へ投げる。
        if let stream { Self.tearDownWithoutWaiting(stream) }
    }

    /// 監視するフォルダを入れ替える。同じ顔ぶれなら何もしない(画面が描き直されるたびに
    /// 呼ばれても、ストリームを張り直さないようにするため)。空を渡すと監視を止める。
    ///
    /// **`async`なのは`FSEventStreamCreate`がブロックしうるため**(型コメント参照)。
    /// - Parameter startingAt: **初めて張る**ストリームの起点(`FSEventsGetCurrentEventId()` で控えた値)。呼び出し側が一覧を読み始める
    ///   **前に**控えて渡すと、読み始めてからストリームが立つまでの変更を取りこぼさない(2026-09-19 の監査の L3。以前は `SinceNow` で、
    ///   生成を待つ間 ―― 応答しない共有が混ざると長い ―― の変更が一覧に出なかった)。パスの入れ替えでは使わない(止めた時点の ID が起点)。
    func watch(_ paths: Set<String>, startingAt: FSEventStreamEventId? = nil) async {
        guard paths != watchedPaths else { return }
        stopStream()
        watchedPaths = paths
        // 空でも世代は必ず進める ―― 進めないと、待っている最中の生成が「まだ最新」と判定され、
        // 監視する相手が1つも無いのに古いパスを見張るストリームが据え付けられる。
        generation &+= 1
        guard !paths.isEmpty else {
            forgetLastEventID()
            return
        }

        let mine = generation
        let requested = Array(paths)
        let isFirstStream = lastEventID == FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        let sinceWhen = isFirstStream ? (startingAt ?? lastEventID) : lastEventID
        let handle = onChange
        let reportsPaths = reportsPaths
        let queue = deliveryQueue
        // メインアクターにいるうちに読み取っておく(下は外で走る)。
        let latency = Self.latency

        let created = await Task.detached(priority: .utility) {
            makeFolderChangeStream(
                roots: requested, sinceWhen: sinceWhen, latency: latency,
                queue: queue, reportsPaths: reportsPaths, onChange: handle
            )
        }.value

        // 待っている間にパスがまた変わっていたら、作ったものは捨てる
        // (30秒前の顔ぶれを見張るストリームを据えない)。
        guard generation == mine else {
            if let created { Self.tearDownWithoutWaiting(created.ref) }
            return
        }
        // 生成に失敗したら「まだ何も見ていない」に戻す ―― `watchedPaths`を残したままだと、
        // 同じ顔ぶれで呼ばれ続ける限り先頭の照合で弾かれ、二度と張り直されない
        // (監査で指摘 2026-09-09)。次の契機(アクティブ化・画面の表示)でもう一度試みる。
        guard let created else {
            watchedPaths = []
            return
        }
        stream = created.ref
        streamProgress = created.progress
    }

    /// 監視をやめる(テストと、フォルダが1つも無くなったとき)。
    func tearDown() {
        stopStream()
        watchedPaths = []
        generation &+= 1
        forgetLastEventID()
    }

    /// **見張るものが無くなったら、止めた時点からの続きを覚えておかない**(2026-09-14 の 2 回目の監査 19)。以前は空の組で止めた後も
    /// `lastEventID` を持ち越したので、本を読んで数時間後にファイルブラウザへ戻ると、次に張ったストリームへその間の履歴がまとめて届いた
    /// (ホームで 180 秒に 2,587 件を実測)。空白を埋めるのは「パスを入れ替える」間だけでよい ―― 戻ってきた画面は自分で読み直す。
    private func forgetLastEventID() {
        lastEventID = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    }

    private func stopStream() {
        guard let stream else { return }
        // **止める前に**、システム全体のいまのイベントIDを読む。以前はこのストリームが最後に受け取ったID
        // (`FSEventStreamGetLatestEventId`)を使っていたが、それは静かなフォルダを見ていれば何時間も前の値のままで、
        // `FullHistory` を付けているため、**新しく見張るパスの過去の履歴がその時点から丸ごと再生された**
        // (ファイルブラウザでフォルダを移るたびに、移った先の古い変更が届いた。2026-09-14 の監査の 4)。
        // いまのIDなら、残るパスの空白は埋まり、新しいパスで再生されるのは止めてから始めるまでの間だけ。
        //
        // **直前までコールバックが呼ばれていたストリームだけは、受け取った最後の ID を起点にする**(2026-09-29)。変更が続いている間は
        // FSEvents が `latency` ぶんまとめて持っており、止めた時点でまだ渡されていないものがありうる。以前は `FullHistory` の再生が
        // (意図せず)それも届けていたが、起点以前の再生を捨てるようにしたので、ここで起点を戻して拾う。戻る幅は高々
        // `pendingDeliveryWindow` 秒ぶんなので、静かなフォルダの何時間も前の履歴が再生されることはない。
        let current = FSEventsGetCurrentEventId()
        if let progress = streamProgress, progress.wasCalledBack(within: Self.pendingDeliveryWindow) {
            let delivered = max(FSEventStreamGetLatestEventId(stream), progress.startedAfter ?? 0)
            lastEventID = delivered > 0 ? min(delivered, current) : current
        } else {
            lastEventID = current
        }
        self.stream = nil
        streamProgress = nil
        Self.tearDownWithoutWaiting(stream)
    }

    /// 「まだ渡されていない変更がありうる」とみなす、最後のコールバックからの秒数(`latency` より十分長く)。
    private static let pendingDeliveryWindow: TimeInterval = 1

    /// 破棄を別の実行先へ投げ、完了を待たない(破棄もブロックしうる)。渡した時点でこちらは
    /// 参照を捨てているので、二重に触ることはない。
    private nonisolated static func tearDownWithoutWaiting(_ stream: FSEventStreamRef) {
        let box = FolderChangeStreamBox(stream)
        DispatchQueue.global(qos: .utility).async {
            FSEventStreamStop(box.ref)
            FSEventStreamInvalidate(box.ref)
            FSEventStreamRelease(box.ref)
        }
    }
}

// MARK: - C とやりとりする部分
//
// **`@MainActor`の型の内側に置いてはいけない**(FolderChangeWatcherの型コメント参照)。
// メインアクター隔離とみなされると実行アクターの表明が入り、FSEvents 自身のキューから
// 呼ばれた時点で落ちる。ファイル直下ならどのアクタにも属さない。

/// `FSEventStreamRef`を実行文脈の境界を越えて運ぶための箱。中身は不透明ポインタで、
/// 渡す側は必ず参照を手放してから渡すので、共有された可変状態にはならない。
private nonisolated struct FolderChangeStreamBox: @unchecked Sendable {
    let ref: FSEventStreamRef
    /// 張ったストリームの進み具合(破棄のために運ぶときは要らない)。
    let progress: FolderChangeStreamProgress?
    init(_ ref: FSEventStreamRef, progress: FolderChangeStreamProgress? = nil) {
        self.ref = ref
        self.progress = progress
    }
}

/// ストリーム 1 本の進み具合: 履歴の再生が終わったか、最後にコールバックが呼ばれたのはいつか
/// (FolderChangeWatcher の型コメント「履歴の再生は受け取り側へ流さない」)。
///
/// 書くのは FSEvents の配送キュー(C のコールバック)、読むのはメインアクター(`stopStream`)なので、ロックで守る。
nonisolated final class FolderChangeStreamProgress: Sendable {
    /// このストリームの起点。nil は `SinceNow`(履歴は再生されず、番兵も届かない)。
    let startedAfter: FSEventStreamEventId?

    private nonisolated struct State: Sendable {
        var isReplayingHistory: Bool
        var lastCallbackUptime: UInt64?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(sinceWhen: FSEventStreamEventId) {
        let startedAfter = sinceWhen == FSEventStreamEventId(kFSEventStreamEventIdSinceNow) ? nil : sinceWhen
        self.startedAfter = startedAfter
        state = OSAllocatedUnfairLock(initialState: State(isReplayingHistory: startedAfter != nil, lastCallbackUptime: nil))
    }

    /// コールバック 1 回ぶんのイベントのうち、受け取り側へ渡すものの位置。
    ///
    /// 捨てるのは、番兵(`HistoryDone`。パスは見張っている根で、変更ではない)と、**番兵より前に届いた起点以前の変更**
    /// (`FullHistory` の重なり)。取りこぼしの知らせ(`UserDropped` / `KernelDropped`)と ID を持たないもの(0)は、
    /// ID で新旧を決められないので必ず渡す。番兵の後に届くものは生の知らせなので、ID を見ずに渡す。
    func admittedIndices(
        count: Int, flags: UnsafePointer<FSEventStreamEventFlags>, ids: UnsafePointer<FSEventStreamEventId>
    ) -> [Int] {
        let historyDone = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        let now = DispatchTime.now().uptimeNanoseconds
        let startedAfter = startedAfter
        return state.withLockUnchecked { state in
            state.lastCallbackUptime = now
            var admitted: [Int] = []
            for index in 0..<count {
                if flags[index] & historyDone != 0 {
                    state.isReplayingHistory = false
                    continue
                }
                if state.isReplayingHistory, let startedAfter, ids[index] != 0, ids[index] <= startedAfter,
                   flags[index] & dropped == 0 {
                    continue
                }
                admitted.append(index)
            }
            return admitted
        }
    }

    /// 直前 `seconds` 秒のうちにコールバックが呼ばれたか(捨てたイベントだけの回も数える ―― FSEvents がまとめ始めるのは
    /// 配送した時点からなので)。
    func wasCalledBack(within seconds: TimeInterval) -> Bool {
        guard let last = state.withLock({ $0.lastCallbackUptime }) else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= last && Double(now - last) / 1_000_000_000 < seconds
    }
}

/// FSEvents の`context.info`に載せるためだけの箱。C の`void *`を跨ぐために要る。
/// 保持しているのは書き換えられない1本のクロージャだけ。
private nonisolated final class FolderChangeCallbackBox: Sendable {
    let handle: @Sendable ([FolderChangeWatcher.Event]) -> Void
    let reportsPaths: Bool
    let progress: FolderChangeStreamProgress
    init(
        _ handle: @escaping @Sendable ([FolderChangeWatcher.Event]) -> Void, reportsPaths: Bool,
        progress: FolderChangeStreamProgress
    ) {
        self.handle = handle
        self.reportsPaths = reportsPaths
        self.progress = progress
    }
}

private nonisolated let folderChangeRetain: CFAllocatorRetainCallBack = { info in
    guard let info else { return nil }
    return UnsafeRawPointer(Unmanaged<FolderChangeCallbackBox>.fromOpaque(info).retain().toOpaque())
}

private nonisolated let folderChangeRelease: CFAllocatorReleaseCallBack = { info in
    guard let info else { return }
    Unmanaged<FolderChangeCallbackBox>.fromOpaque(info).release()
}

private nonisolated let folderChangeCallback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, eventIds in
    guard let info else { return }
    let box = Unmanaged<FolderChangeCallbackBox>.fromOpaque(info).takeUnretainedValue()
    // 履歴の再生と番兵は渡さない(型コメント「履歴の再生は受け取り側へ流さない」)。残らなければ知らせない。
    let admitted = box.progress.admittedIndices(count: count, flags: eventFlags, ids: eventIds)
    guard !admitted.isEmpty else { return }
    // パスを求められていなければ中身は見ない(型コメント参照)。「何か変わった」だけを伝える。
    guard box.reportsPaths else {
        box.handle([])
        return
    }
    // UseCFTypes を付けていないので、eventPaths は C 文字列の配列。
    let pointers = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    let rescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
    )
    let directoryFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
    let arrivalFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed)
    let structuralFlags = arrivalFlags | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
    box.handle(admitted.map {
        FolderChangeWatcher.Event(
            path: String(cString: pointers[$0]), mustScanSubdirectories: eventFlags[$0] & rescanFlags != 0,
            isDirectoryCreatedOrRenamed: eventFlags[$0] & directoryFlag != 0 && eventFlags[$0] & arrivalFlags != 0,
            isStructuralChange: eventFlags[$0] & structuralFlags != 0
        )
    })
}

/// ストリームを1本作って開始する。**メインアクターの外で走る**(生成はブロックしうる)。
/// 状態には一切触らず、材料はすべて引数で受け取る。
private nonisolated func makeFolderChangeStream(
    roots: [String],
    sinceWhen: FSEventStreamEventId,
    latency: CFTimeInterval,
    queue: DispatchQueue,
    reportsPaths: Bool,
    onChange: @escaping @Sendable ([FolderChangeWatcher.Event]) -> Void
) -> FolderChangeStreamBox? {
    let progress = FolderChangeStreamProgress(sinceWhen: sinceWhen)
    let box = FolderChangeCallbackBox(onChange, reportsPaths: reportsPaths, progress: progress)
    var context = FSEventStreamContext(
        version: 0,
        // **passUnretained で渡す。** retain を指定した context は CF が自分で+1するので、
        // ここで+1すると作り直すたびに箱が1つずつ漏れる。
        info: Unmanaged.passUnretained(box).toOpaque(),
        retain: folderChangeRetain,
        release: folderChangeRelease,
        copyDescription: nil
    )

    // FileEvents: フォルダ単位ではなくファイル単位で拾う(書庫を1つ置いただけでも飛ぶ)。
    // NoDefer: 最初のイベントを latency ぶん待たせない(待つのは続けて起きた変更をまとめるとき)。
    // FullHistory: 異常終了の直前に起きた変更を取りこぼさない。走査は何度やっても同じ結果
    //   (重複はinsertItemsが弾く)なので、余分に届いても害が無い。
    //   → **害はあった**(2026-09-29。型コメント「履歴の再生は受け取り側へ流さない」)。フラグは残し、起点より前の再生は
    //   コールバックで捨てる(フラグを外すと、起点の近くの変更が「保存のされ方の都合で飛ばされうる」―― FSEvents.h)。
    //
    // **WatchRoot は付けない**(実機で発覚 2026-09-09)。このフラグは見張っているフォルダ自身の
    // 改名・移動を知らせるために、**ルートとその祖先ディレクトリを1階層ごとに open して握り続ける**
    // (`/Volumes/X/A/B/C` なら5個。実測: ルート1本・深さ13で DIR fd が13個、2本で26個、
    // 無しなら0個)。自動登録フォルダはコレクションの数だけルートになるので、49個 × 5 = 245 で
    // GUI アプリの soft limit(256)を起動直後に使い切り、以後のあらゆる open が EMFILE で落ちた
    // ―― カバー画像が全部空になり、ドロップした本のブックマークも黙って作れなくなった。
    // 改名・削除は走査側がフォルダを列挙して「見つかりません」に落ちるので、失うのは
    // 「改名した瞬間に気づく」ことだけ(次の契機で追いつく)。
    //
    // **IgnoreSelf は付けない。** このアプリ自身が自動登録フォルダへ本を書き出すことがあり
    // (CBZ/EPUB/PDFの書き出し先に選べる)、それを抑止する理由が無い。
    let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        | FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        | FSEventStreamCreateFlags(kFSEventStreamCreateFlagFullHistory)

    guard let created = FSEventStreamCreate(
        kCFAllocatorDefault, folderChangeCallback, &context,
        roots as CFArray, sinceWhen, latency, flags
    ) else {
        // 生成に失敗しても致命的ではない(人の操作を契機にする走査は生きている)。
        // 失敗した場合 FSEvents は retain を呼んでいないので、ここで解放してはならない。
        return nil
    }
    FSEventStreamSetDispatchQueue(created, queue)
    guard FSEventStreamStart(created) else {
        FSEventStreamInvalidate(created)
        FSEventStreamRelease(created)
        return nil
    }
    return FolderChangeStreamBox(created, progress: progress)
}

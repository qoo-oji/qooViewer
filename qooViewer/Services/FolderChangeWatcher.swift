import CoreServices
import Foundation

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

    private let onChange: @Sendable () -> Void
    /// FSEvents の配送先。**メインキューにはしない**(型コメント参照)。
    private let deliveryQueue = DispatchQueue(label: "jp.qooViewer.folderChangeWatcher", qos: .utility)
    /// いま監視しているパス(同じ顔ぶれなら張り直さないための照合用)。
    private var watchedPaths: Set<String> = []
    /// `deinit`(nonisolated)から破棄するため`nonisolated(unsafe)`。書き換えはメインアクター上の
    /// メソッドからだけで、`deinit`の時点では他に参照が無いため競合しない。
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    /// 直前のストリームが最後に処理したイベントID。パスを差し替えるときに`sinceWhen`として
    /// 渡し、止めてから始めるまでの空白を埋める(その間の変更を取りこぼさない)。
    private var lastEventID = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    /// 生成を待っている間にパスが変わったかを見分けるための世代番号。
    private var generation = 0

    /// - Parameter onChange: 変更を検知したときに呼ぶ。**任意のキューから呼ばれる**ので、
    ///   受け取る側がメインアクターへ渡し直すこと。
    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit {
        // **待たない。** 破棄も相手が居なければ待たされうるので、解放だけを別の実行先へ投げる。
        if let stream { Self.tearDownWithoutWaiting(stream) }
    }

    /// 監視するフォルダを入れ替える。同じ顔ぶれなら何もしない(画面が描き直されるたびに
    /// 呼ばれても、ストリームを張り直さないようにするため)。空を渡すと監視を止める。
    ///
    /// **`async`なのは`FSEventStreamCreate`がブロックしうるため**(型コメント参照)。
    func watch(_ paths: Set<String>) async {
        guard paths != watchedPaths else { return }
        stopStream()
        watchedPaths = paths
        // 空でも世代は必ず進める ―― 進めないと、待っている最中の生成が「まだ最新」と判定され、
        // 監視する相手が1つも無いのに古いパスを見張るストリームが据え付けられる。
        generation &+= 1
        guard !paths.isEmpty else { return }

        let mine = generation
        let requested = Array(paths)
        let sinceWhen = lastEventID
        let handle = onChange
        let queue = deliveryQueue
        // メインアクターにいるうちに読み取っておく(下は外で走る)。
        let latency = Self.latency

        let created = await Task.detached(priority: .utility) {
            makeFolderChangeStream(
                roots: requested, sinceWhen: sinceWhen, latency: latency,
                queue: queue, onChange: handle
            )
        }.value

        // 待っている間にパスがまた変わっていたら、作ったものは捨てる
        // (30秒前の顔ぶれを見張るストリームを据えない)。
        guard generation == mine else {
            if let created { Self.tearDownWithoutWaiting(created.ref) }
            return
        }
        stream = created?.ref
    }

    /// 監視をやめる(テストと、フォルダが1つも無くなったとき)。
    func tearDown() {
        stopStream()
        watchedPaths = []
        generation &+= 1
    }

    private func stopStream() {
        guard let stream else { return }
        // **止める前に**読む(無効化したあとは取れない)。構造体のフィールドを読むだけなので
        // ブロックしない。
        lastEventID = FSEventStreamGetLatestEventId(stream)
        self.stream = nil
        Self.tearDownWithoutWaiting(stream)
    }

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
    init(_ ref: FSEventStreamRef) { self.ref = ref }
}

/// FSEvents の`context.info`に載せるためだけの箱。C の`void *`を跨ぐために要る。
/// 保持しているのは書き換えられない1本のクロージャだけ。
private nonisolated final class FolderChangeCallbackBox: Sendable {
    let handle: @Sendable () -> Void
    init(_ handle: @escaping @Sendable () -> Void) { self.handle = handle }
}

private nonisolated let folderChangeRetain: CFAllocatorRetainCallBack = { info in
    guard let info else { return nil }
    return UnsafeRawPointer(Unmanaged<FolderChangeCallbackBox>.fromOpaque(info).retain().toOpaque())
}

private nonisolated let folderChangeRelease: CFAllocatorReleaseCallBack = { info in
    guard let info else { return }
    Unmanaged<FolderChangeCallbackBox>.fromOpaque(info).release()
}

private nonisolated let folderChangeCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
    guard let info else { return }
    // イベントの中身は見ない(型コメント参照)。「何か変わった」だけを伝える。
    Unmanaged<FolderChangeCallbackBox>.fromOpaque(info).takeUnretainedValue().handle()
}

/// ストリームを1本作って開始する。**メインアクターの外で走る**(生成はブロックしうる)。
/// 状態には一切触らず、材料はすべて引数で受け取る。
private nonisolated func makeFolderChangeStream(
    roots: [String],
    sinceWhen: FSEventStreamEventId,
    latency: CFTimeInterval,
    queue: DispatchQueue,
    onChange: @escaping @Sendable () -> Void
) -> FolderChangeStreamBox? {
    let box = FolderChangeCallbackBox(onChange)
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
    // WatchRoot: 見張っているフォルダ自身の改名・移動・削除も知らせる(自動登録が黙って
    //   止まるのではなく、走査が空振りして「見つかりません」に落ちる)。
    // FullHistory: 異常終了の直前に起きた変更を取りこぼさない。走査は何度やっても同じ結果
    //   (重複はinsertItemsが弾く)なので、余分に届いても害が無い。
    //
    // **IgnoreSelf は付けない。** このアプリ自身が自動登録フォルダへ本を書き出すことがあり
    // (CBZ/EPUB/PDFの書き出し先に選べる)、それを抑止する理由が無い。
    let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        | FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        | FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
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
    return FolderChangeStreamBox(created)
}

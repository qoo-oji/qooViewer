import AppKit
import Darwin

/// 名前の編集(インラインの名前の変更)を**始めてよいか・続けてよいか**の決まり。リストとアイコン表示が同じものを使う(2026-09-19)。
///
/// ■ なぜ一か所にまとめたか
/// リストで、選ばれているファイルをフォルダへドラッグして移動したのに、**移動したファイルの名前の編集が始まった**(ユーザー報告
/// 2026-09-19)。編集中は一覧を取り込まない(添字ずれで別の項目の名前を変えないため。監査の 5)ので、もう無いファイルが一覧に残り、
/// 編集を終えるまで消えなかった。調べると、編集の始まり方と、始めた後の一覧との食い違いのどちらにも穴があった:
/// - リストの「選ばれている行をもう一度クリック」は `NSTableView` の標準に任せていた。実際に編集を始めるのは AppKit の内側の遅延実行
///   (`-[NSTableRowData _delayMakeFirstResponder:]`、ダブルクリックの間隔の後。実機のスタックで確認)で、アプリの状態を何も見ない。
///   押し直しがダブルクリック扱いになるとこの予約が取り消されず、操作の途中で編集が始まった(合成イベントで再現)
/// - 編集を始める時点で、その項目が今の一覧・今のディスクにあるかを誰も確かめていなかった
/// - 編集中にその項目が消えても(ドラッグでの移動・Finder・自動リネーム・他のウインドウ)、編集は残り続けた
/// そこで、(1) 名前の欄は**アプリが編集を始めるときだけ**編集できる欄にし(AppKit には始めさせない)、クリックからの予約は
/// `FileBrowserNameClickRename` が持つ、(2) 始める直前に `canBegin` で確かめる、(3) 編集中に届いた一覧から項目が消えていたら
/// `editedItemVanished` で編集を取りやめる、の 3 つをリスト・アイコンの両方に入れた。ツリーは名前を編集しない。
enum FileBrowserNameEditing {
    /// 名前の編集を始めてよいか。
    /// - Parameters:
    ///   - entry: 一覧(画面に出している写し)の項目。
    ///   - displayedFolder: 一覧が画面に出しているフォルダ(最後に取り込んだ時点の `state.currentFolder`)。
    ///   - itemExists: ディスクにまだあるか(テストで差し替える)。
    static func canBegin(
        _ entry: FileBrowserEntry, displayedFolder: URL?, state: FileBrowserState, allowsFileChanges: Bool,
        itemExists: (URL) -> Bool = itemExists(at:)
    ) -> Bool {
        // 読み取り専用モードの間は始めない(段階 8.5)。ボリュームの名前は変えない。
        guard allowsFileChanges, !entry.isVolume else { return false }
        // 画面が状態に追いついている(一覧の取り込みを待たせている間の古い行ではない)。
        guard state.currentFolder == displayedFolder, state.entry(withID: entry.id) != nil else { return false }
        // 一覧の読み直しより先に、ディスクから消えた・移った(ドラッグで移した直後など)。
        return itemExists(entry.url)
    }

    /// 項目がディスクにあるか。リンクは辿らない(壊れたリンクもリンクとしてはある)。
    nonisolated static func itemExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// 編集中に届いた一覧から、編集している項目が消えたか。**表示するフォルダが同じまま**のときだけ ―― フォルダが変わったときは
    /// 打った名前で確定する(それぞれの一覧の `update` のコメント)。消えていたら編集を取りやめる(打った名前で変えようとしても元が無い)。
    static func editedItemVanished(id: String, displayedFolder: URL?, state: FileBrowserState) -> Bool {
        state.currentFolder == displayedFolder && state.entry(withID: id) == nil
    }
}

/// 選ばれている 1 件の名前をもう一度クリックしてから、ダブルクリックの間隔だけ待って名前の編集を始める予約(Finder と同じ)。
/// リストとアイコン表示が 1 つずつ持つ。
///
/// 待っている間に**アプリのどこかで**押す・キーを打つ(ダブルクリックの 2 回目、ツリーでの押し下げ、ドラッグの始まり)と取りやめる。
/// 一覧の中のクリックだけを数える作り(以前のアイコン表示)だと、ほかの部品で始めた操作を見落とす。待ち終わった時点でボタンが
/// 押されたまま(ドラッグの最中)なら始めない。何を確かめてから始めるかは呼び出し側の閉包(`FileBrowserNameEditing.canBegin` を通す)。
@MainActor
final class FileBrowserNameClickRename {
    private var pending: Task<Void, Never>?
    private var monitor: Any?
    /// 待つ(ダブルクリックの間隔。テストはすぐ戻る待ちに差し替える)。
    var wait: @MainActor () async -> Void = { try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval)) }

    var isPending: Bool { pending != nil }

    /// - Returns: 待って始める(または取りやめる)までの Task(テストが待つ)。
    @discardableResult
    func schedule(_ begin: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        cancel()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            self?.cancel()
            return event
        }
        let wait = wait
        let task = Task { @MainActor [weak self] in
            await wait()
            guard let self, !Task.isCancelled else { return }
            self.stop()
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            begin()
        }
        pending = task
        return task
    }

    /// 予約を取りやめる(押し下げ・キー・ドラッグの始まり・編集の開始・ビューの片付け)。
    func cancel() {
        pending?.cancel()
        stop()
    }

    private func stop() {
        pending = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

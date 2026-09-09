import CoreServices
import Foundation

/// 指定したフォルダの中身が変わったことを知らせる(FSEvents の薄い包み)。
///
/// 自動登録フォルダ(CollectionAutoFolderScanner)のためだけに作った。**必要になるまで
/// 入れていなかった** ―― 当初は「見にきたときに走査すれば見え方は同じ」と考えて契機を人の操作
/// (アプリのアクティブ化・画面の表示)に寄せていたが、ユーザーの要望は「コピーした瞬間に増えて
/// ほしい」だったため、監視を足した(ユーザー要望 2026-09-09)。
///
/// ■ 監視するのは許可済みのフォルダだけ
/// サンドボックスでは、アクセス権のあるパスしか監視できない。呼び出し側が
/// `FolderAccessStore.isPathCovered` で絞ってから渡す(CollectionAutoFolderScanner)。
///
/// ■ 取りこぼしは前提にしない
/// FSEvents はネットワークボリューム(SMB/AFP)では飛ばず、アプリが止められている間の変更も
/// まとめて1回になる。**これだけに頼らない** ―― 呼び出し側は従来どおり、アプリがアクティブに
/// なったときや画面が出たときにも走査する。監視はあくまで「見ている間の即時反映」のためのもの。
///
/// ■ 何が変わったかは見ない
/// コールバックはイベントの中身を捨てて「何か変わった」とだけ伝える。どの本が増えたかは
/// 走査側がフォルダを一覧して決める(判定を2箇所に分けない)。
///
/// nonisolated: FSEvents のコールバックは任意のキューから呼ばれる C の関数ポインタなので、
/// メインアクター分離の型にはできない(ArchiveReading.swift 冒頭のコメント参照)。
nonisolated final class FolderChangeWatcher {
    /// イベントをまとめる時間(秒)。短くすると反応は早くなるが、コピー中のファイル1つで
    /// 何度も走査が走る。0.3 秒あれば人の感覚では即時で、連続する書き込みはひとまとめになる。
    private static let latency: CFTimeInterval = 0.3

    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "jp.qooViewer.folderChangeWatcher", qos: .utility)
    /// いま監視しているパス(重複して張り直さないための照合用)。
    private var watchedPaths: Set<String> = []
    private var stream: FSEventStreamRef?

    /// - Parameter onChange: 変更を検知したときに呼ぶ。**任意のキューから呼ばれる**ので、
    ///   受け取る側がメインアクターへ渡し直すこと。
    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit {
        tearDown()
    }

    /// 監視するフォルダを入れ替える。同じ顔ぶれなら何もしない(画面が描き直されるたびに
    /// 呼ばれても、ストリームを張り直さないようにするため)。
    func watch(_ paths: Set<String>) {
        guard paths != watchedPaths else { return }
        tearDown()
        watchedPaths = paths
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        // kFSEventStreamCreateFlagFileEvents: フォルダ単位ではなくファイル単位で拾う
        //   (書庫を1つ置いただけでも飛ぶようにする)。
        // kFSEventStreamCreateFlagNoDefer: 最初のイベントを latency ぶん待たずにすぐ渡す
        //   (待つのは「続けて起きた変更をまとめる」ときだけ)。
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            folderChangeWatcherCallback,
            &context,
            Array(paths) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            flags
        ) else {
            watchedPaths = []
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    /// 監視をやめる(テストと、フォルダが1つも無くなったとき)。
    func tearDown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watchedPaths = []
    }

    fileprivate func notifyChanged() {
        onChange()
    }
}

/// FSEvents のコールバック。C の関数ポインタなので、`info` から持ち主を取り出すだけの
/// トップレベル関数にしてある。
private nonisolated let folderChangeWatcherCallback: FSEventStreamCallback = {
    _, info, _, _, _, _ in
    guard let info else { return }
    Unmanaged<FolderChangeWatcher>.fromOpaque(info).takeUnretainedValue().notifyChanged()
}

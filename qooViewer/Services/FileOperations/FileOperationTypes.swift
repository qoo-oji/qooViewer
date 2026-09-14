import Foundation

// ファイル操作エンジン(FileOperationService)の入出力の型(改善要望7 段階 2、2026-09-13)。
// 型と決めごとは qooLibrary の実装を写し、qooViewer の計画(docs/plans/file-browser-plan.md §2)に
// 合わせて次を変えている:
// - 一括の移動・コピーは失敗を例外で投げ切らず、**動いた分の受領書と失敗を 1 つの結果に入れて返す**
//   (TransferOutcome)。1 件も動かなかったときだけ投げる。
// - 衝突の「以降すべてに適用」は、呼び出し側ではなく 1 回の操作の中でエンジンが覚える(ConflictDecision)。
// - 中止は `Cancellation` を Options で渡す(進捗の帯の中止ボタンが持つ)。

/// 宛先に同じ名前があったときの扱い。
nonisolated enum ConflictPolicy: Sendable, Equatable {
    /// `conflictResolver` に尋ねる。
    case ask
    /// 既存を**同じフォルダへ退避してから**書き、成功したら退避をゴミ箱へ(直後の Undo で戻せる)。
    /// 中断・失敗したら退避を元へ戻す。
    case replace
    /// `name 2.ext` の名前で置く(FileNameValidation.nextAvailableName)。
    case keepBoth
    case skip
}

/// 尋ねるときに渡す 1 件ぶんの衝突。
nonisolated struct FileConflict: Sendable, Equatable {
    let source: URL
    let destination: URL
}

/// 衝突への答え。`applyToRemaining` なら同じ操作の残りの衝突にも同じ答えを使う(もう尋ねない)。
nonisolated struct ConflictDecision: Sendable, Equatable {
    /// `.ask` は受け付けない(もう一度尋ねる無限ループになるので、エンジンは失敗として扱う)。
    var policy: ConflictPolicy
    var applyToRemaining: Bool
    /// `.replace` で、置き換えられる既存の項目(自身か、すぐに消すときは中の項目)がロックされていても外して置き換える
    /// (利用者が確認で「続ける」と答えた)。false ならロックされた既存の項目は触る前に「ロックされています」で断る。
    var unlockingLocked: Bool

    init(_ policy: ConflictPolicy, applyToRemaining: Bool = false, unlockingLocked: Bool = false) {
        self.policy = policy
        self.applyToRemaining = applyToRemaining
        self.unlockingLocked = unlockingLocked
    }
}

/// 長い操作の進み具合。件数とバイト数の両方を持つ(件数だけだと巨大な 1 ファイルが 0/1 のまま
/// 止まって見え、バイトだけだと残りの件数が分からない)。
nonisolated struct FileOperationProgress: Sendable, Equatable {
    var completedBytes: Int64 = 0
    /// 0 は「総量が分からない」(数えていない ―― 同一ボリュームの移動・クローンで済むコピー)。
    var totalBytes: Int64 = 0
    var completedItems = 0
    var totalItems = 0
    /// いま運んでいる項目の名前(パスではない)。
    var currentItemName: String?

    /// 0...1。総量が分からなければ nil(不定の進捗にする)。
    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }
}

/// 進捗の受け取り口。**どのスレッドから呼ばれるか分からない**(copyfile の status callback は
/// FileIO のスレッドの上)ので、受け取った側がメインアクターへ移すこと。間引きは送る側
/// (ProgressTracker)が 100ms で行う。
nonisolated struct ProgressSink: Sendable {
    private let handler: @Sendable (FileOperationProgress) -> Void

    init(_ handler: @escaping @Sendable (FileOperationProgress) -> Void) {
        self.handler = handler
    }

    func report(_ progress: FileOperationProgress) {
        handler(progress)
    }
}

nonisolated struct FileOperationOptions: Sendable {
    var conflictPolicy: ConflictPolicy
    /// `.ask` のときに衝突 1 件ごとに呼ばれる。メインアクターで尋ねる(シート・アラート)。
    var conflictResolver: (@MainActor @Sendable (FileConflict) async -> ConflictDecision)?
    var progress: ProgressSink?
    /// 中止ボタンの旗。立てると次の区切り(項目の境目・copyfile の callback)で止まり、
    /// そこまでに運び終えた分の受領書を返す。
    var cancellation: Cancellation
    /// 移動で、ロックされた項目(同じボリュームなら項目自身、別のボリュームなら中の項目も)のロックを外して運び、
    /// 運んだ先で掛け直す(利用者が確認で「続ける」と答えた、または取り消しで自分が運んだものを戻す)。
    /// false ならロックされた項目は「ロックされています」で断る。コピーには関係しない(ロックごと写る)。
    var unlockingLocked: Bool

    init(
        conflictPolicy: ConflictPolicy = .ask,
        conflictResolver: (@MainActor @Sendable (FileConflict) async -> ConflictDecision)? = nil,
        progress: ProgressSink? = nil,
        cancellation: Cancellation = Cancellation(),
        unlockingLocked: Bool = false
    ) {
        self.conflictPolicy = conflictPolicy
        self.conflictResolver = conflictResolver
        self.progress = progress
        self.cancellation = cancellation
        self.unlockingLocked = unlockingLocked
    }
}

// MARK: - 結果

/// 項目の実体の見分け(取り消しの前に「操作で作った・運んだそのもの」かを確かめる。2026-09-14)。
///
/// ■ なぜ要るか
/// 受領書はパスで持つので、操作のあとで同じパスに**別の項目**が来ると、取り消しがそれを自分のものと取り違える
/// (取り消せない移動は履歴に積まないので、前の操作が作った場所へ同じ名前の項目を移動してくると、⌘Z が
/// **移動してきた項目を**ゴミ箱へ送った ―― 計画 §4.14。Finder など外での置き換えでも同じ)。
///
/// ■ 何で見分けるか
/// デバイス番号 + inode + 作成日時。**履歴はメモリの中だけ**(アプリを閉じれば消える)なので、同じセッションの中で
/// 比べられればよい。デバイス番号はマウントし直すと変わる(メモ st-dev-changes-with-mount-order)が、そのときは
/// 「別の項目」と見なして断る側に倒れるだけ。inode だけにしないのは、exFAT/FAT の inode が場所から作られ、
/// 同じ場所に置き直した別のファイルが同じ番号になるため。
nonisolated struct FileIdentity: Sendable, Hashable {
    let device: Int32
    let inode: UInt64
    let birthSeconds: Int
    let birthNanoseconds: Int

    /// **リンクを辿らない**(lstat)。無ければ nil。ブロッキングするので FileIO の上で呼ぶ。
    static func of(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FileIdentity(
            device: info.st_dev, inode: info.st_ino,
            birthSeconds: info.st_birthtimespec.tv_sec, birthNanoseconds: info.st_birthtimespec.tv_nsec
        )
    }

    /// `url` にあるのが `expected` の項目か。`expected` が nil(記録できなかった)なら、あるかどうかだけで判断する
    /// (記録できないのは作った直後に lstat が失敗したときだけで、以前の動作に戻るだけ)。
    static func matches(_ url: URL, _ expected: FileIdentity?) -> Bool {
        guard let current = of(url) else { return false }
        return expected.map { $0 == current } ?? true
    }
}

/// 1 件の移動・コピーで実際に起きたこと。**Undo はこれだけを頼りに組み立てる。**
nonisolated struct TransferReceipt: Sendable, Equatable {
    let source: URL
    /// 実際に置いた場所(`.keepBoth` なら `name 2.ext`)。
    let destination: URL
    /// `.replace` で置き換えた既存の項目を送ったゴミ箱の中の場所(送れなかった・置き換えていないなら nil)。
    let replacedItemInTrash: URL?
    /// 置いた直後の `destination` の実体(FileIdentity)。取り消しはこれと一致するときだけ手を付ける。
    var identity: FileIdentity?

    init(source: URL, destination: URL, replacedItemInTrash: URL?, identity: FileIdentity? = nil) {
        self.source = source
        self.destination = destination
        self.replacedItemInTrash = replacedItemInTrash
        self.identity = identity
    }
}

/// 失敗した 1 件と、その理由(表示言語の文)。
nonisolated struct FailedItem: Sendable, Equatable {
    /// 見せる名前(ファイルなら lastPathComponent、まとめた操作なら操作の名前)。
    let name: String
    /// 対象のファイル。ファイルを指さない失敗(まとめた操作の子の取り消し)では nil。
    let url: URL?
    let reason: String

    init(url: URL, reason: String) {
        name = url.lastPathComponent
        self.url = url
        self.reason = reason
    }

    init(name: String, reason: String) {
        self.name = name
        url = nil
        self.reason = reason
    }
}

/// 一括の移動・コピーの結果。**部分失敗は捨てない**: 30 件目で失敗しても、動いた 29 件の受領書は
/// ここに残る(捨てると、動いたファイルを Undo で戻す手段が無くなる。qooLibrary で監査により発見)。
nonisolated struct TransferOutcome: Sendable, Equatable {
    var receipts: [TransferReceipt] = []
    /// 止まった原因の項目。今は最初の失敗で止まるので 0 件か 1 件。
    var failures: [FailedItem] = []
    /// 衝突で `.skip` を選んだ項目。
    var skipped: [URL] = []
    /// 失敗・中止のあと手を付けなかった項目。
    var unprocessed: [URL] = []
    var wasCancelled = false

    var isCompleteSuccess: Bool { failures.isEmpty && unprocessed.isEmpty && !wasCancelled }
}

nonisolated struct RenameReceipt: Sendable, Equatable {
    let original: URL
    let renamed: URL
    /// 名前を変えた直後の実体(TransferReceipt.identity と同じ役目)。
    var identity: FileIdentity?

    init(original: URL, renamed: URL, identity: FileIdentity? = nil) {
        self.original = original
        self.renamed = renamed
        self.identity = identity
    }
}

nonisolated struct TrashReceipt: Sendable, Equatable {
    let originalURL: URL
    /// `NSWorkspace.recycle` が返したゴミ箱の中の場所。返らなかった(送れたのに場所が分からない)なら nil ――
    /// その項目は Undo で戻せない。
    let trashURL: URL?
}

nonisolated struct TrashOutcome: Sendable, Equatable {
    var receipts: [TrashReceipt] = []
    var failures: [FailedItem] = []
}

nonisolated struct DeletionOutcome: Sendable, Equatable {
    var deleted: [URL] = []
    var failures: [FailedItem] = []
}

nonisolated struct RestoreOutcome: Sendable, Equatable {
    /// 戻せた項目(元の場所)。
    var restored: [URL] = []
    var failures: [FailedItem] = []
}

// MARK: - エラー

/// ファイル操作の失敗。**書き始める前に分かるものは書き始める前に投げる**(1 バイトも書かない)。
nonisolated enum FileOperationError: Error, Sendable, Equatable {
    /// `.ask` なのに `conflictResolver` が無い、または答えが `.ask` だった。
    case conflictResolutionRequired(destination: URL)
    /// その名前の項目が既にある(新規フォルダ・名前の変更)。
    case alreadyExists(URL)
    /// 対象の項目が無い。
    case itemMissing(URL)
    /// POSIX の失敗で止まった。errno を畳まずに持つ(容量不足か権限かを言い分けるため)。
    case posixFailure(item: URL, errnoCode: Int32)
    /// 始める前に空きが足りないと分かった。`required` は書く量に余裕(FileOperationPreflight.freeSpaceMargin)を足した値。
    case insufficientFreeSpace(required: Int64, available: Int64, destination: URL)
    /// フォルダをそれ自身かその配下へ運ぼうとした。copyfile は 332 階層まで自己増殖してから
    /// ENAMETOOLONG で止まり、ゴミの木を残した(qooLibrary 実測)。
    case destinationInsideSource(source: URL, destination: URL)
    case destinationIsReadOnly(URL)
    /// `access(W_OK)` が通らない。モードビットも `volumeIsReadOnly` も SMB では嘘をつくので別に持つ。
    case destinationNotWritable(URL, errnoCode: Int32)
    /// その場所にゴミ箱が無い。呼び出し側が先に `TrashAvailability` で見て完全削除へ振り分けるのが
    /// 本筋で、これは取りこぼしの最後の砦。
    case trashUnavailable(URL)
    /// 待つのをやめた(I/O が止まったのではない)。
    case timedOut(seconds: Double)
    case invalidName(String, reason: FileNameValidation.Failure)
    /// 出来上がるパスが上限(全形式で 1024 バイト = PATH_MAX)を超える。
    case pathTooLong(item: URL, resultingBytes: Int, limitBytes: Int)
    /// 運んでいる間に元が書き換えられた。移動なら元を消さず、写した側を片付けてある。
    case sourceChangedDuringOperation(URL)
    /// 名前が宛先の上限を超える(SMB は UTF-8 で 255 バイト)。
    case nameTooLongForDestination(name: String, lengthBytes: Int, limitBytes: Int)
    /// 1 ファイルが宛先の上限を超える(FAT32 は 4GB 弱)。
    case fileTooLargeForDestination(item: URL, size: Int64, limit: Int64)
    /// 「置き換える」で退避した元の項目を戻せなかった。元の項目は `backup` の名前(先頭がドット)で残っている。
    case replaceBackupOrphaned(backup: URL, target: URL)
    /// 項目がロックされている(Finder の「ロック」)。ゴミ箱へ送る・完全に削除する・置き換えるのどれもできない。
    case itemLocked(URL)
    /// 別ボリュームへの移動で、写し終えたが元を消せなかった。**写しは宛先に残してある**(元は途中まで消えているかもしれない)。
    /// 投げずに `TransferOutcome.failures` の理由の文として使う(FileCopyEngine.Outcome.copiedButSourceRemains)。
    case sourceRemainsAfterMove(item: URL, reason: String)
    /// 「置き換える」で書き終えたが、置き換えられた元の項目をゴミ箱へ送れなかった。**消さずに `backup`(先頭がドットの隠しフォルダ)に
    /// 残してある**。投げずに `TransferOutcome.failures` の理由の文として使う。
    case replacedItemKept(backup: URL, target: URL)
}

extension FileOperationError: LocalizedError {
    nonisolated var errorDescription: String? {
        let locale = AppLanguage.currentLocale
        switch self {
        case let .conflictResolutionRequired(destination), let .alreadyExists(destination):
            return String(format: String(localized: "An item named “%@” already exists in this location.", language: locale),
                          destination.lastPathComponent)
        case let .itemMissing(url):
            return String(format: String(localized: "“%@” could not be found.", language: locale), url.lastPathComponent)
        case let .posixFailure(item, code):
            return String(format: String(localized: "The operation couldn’t be completed for “%1$@”. %2$@", language: locale),
                          item.lastPathComponent, PosixFailure.reason(code))
        case let .insufficientFreeSpace(required, available, destination):
            let formatter = ByteCountFormatter()
            return String(
                format: String(localized: "There isn’t enough free space on “%1$@”. %2$@ is needed, but only %3$@ is available.", language: locale),
                destination.lastPathComponent, formatter.string(fromByteCount: required), formatter.string(fromByteCount: available)
            )
        case let .destinationInsideSource(source, _):
            return String(format: String(localized: "The folder “%@” can’t be put inside itself.", language: locale), source.lastPathComponent)
        case let .destinationIsReadOnly(destination):
            return String(format: String(localized: "“%@” is on a read-only volume.", language: locale), destination.lastPathComponent)
        case let .destinationNotWritable(destination, _):
            return String(format: String(localized: "You don’t have permission to write to “%@”.", language: locale), destination.lastPathComponent)
        case let .trashUnavailable(url):
            return String(format: String(localized: "The volume containing “%@” doesn’t have a Trash.", language: locale), url.lastPathComponent)
        case let .timedOut(seconds):
            let shown = seconds < 1 ? String(format: "%.1f", seconds) : String(Int(seconds))
            return String(format: String(localized: "The volume didn’t respond within %@ seconds.", language: locale), shown)
        case let .invalidName(_, reason):
            return reason.errorDescription
        case let .pathTooLong(item, resultingBytes, limitBytes):
            return String(
                format: String(localized: "The path of “%1$@” would be too long at the destination (%2$lld bytes; the limit is %3$lld).", language: locale),
                item.lastPathComponent, resultingBytes, limitBytes
            )
        case let .sourceChangedDuringOperation(url):
            return String(format: String(localized: "“%@” changed while it was being copied, so the operation was stopped.", language: locale), url.lastPathComponent)
        case let .nameTooLongForDestination(name, lengthBytes, limitBytes):
            return String(
                format: String(localized: "The name “%1$@” is too long for the destination (%2$lld bytes; the limit is %3$lld).", language: locale),
                name, lengthBytes, limitBytes
            )
        case let .fileTooLargeForDestination(item, size, limit):
            let formatter = ByteCountFormatter()
            return String(
                format: String(localized: "“%1$@” (%2$@) is larger than the destination volume allows (%3$@).", language: locale),
                item.lastPathComponent, formatter.string(fromByteCount: size), formatter.string(fromByteCount: limit)
            )
        case let .replaceBackupOrphaned(backup, target):
            return String(
                format: String(localized: "The original “%1$@” couldn’t be put back. It was kept as the hidden item “%2$@” in the same folder.", language: locale),
                target.lastPathComponent, backup.lastPathComponent
            )
        case let .itemLocked(url):
            return String(format: String(localized: "“%@” is locked.", language: locale), url.lastPathComponent)
        case let .replacedItemKept(backup, target):
            return String(
                format: String(localized: "“%1$@” was replaced, but the original couldn’t be moved to the Trash. It was kept as the hidden item “%2$@” in the same folder.", language: locale),
                target.lastPathComponent, backup.lastPathComponent
            )
        case let .sourceRemainsAfterMove(item, reason):
            return String(
                format: String(localized: "“%1$@” was copied to the destination, but the original couldn’t be removed, so both were kept. %2$@", language: locale),
                item.lastPathComponent, reason
            )
        }
    }
}

/// errno を表示言語の短い文へ。**strerror の英語を本文に混ぜない**(表示言語と食い違う)。
/// 言い分けて意味のあるものだけを持ち、残りは Foundation の説明(OS の言語)に任せる。
nonisolated enum PosixFailure {
    static func reason(_ code: Int32) -> String {
        let locale = AppLanguage.currentLocale
        switch code {
        case ENOSPC, EDQUOT:
            return String(localized: "There isn’t enough free space.", language: locale)
        case EACCES, EPERM:
            return String(localized: "You don’t have permission.", language: locale)
        case EROFS:
            return String(localized: "The volume is read-only.", language: locale)
        case ENAMETOOLONG:
            return String(localized: "The name or path is too long.", language: locale)
        case EEXIST:
            return String(localized: "An item with the same name already exists.", language: locale)
        case EFBIG:
            return String(localized: "The file is too large for the destination volume.", language: locale)
        case ENOENT:
            return String(localized: "The item could not be found.", language: locale)
        case ENOTEMPTY, EBUSY:
            return String(localized: "The item is in use. An app may have a file inside it open.", language: locale)
        default:
            return NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
        }
    }
}

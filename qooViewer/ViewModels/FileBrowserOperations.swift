import AppKit
import Combine
import Foundation

/// ファイルブラウザの書く操作の窓口(改善要望7 段階4、2026-09-13)。コピー・カット・ペースト・ゴミ箱・
/// 新規フォルダ・名前の変更・取り消し/やり直しを、リスト・アイコン・ツリー・メニューバーの全部が
/// **ここ1つ**を通して行う。
///
/// `FileBrowserState`が1つ持つ(ウインドウごと)。本を開いてファイルブラウザが画面から消えても生きているので、
/// 走っている操作は途中で捨てられない。
///
/// ■ 同時に走る操作は1本
/// 次の操作は前の操作が終わるのを待つ(`enqueue`)。2本を並べると、進捗の帯が2本要るうえ、
/// 前の操作の衝突の確認と次の操作の確認が重なる。
///
/// ■ 見せるのは`presenter`
/// 確認(完全削除・衝突)と問題の報告はここでは描かず、`FileBrowserOperationPresenting`へ渡す
/// (本番はウインドウのシート。テストは台本どおりに答える偽物)。**問題を見せる前に進捗の帯を片付ける**
/// (qooLibrary で、帯が出たままダイアログが出て「まだ動いている」ように見えた)。
///
/// ■ 「置き換える」
/// 置き換えの途中でアプリが落ちると、元の項目が隠しフォルダに退避されたまま残る(FileOperationServiceの
/// checkConflictのコメント)。退避は作る前に `ReplaceBackupJournal` へ記録し、次の起動で戻す
/// (`ReplaceBackupRecovery`)。それが入るまで(2026-09-13〜14)衝突の確認は「両方残す / スキップ / 中止」だけだった。
/// ゴミ箱の無い場所では置き換えた元をすぐに消すしかないので、確認の文でそう伝える(`replacingDeletesImmediately`)。
///
/// ■ 読み取り専用モード(決定事項 Q12、段階 8.5)
/// ON の間、ファイルを変える操作は**ここの入り口で断る**(`isReadOnly`)。メニュー・キー・D&D の経路ごとに判定を散らさない
/// ―― 画面の側は項目を淡色にするために同じ値を読むだけで、淡色にし忘れた経路があってもここで止まる。
/// 判定は**呼ばれた時点**で行う。走っている操作・すでに順番を待っている操作は止めない(次の操作から効く)。
/// 取り消しの履歴は消さず、ON の間は取り消し/やり直しを断るだけ。⌘C(ペーストボードへ載せるだけ)は断らない。
@MainActor
final class FileBrowserOperations: ObservableObject {
    /// いま走っている操作(進捗の帯)。nil なら帯を出さない。
    @Published private(set) var activity: FileBrowserActivity?

    weak var state: FileBrowserState?
    /// 確認と報告を見せる相手。ペインが出たときに本物を入れる。
    var presenter: (any FileBrowserOperationPresenting)?

    // 以下はテストで差し替える口(本番は既定のまま)。
    var fileOps: FileOperationService = .shared
    var pasteboard: NSPasteboard = .general
    /// ゴミ箱の有無の判定。FileIO の上で呼ばれる。
    var hasTrash: @Sendable (URL) -> Bool = { TrashAvailability.hasTrash(for: $0) }
    /// 移動する項目を、取り消しで元のフォルダへ戻せるか。FileIO の上で呼ばれる。
    var canPutBack: @Sendable (URL) -> Bool = { FileBrowserOperations.canPutBack($0) }
    /// 帯を出すまでの猶予(一瞬で終わる操作で帯がちらつかないように)。
    var activityRevealDelay: Duration = .milliseconds(400)

    private var queueTail: Task<Void, Never>?
    private var activityCancellation: Cancellation?

    init() {}

    // MARK: - 読み取り専用モード

    /// ファイルを変える操作を断るか(環境設定「読み取り専用」)。環境設定が届いていなければ断る側に倒す。
    var isReadOnly: Bool {
        state?.preferences?.fileBrowserReadOnly ?? true
    }

    // MARK: - 取り消し・やり直し

    var commandStack: FileCommandStack? { state?.commandStack }

    @discardableResult
    func undo() -> Task<Void, Never> {
        guard !isReadOnly else { return Task {} }
        return enqueue { [weak self] in
            guard let self, let stack = self.commandStack else { return }
            let outcome = await stack.undo()
            self.didChangeFileSystem(inUnknownScope: true)
            self.presentIfNeeded(outcome, isRedo: false)
        }
    }

    @discardableResult
    func redo() -> Task<Void, Never> {
        guard !isReadOnly else { return Task {} }
        return enqueue { [weak self] in
            guard let self, let stack = self.commandStack else { return }
            let outcome = await stack.redo()
            self.didChangeFileSystem(inUnknownScope: true)
            self.presentIfNeeded(outcome, isRedo: true)
        }
    }

    // MARK: - コピー・カット・ペースト

    /// ⌘C。ペーストボードへファイルの URL を書く(Finder へ貼ればコピーになる)。
    func copy(_ entries: [FileBrowserEntry]) {
        write(entries, cut: false)
    }

    /// ⌘X。書く内容は⌘Cと同じで、**アプリの中で覚えておく**(ペーストしたときに一致すれば移動)。
    /// Finder のカットの判定は非公開の API なので、Finder へ貼るとコピーになる(検討メモ §3.2)。
    func cut(_ entries: [FileBrowserEntry]) {
        // カットは移動の前段なので、読み取り専用の間は断る(ペーストボードにも書かない)。
        guard !isReadOnly else { return }
        write(entries, cut: true)
    }

    /// ペーストボードにファイルがあるか(メニューの淡色の判定。ファイルシステムには触らない)。
    var canPaste: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: Self.fileURLOptions)
    }

    /// ⌘V(`forceMove` なら ⌥⌘V「ここに項目を移動」)。`folder` へ貼る。
    ///
    /// カットした集合と**ペーストボードの集合がそのまま一致したときだけ移動**(他のアプリで別のものを
    /// コピーした後に、前のカットの記憶で移動してしまわない)。移動したらカットの記憶を消す。
    /// 同じフォルダへのコピーは「両方残す」で複製にする(Finder の「のコピー」に当たる。名前は `name 2`)。
    ///
    /// **Finder などほかのアプリでコピーした項目も、許可の無い場所から貼れる**(2026-09-14、許可を持たない Debug で実測)。
    /// ペーストボードから読んだ URL には、**その項目自身**への読み書きの許可が付く(フォルダなら中身ごと)。
    /// 拡張を添えずに型のバイト列だけを置いた URL でも同じだったので、付けているのは書き手ではなくペーストボードの側。
    /// 親フォルダへの許可は付かないが、⌥⌘V の移動は通る(元の削除は項目自身の許可で足りる)。
    /// ただし**その移動の取り消しは、元のフォルダへ書けず「アクセス権がありません」で失敗する**(運んだものは宛先に残る)。
    /// なので移動の前に確かめ、戻せない項目があれば「取り消せません」と尋ねる(`transfer` の中。2026-09-14)。
    @discardableResult
    func paste(into folder: URL, forceMove: Bool = false) -> Task<Void, Never> {
        guard !isReadOnly else { return Task {} }
        let urls = readPasteboardURLs()
        guard !urls.isEmpty else { return Task {} }
        let isMove = forceMove || (!(state?.cutPaths.isEmpty ?? true) && Self.paths(of: urls) == state?.cutPaths)
        if isMove { state?.setCutPaths([]) }
        return transfer(urls, to: folder, isMove: isMove)
    }

    /// 移動またはコピー(ペースト)。
    @discardableResult
    func transfer(_ urls: [URL], to folder: URL, isMove: Bool) -> Task<Void, Never> {
        guard !isReadOnly else { return Task {} }
        return transfer(moving: isMove ? urls : [], copying: isMove ? [] : urls, to: folder)
    }

    /// ドラッグ&ドロップ(段階4b)。移動とコピーが混ざった 1 回のドロップは**1 回の取り消しで戻る**
    /// (`CompositeFileCommand`。検討メモ §9)。
    @discardableResult
    func drop(_ plan: FileDropPlan, into folder: URL) -> Task<Void, Never> {
        guard !isReadOnly else { return Task {} }
        return transfer(moving: plan.moves, copying: plan.copies, to: folder)
    }

    private func transfer(moving moves: [URL], copying copies: [URL], to folder: URL) -> Task<Void, Never> {
        enqueue { [weak self] in
            guard let self else { return }
            let destinationPath = FileBrowserState.id(for: folder)
            let isInDestination = { (url: URL) in FileBrowserState.id(for: url.deletingLastPathComponent()) == destinationPath }
            // 自分のフォルダへの移動は何もしない(エンジンの決まり)ので、同じフォルダの項目は外す。
            var movers = moves.filter { !isInDestination($0) }
            let duplicates = copies.filter(isInDestination)
            var copiers = copies.filter { !isInDestination($0) }
            // **ロックされた項目の移動は先に尋ねる**(2026-09-14。以前は OS が断って「権限がありません」と出るだけだった)。
            // 「続ける」ならロックを外して運び、運んだ先で掛け直す。「ロックされた項目をスキップ」なら外す。
            var unlocksMovers = false
            if !movers.isEmpty {
                let candidates = movers
                let locked = await FileIO.perform {
                    let mounts = MountTable.current()
                    return candidates.filter { FileOperationService.movingIsBlockedByLock($0, to: folder, mounts: mounts) }
                }
                if !locked.isEmpty {
                    switch await self.presenter?.confirmLockedItems(locked, totalCount: movers.count + copies.count, action: .move) ?? .stop {
                    case .proceed:
                        unlocksMovers = true
                    case .skipLocked:
                        let lockedSet = Set(locked)
                        movers.removeAll { lockedSet.contains($0) }
                    case .stop:
                        return
                    }
                }
            }
            // **取り消しで戻せない移動は、先に尋ねる**(2026-09-14、ユーザー決定)。Finder などでコピーした許可の無い場所の
            // 項目は、項目自身の許可で移動できてしまうが、元のフォルダへは書けないので ⌘Z が「アクセス権がありません」で
            // 失敗する(paste のコメント)。「移動」なら取り消しに積まない(積むと ⌘Z が失敗の報告になるだけ)、
            // 「コピー」なら戻せない項目だけをコピーに変える(戻せる項目は移動のまま、全体を 1 回で取り消せる)。
            var movesAreUndoable = true
            if !movers.isEmpty {
                let canPutBack = self.canPutBack
                let candidates = movers
                let stranded = await FileIO.perform { candidates.filter { !canPutBack($0) } }
                if !stranded.isEmpty {
                    switch await self.presenter?.confirmIrreversibleMove(of: stranded, totalCount: movers.count + copies.count) ?? .stop {
                    case .move:
                        movesAreUndoable = false
                    case .copy:
                        let strandedSet = Set(stranded)
                        movers.removeAll { strandedSet.contains($0) }
                        copiers += stranded
                    case .stop:
                        return
                    }
                }
            }
            let cancellation = Cancellation()
            let options = self.transferOptions(policy: .ask, cancellation: cancellation)
            var commands: [any FileCommand] = []
            if !movers.isEmpty {
                var moveOptions = options
                moveOptions.unlockingLocked = unlocksMovers
                commands.append(MoveFilesCommand(
                    items: movers, destination: folder, options: moveOptions, isUndoable: movesAreUndoable, fileOps: self.fileOps
                ))
            }
            if !duplicates.isEmpty {
                // 同じフォルダへのコピーは複製(「両方残す」。Finder の「のコピー」に当たる)。
                var duplicate = options
                duplicate.conflictPolicy = .keepBoth
                commands.append(CopyFilesCommand(items: duplicates, destination: folder, options: duplicate, fileOps: self.fileOps))
            }
            if !copiers.isEmpty {
                commands.append(CopyFilesCommand(items: copiers, destination: folder, options: options, fileOps: self.fileOps))
            }
            guard !commands.isEmpty else { return }
            let urls = movers + duplicates + copiers
            let count = urls.count
            // 「コピー」を選んで移動がコピーに変わったものがあれば、題は「コピー」。
            let isMove = duplicates.isEmpty && copiers.isEmpty
            let command: any FileCommand = commands.count == 1
                ? commands[0]
                : CompositeFileCommand(displayName: Self.transferName(count: count, isMove: isMove), children: commands)
            let title = Self.activityTitle(count: count, isMove: isMove)
            await self.run(command, title: title, cancellation: cancellation, affected: [folder] + urls.map { $0.deletingLastPathComponent() }) { result in
                // 運んだものを選ぶ(今のフォルダへ貼ったとき)。
                let placed = commands.flatMap { child -> [URL] in
                    (child as? MoveFilesCommand)?.outcome.receipts.map(\.destination)
                        ?? (child as? CopyFilesCommand)?.outcome.receipts.map(\.destination) ?? []
                }
                return placed
            }
        }
    }

    // MARK: - ゴミ箱

    /// ⌘⌫。ゴミ箱の無い場所(ネットワーク共有)が混ざっていれば、「すぐに削除されます」と確認してから
    /// 完全に削除する(決定事項 Q4。取り消せない)。
    @discardableResult
    func moveToTrash(_ entries: [FileBrowserEntry]) -> Task<Void, Never> {
        guard !isReadOnly else { return Task {} }
        let selected = entries.filter { !$0.isVolume }.map(\.url)
        return enqueue { [weak self] in
            guard let self, !selected.isEmpty else { return }
            var urls = selected
            let hasTrash = self.hasTrash
            let canTrash = await FileIO.perform { TrashAvailability.hasTrash(forAll: selected, using: hasTrash) }
            if !canTrash {
                guard await self.presenter?.confirmImmediateDeletion(of: urls) == true else { return }
            }
            // ロックされた項目は確認してから(Finder と同じ「続ける / 中止」)。ゴミ箱へ送るなら項目自身のロックだけが
            // 邪魔をする(中にロックされた項目があるフォルダは送れる。実測)が、完全に削除するなら中の項目も見る。
            let candidates = urls
            let locked = await FileIO.perform {
                candidates.filter { canTrash ? FileOperationService.isLocked($0) : FileOperationService.containsLockedItem($0) }
            }
            var unlocking = false
            if !locked.isEmpty {
                let action: LockedItemAction = canTrash ? .trash : .deleteImmediately
                switch await self.presenter?.confirmLockedItems(locked, totalCount: urls.count, action: action) ?? .stop {
                case .proceed:
                    unlocking = true
                case .skipLocked:
                    let lockedSet = Set(locked)
                    urls.removeAll { lockedSet.contains($0) }
                    guard !urls.isEmpty else { return }
                case .stop:
                    return
                }
            }
            let command: any FileCommand = canTrash
                ? TrashFilesCommand(items: urls, unlockingLocked: unlocking, fileOps: self.fileOps)
                : DeleteFilesImmediatelyCommand(items: urls, unlockingLocked: unlocking, fileOps: self.fileOps)
            let locale = AppLanguage.currentLocale
            let title = urls.count == 1
                ? String(format: String(localized: "Moving “%@” to the Trash…", language: locale), urls[0].lastPathComponent)
                : String(format: String(localized: "Moving %lld items to the Trash…", language: locale), urls.count)
            await self.run(command, title: title, cancellation: nil, affected: urls.map { $0.deletingLastPathComponent() }) { _ in [] }
        }
    }

    // MARK: - 新規フォルダ・名前の変更

    /// 新規フォルダ。作ったら選んで、名前の編集を始めてもらう(`state.requestRename`)。
    @discardableResult
    func newFolder(in folder: URL) -> Task<Void, Never> {
        guard !isReadOnly else { return Task {} }
        return enqueue { [weak self] in
            guard let self else { return }
            let existing = await FileIO.perform {
                Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            }
            let name = FileNameValidation.untitledFolderName(existing: existing)
            let url = folder.appendingPathComponent(name, isDirectory: true)
            let command = CreateFolderCommand(url: url, fileOps: self.fileOps)
            await self.run(command, title: nil, cancellation: nil, affected: [folder]) { _ in [url] }
            if let state = self.state, FileBrowserState.id(of: state.currentFolder) == FileBrowserState.id(for: folder),
               await FileIO.perform({ FileOperationService.itemExists(at: url) }) {
                state.requestRename(FileBrowserState.id(for: url))
            }
        }
    }

    /// 名前の変更(インラインの編集が確定したとき)。同じ名前なら何もしない。
    @discardableResult
    func rename(_ entry: FileBrowserEntry, to newName: String) -> Task<Void, Never> {
        guard !isReadOnly else { return Task {} }
        let url = entry.url
        return enqueue { [weak self] in
            guard let self else { return }
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != url.lastPathComponent else { return }
            // ロックされた項目は尋ねてから(移動と同じ。2026-09-14)。
            var unlocking = false
            if await FileIO.perform({ FileOperationService.isLocked(url) }) {
                guard await self.presenter?.confirmLockedItems([url], totalCount: 1, action: .rename) == .proceed else { return }
                unlocking = true
            }
            let command = RenameFileCommand(item: url, newName: newName, unlockingLocked: unlocking, fileOps: self.fileOps)
            await self.run(command, title: nil, cancellation: nil, affected: [url.deletingLastPathComponent()]) { [weak self] _ in
                // **名前を変えた項目がまだ選ばれているときだけ**選び直す(2026-09-14)。アイコン表示で編集中に余白をクリックすると、
                // 焦点が外れて確定する間に余白のクリックが選択を外すが、確定した名前の変更が済んでから選び直していたので、
                // 選択が外れなかった(計画 §4.10)。Return で確定したときは選ばれたままなので、今までどおり選ぶ。
                guard self?.state?.selection.contains(FileBrowserState.id(for: url)) == true else { return [] }
                return command.receipt.map { [$0.renamed] } ?? []
            }
        }
    }

    // MARK: - 一括リネーム(段階 5)

    /// 複数の項目の「名前を変更…」。シートで方式を尋ね、Finder と同じ規則で名前を決めて(BulkRename)、全体を 1 回の取り消しで戻せる形で変える。
    ///
    /// 番号は**表示順**(`state.entries` の並び)に振る。選択は集合なので、渡された順のままだと Finder と違う順に番号が付く
    /// (qooLibrary で踏んだ)。名前は**押した時点で**決め直す(シートを開いている間にフォルダが変わっても、日付が進んでも、
    /// 付くのは押した瞬間の結果)。
    @discardableResult
    func bulkRename(_ entries: [FileBrowserEntry]) -> Task<Void, Never> {
        guard !isReadOnly else { return Task {} }
        let order = Dictionary((state?.entries ?? []).enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let targets = entries.filter { !$0.isVolume }
            .enumerated()
            .sorted { (order[$0.element.id] ?? Int.max, $0.offset) < (order[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element.url)
        return enqueue { [weak self] in
            guard let self, let state = self.state, let first = targets.first else { return }
            let folder = first.deletingLastPathComponent()
            let folderID = FileBrowserState.id(for: folder)
            guard targets.allSatisfy({ FileBrowserState.id(for: $0.deletingLastPathComponent()) == folderID }) else { return }
            let names = targets.map(\.lastPathComponent)
            guard let existing = await Self.names(in: folder),
                  let settings = await self.presenter?.requestBulkRename(
                      BulkRenameRequest(names: names, existingNames: existing, settings: state.bulkRenameSettings)
                  )
            else { return }
            state.bulkRenameSettings = settings
            let locale = AppLanguage.currentLocale
            let mode = settings.mode(locale: locale)
            guard BulkRename.canApply(mode) else { return }
            // シートを開いている間に Finder などで変わっていてもよいよう、押した時点の中身で決め直す。
            let current = await Self.names(in: folder) ?? existing
            let plan = BulkRename.plan(names: names, existingNames: current, mode: mode, locale: locale)
            if let problem = BulkRename.firstProblem(in: plan), let reason = problem.problem {
                // シートが押させないはずだが、決め直した結果で出たときの受け皿。何も変えない(Finder と同じ)。
                self.presenter?.showProblem(FileBrowserProblem(
                    title: String(localized: "The items couldn’t be renamed.", language: locale),
                    message: reason.message(for: problem.originalName, locale: locale)
                ))
                return
            }
            var renames = zip(targets, plan).filter { $0.1.isChanged }.map { (item: $0.0, newName: $0.1.newName) }
            guard !renames.isEmpty else { return }
            // ロックされた項目は尋ねてから(1 件の名前の変更と同じ)。
            let candidates = renames.map(\.item)
            let locked = await FileIO.perform { candidates.filter { FileOperationService.isLocked($0) } }
            var unlocking = false
            if !locked.isEmpty {
                switch await self.presenter?.confirmLockedItems(locked, totalCount: renames.count, action: .rename) ?? .stop {
                case .proceed:
                    unlocking = true
                case .skipLocked:
                    let lockedSet = Set(locked)
                    renames.removeAll { lockedSet.contains($0.item) }
                    guard !renames.isEmpty else { return }
                case .stop:
                    return
                }
            }
            let cancellation = Cancellation()
            let sink = ProgressSink { [weak self] progress in
                Task { @MainActor [weak self] in self?.report(progress) }
            }
            let command = BulkRenameFileCommand(
                renames: renames, unlockingLocked: unlocking, progress: sink, cancellation: cancellation, fileOps: self.fileOps
            )
            let title = String(format: String(localized: "Renaming %lld items…", language: locale), renames.count)
            await self.run(command, title: title, cancellation: cancellation, affected: [folder]) { _ in
                command.receipts.map(\.renamed)
            }
        }
    }

    // MARK: - 圧縮・展開(段階 6)

    /// 限度(伸長爆弾よけ)。**テストで小さくする口。**
    var extractionLimits = ArchiveExtractionLimits.standard

    /// 「ここに圧縮」(`choosingDestination` なら「保存先を選んで圧縮…」)。同じフォルダの項目を 1 つの zip に固める。
    /// 拡張子は環境設定(zip / cbz)。名前は 1 件ならその名前、複数ならフォルダの名前(ZipCompressor.archiveBaseName)。
    @discardableResult
    func compress(_ entries: [FileBrowserEntry], choosingDestination: Bool = false) -> Task<Void, Never> {
        guard !isReadOnly else { return Task {} }
        let urls = entries.filter { !$0.isVolume }.map(\.url)
        let fileExtension = state?.preferences?.fileBrowserCompressionFormat.fileExtension ?? "zip"
        return enqueue { [weak self] in
            guard let self, let first = urls.first else { return }
            let parent = first.deletingLastPathComponent()
            let parentID = FileBrowserState.id(for: parent)
            guard urls.allSatisfy({ FileBrowserState.id(for: $0.deletingLastPathComponent()) == parentID }) else { return }
            var destination = parent
            if choosingDestination {
                guard let chosen = await self.presenter?.chooseDestinationFolder(for: .compress(count: urls.count), startingAt: parent)
                else { return }
                destination = chosen
            }
            let cancellation = Cancellation()
            let command = CompressFilesCommand(
                items: urls, destination: destination, baseName: ZipCompressor.archiveBaseName(for: urls),
                fileExtension: fileExtension, progress: self.progressSink(), cancellation: cancellation, fileOps: self.fileOps
            )
            let locale = AppLanguage.currentLocale
            let title = urls.count == 1
                ? String(format: String(localized: "Compressing “%@”…", language: locale), first.lastPathComponent)
                : String(format: String(localized: "Compressing %lld items…", language: locale), urls.count)
            await self.run(command, title: title, cancellation: cancellation, affected: [destination]) { _ in
                command.receipt.map { [$0.destination] } ?? []
            }
        }
    }

    /// 「ここに展開」「〈名前〉に展開」(`choosingDestination` なら「展開先を選んで展開…」。置き方は `placement`)。
    /// 書庫でない項目は外す。1 冊ずつ順に展開し、全体で 1 回の取り消し。
    @discardableResult
    func extract(
        _ entries: [FileBrowserEntry], placement: ArchiveExtractor.Placement, choosingDestination: Bool = false
    ) -> Task<Void, Never> {
        guard !isReadOnly else { return Task {} }
        let archives = entries.filter(\.isExtractableArchive).map(\.url)
        let limits = extractionLimits
        return enqueue { [weak self] in
            guard let self, let first = archives.first else { return }
            var destination = first.deletingLastPathComponent()
            if choosingDestination {
                guard let chosen = await self.presenter?.chooseDestinationFolder(
                    for: .extract(count: archives.count), startingAt: destination
                ) else { return }
                destination = chosen
            }
            let cancellation = Cancellation()
            let command = ExtractArchivesCommand(
                archives: archives, destination: destination, placement: placement, limits: limits,
                progress: self.progressSink(), cancellation: cancellation, fileOps: self.fileOps
            )
            let locale = AppLanguage.currentLocale
            let title = archives.count == 1
                ? String(format: String(localized: "Extracting “%@”…", language: locale), first.lastPathComponent)
                : String(format: String(localized: "Extracting %lld archives…", language: locale), archives.count)
            await self.run(command, title: title, cancellation: cancellation, affected: [destination]) { _ in
                command.receipts.map(\.destination)
            }
        }
    }

    private func progressSink() -> ProgressSink {
        ProgressSink { [weak self] progress in
            Task { @MainActor [weak self] in self?.report(progress) }
        }
    }

    /// フォルダの中の名前全部(隠しファイルを含む)。読めなければ nil。
    private nonisolated static func names(in folder: URL) async -> Set<String>? {
        await FileIO.perform {
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)).map(Set.init)
        }
    }

    // MARK: - 進捗の帯

    /// 帯の中止ボタン。次の区切り(項目の境目・copyfile の callback)で止まる。
    func cancelActivity() {
        activityCancellation?.request()
    }

    /// 走っている(または待っている)操作が全部終わるまで待つ。**テストのための口。**
    func settle() async {
        while let task = queueTail {
            await task.value
            if queueTail == task { return }
        }
    }

    // MARK: - 下請け

    /// 前の操作が終わってから `work` を始める。
    @discardableResult
    private func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = queueTail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        queueTail = task
        return task
    }

    /// コマンドを積み場所で実行し、帯・読み直し・選択・報告までを済ませる。
    ///
    /// - Parameter placed: 成功後に選ぶ項目(今のフォルダの中のものだけが効く)。
    private func run(
        _ command: any FileCommand, title: String?, cancellation: Cancellation?, affected: [URL],
        placed: (FileCommandResult?) -> [URL]
    ) async {
        guard let stack = commandStack else { return }
        let token = title.map { beginActivity(title: $0, cancellation: cancellation) }
        var problem: FileBrowserProblem?
        var result: FileCommandResult?
        do {
            result = try await stack.run(command)
            if case let .partial(_, failures, wasCancelled)? = result, !failures.isEmpty, !wasCancelled {
                problem = FileBrowserProblem.partialFailure(operationName: command.displayName, failures: failures)
            }
        } catch let rollback as CompositeRollbackError {
            problem = FileBrowserProblem(title: rollback.localizedDescription, message: FileBrowserProblem.listing(rollback.failures))
        } catch {
            if !FileCommandStack.isCancellation(error) {
                problem = FileBrowserProblem(
                    title: String(
                        format: String(localized: "%@ couldn’t be completed.", language: AppLanguage.currentLocale),
                        command.displayName
                    ),
                    message: error.localizedDescription
                )
            }
        }
        if let token { endActivity(token) }
        didChangeFileSystem(affected: affected, selecting: placed(result))
        // **帯を片付けてから見せる**(型コメント)。
        if let problem { presenter?.showProblem(problem) }
    }

    private func beginActivity(title: String, cancellation: Cancellation?) -> UUID {
        let id = UUID()
        activityCancellation = cancellation
        let delay = activityRevealDelay
        let pending = FileBrowserActivity(id: id, title: title, progress: FileOperationProgress(), isCancellable: cancellation != nil)
        pendingActivity = pending
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, let pending = self.pendingActivity, pending.id == id else { return }
            self.activity = pending
        }
        return id
    }

    /// 帯を出す前(猶予の間)の進捗もここへ溜める(出した瞬間から正しい数字を見せる)。
    private var pendingActivity: FileBrowserActivity? {
        didSet {
            if activity != nil, let pendingActivity, activity?.id == pendingActivity.id { activity = pendingActivity }
        }
    }

    private func endActivity(_ id: UUID) {
        guard pendingActivity?.id == id else { return }
        pendingActivity = nil
        activity = nil
        activityCancellation = nil
    }

    private func report(_ progress: FileOperationProgress) {
        guard var pending = pendingActivity else { return }
        if pending.bytesStartedAt == nil, progress.completedBytes > 0 { pending.bytesStartedAt = Date() }
        pending.progress = progress
        pendingActivity = pending
    }

    private func transferOptions(policy: ConflictPolicy, cancellation: Cancellation) -> FileOperationOptions {
        let sink = ProgressSink { [weak self] progress in
            Task { @MainActor [weak self] in self?.report(progress) }
        }
        return FileOperationOptions(
            conflictPolicy: policy,
            conflictResolver: { [weak self] conflict in
                guard let self, let presenter = self.presenter else { return ConflictDecision(.skip) }
                let hasTrash = self.hasTrash
                let folder = conflict.destination.deletingLastPathComponent()
                let deletesImmediately = await FileIO.perform { !hasTrash(folder) }
                var answer = await presenter.resolveConflict(conflict, replacingDeletesImmediately: deletesImmediately, cancellation: cancellation)
                // 置き換えられる項目がロックされていたら、置き換える前に尋ねる(2026-09-14。以前はゴミ箱の無い場所で
                // 中のロックに当たって退避を消しきれず、次の起動で警告が出た ―― 計画 §4.11)。
                guard answer.policy == .replace else { return answer }
                let target = conflict.destination
                let blocked = await FileIO.perform {
                    FileOperationService.replacingIsBlockedByLock(target, deletesImmediately: deletesImmediately)
                }
                guard blocked else { return answer }
                switch await presenter.confirmLockedItems([target], totalCount: 1, action: .replace(deletesImmediately: deletesImmediately)) {
                case .proceed:
                    answer.unlockingLocked = true
                    return answer
                case .skipLocked, .stop:
                    // 衝突の確認の「中止」と同じ: 残りを止め、この項目はスキップ。
                    cancellation.request()
                    return ConflictDecision(.skip)
                }
            },
            progress: sink,
            cancellation: cancellation
        )
    }

    /// 操作のあとで一覧とツリーを読み直す。ネットワークでは FSEvents が飛ばないので、待たずに明示的に読む。
    /// - Parameter inUnknownScope: 取り消し・やり直し。どのフォルダが変わったか分からないので、ツリーには全体を
    ///   見直してもらう(以前は何も知らせず、取り消しで戻ったフォルダがツリーに出てこなかった。実機 2026-09-13)。
    private func didChangeFileSystem(affected: [URL] = [], selecting placed: [URL] = [], inUnknownScope: Bool = false) {
        guard let state else { return }
        let current = FileBrowserState.id(of: state.currentFolder)
        let selectable = Set(placed.filter { FileBrowserState.id(for: $0.deletingLastPathComponent()) == current }
            .map(FileBrowserState.id(for:)))
        state.reload(selecting: selectable.isEmpty ? nil : selectable)
        if inUnknownScope {
            state.noteFileSystemChangeInUnknownScope()
        } else {
            state.noteFileSystemChange(in: affected)
        }
    }

    private func presentIfNeeded(_ outcome: FileUndoOutcome, isRedo: Bool) {
        guard outcome.needsAttention, let problem = FileBrowserProblem.undo(outcome, isRedo: isRedo) else { return }
        presenter?.showProblem(problem)
    }

    private func write(_ entries: [FileBrowserEntry], cut: Bool) {
        let urls = entries.filter { !$0.isVolume }.map(\.url)
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        state?.setCutPaths(cut ? Self.paths(of: urls) : [])
    }

    private func readPasteboardURLs() -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: Self.fileURLOptions) as? [URL]) ?? []
    }

    private static let fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    /// `item` を移動したあと、取り消しで元のフォルダへ戻せるか = 元のフォルダへ書けるか。
    ///
    /// `access(W_OK)` はサンドボックスの判定も返す(2026-09-14 実測。Finder でコピーした項目の親フォルダは拒否、
    /// 許可のあるフォルダは通る、で許可の有無と一致した)。**読み取り専用のボリュームは戻せる扱い**にする ――
    /// そもそも移動が断られるので、尋ねてから失敗を報告する二度手間になる。
    ///
    /// **POSIX の権限で書けないフォルダも戻せる扱い**(2026-09-14、計画 §4.14)。そこから項目を出すにはそのフォルダへの
    /// 書き込みが要るので移動そのものが「権限がありません」で断られ、尋ねると「移動」を選んだ直後に失敗を見せる二度手間になる。
    /// 尋ねるのは「POSIX では書けるのに `access` が断る」= サンドボックスの許可が無いときだけ。
    nonisolated static func canPutBack(_ item: URL) -> Bool {
        let parent = item.deletingLastPathComponent()
        if (try? parent.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return true }
        if access(parent.path, W_OK) == 0 { return true }
        return !posixModeAllowsWrite(parent)
    }

    /// モードビットだけで見た、このプロセスがそのフォルダへ書けるか(ACL は見ない ―― ACL が許すフォルダでは
    /// 尋ねずに移動し、取り消しが失敗しうるが、以前の動作に戻るだけ)。stat できなければ書ける扱い(尋ねる側に倒す)。
    nonisolated static func posixModeAllowsWrite(_ folder: URL) -> Bool {
        var info = stat()
        guard stat(folder.path, &info) == 0 else { return true }
        let uid = geteuid()
        if uid == 0 { return true }
        if info.st_uid == uid { return info.st_mode & S_IWUSR != 0 }
        var groups = [gid_t](repeating: 0, count: Int(NGROUPS_MAX))
        let count = getgroups(Int32(groups.count), &groups)
        let isMember = info.st_gid == getegid() || (count > 0 && groups.prefix(Int(count)).contains(info.st_gid))
        if isMember { return info.st_mode & S_IWGRP != 0 }
        return info.st_mode & S_IWOTH != 0
    }

    /// カットの判定に使うパスの集合。**読み戻した URL は末尾の `/` などで `==` が外れる**(qooLibrary 実測)ので、
    /// 標準化したパスで比べる。
    nonisolated static func paths(of urls: [URL]) -> Set<String> {
        Set(urls.map { MountTable.normalized($0.standardizedFileURL.path) })
    }

    private static func transferName(count: Int, isMove: Bool) -> String {
        let locale = AppLanguage.currentLocale
        return isMove
            ? String(format: String(localized: "Move of %lld Items", language: locale), count)
            : String(format: String(localized: "Copy of %lld Items", language: locale), count)
    }

    private static func activityTitle(count: Int, isMove: Bool) -> String {
        let locale = AppLanguage.currentLocale
        return isMove
            ? String(format: String(localized: "Moving %lld items…", language: locale), count)
            : String(format: String(localized: "Copying %lld items…", language: locale), count)
    }
}

/// 進捗の帯に出す 1 本の操作。
struct FileBrowserActivity: Equatable, Identifiable {
    let id: UUID
    let title: String
    var progress: FileOperationProgress
    /// 中止ボタンを出すか(ゴミ箱は途中で止められない)。
    let isCancellable: Bool
    /// バイトが動き始めた時刻(残り時間の見積りはここからの平均速度。計測 1 秒未満なら出さない)。
    var bytesStartedAt: Date?

    init(id: UUID, title: String, progress: FileOperationProgress, isCancellable: Bool) {
        self.id = id
        self.title = title
        self.progress = progress
        self.isCancellable = isCancellable
    }

    /// 残り秒数。総量が分からない・動き始めて 1 秒未満・まだ速度が出ていないなら nil。
    func estimatedSecondsRemaining(now: Date = Date()) -> TimeInterval? {
        guard let started = bytesStartedAt, progress.totalBytes > 0, progress.completedBytes > 0 else { return nil }
        let elapsed = now.timeIntervalSince(started)
        guard elapsed >= 1 else { return nil }
        let rate = Double(progress.completedBytes) / elapsed
        guard rate > 0 else { return nil }
        return max(0, Double(progress.totalBytes - progress.completedBytes) / rate)
    }
}

/// 利用者に見せる問題 1 件(何が / なぜ / 次に何ができるか を title と message に入れる)。
struct FileBrowserProblem: Equatable {
    let title: String
    let message: String

    /// 一覧に並べる失敗の上限(超えた分は件数だけ)。
    static let listedFailureLimit = 10

    static func partialFailure(operationName: String, failures: [FailedItem]) -> FileBrowserProblem {
        let locale = AppLanguage.currentLocale
        return FileBrowserProblem(
            title: String(
                format: String(localized: "%@: Some items couldn’t be processed.", language: locale),
                operationName
            ),
            message: listing(failures, locale: locale)
        )
    }

    static func undo(_ outcome: FileUndoOutcome, isRedo: Bool) -> FileBrowserProblem? {
        let locale = AppLanguage.currentLocale
        switch outcome {
        case .nothingToDo, .complete:
            return nil
        case let .partial(name, _, failures):
            return FileBrowserProblem(
                title: String(
                    format: isRedo
                        ? String(localized: "%@ could only be partly redone.", language: locale)
                        : String(localized: "%@ could only be partly undone.", language: locale),
                    name
                ),
                message: listing(failures, locale: locale)
            )
        case let .failed(name, reason, canRetry):
            var message = reason
            if canRetry {
                message += "\n\n" + String(
                    localized: "It’s still in the Undo history, so you can try again after fixing the problem.", language: locale
                )
            }
            return FileBrowserProblem(
                title: String(
                    format: isRedo
                        ? String(localized: "%@ couldn’t be redone.", language: locale)
                        : String(localized: "%@ couldn’t be undone.", language: locale),
                    name
                ),
                message: message
            )
        }
    }

    static func listing(_ failures: [FailedItem], locale: Locale = AppLanguage.currentLocale) -> String {
        var lines = failures.prefix(listedFailureLimit).map { "\($0.name): \($0.reason)" }
        if failures.count > listedFailureLimit {
            lines.append(String(
                format: String(localized: "…and %lld more.", language: locale),
                failures.count - listedFailureLimit
            ))
        }
        return lines.joined(separator: "\n")
    }
}

/// ロックされた項目の確認で、何をしようとしているか(文面が変わる)。
enum LockedItemAction: Equatable {
    case trash
    case deleteImmediately
    case move
    case rename
    /// 衝突の「置き換える」。置き換えられる既存の項目がロックされている。
    case replace(deletesImmediately: Bool)
}

/// ロックされた項目の確認への答え。
enum LockedItemsDecision: Equatable {
    /// ロックを外して続ける。
    case proceed
    /// ロックされた項目だけを外して、残りで続ける(一部だけがロックされているときに出す)。
    case skipLocked
    case stop
}

/// 取り消せない移動の確認への答え。
enum IrreversibleMoveDecision: Equatable {
    /// 移動する(取り消しには積まない)。
    case move
    /// 戻せない項目だけコピーに変える(元はそのまま残る)。
    case copy
    /// 何もしない。
    case stop
}

/// 確認と報告を見せる相手(本番はシート、テストは偽物)。
@MainActor
protocol FileBrowserOperationPresenting: AnyObject {
    /// 「すぐに削除されます。取り消せません」。削除してよければ true。
    func confirmImmediateDeletion(of urls: [URL]) async -> Bool
    /// `urls` はロックされている。ロックを外して `action` を続けるか。
    /// - Parameter totalCount: 1 回の操作の項目の総数。`urls` がその一部なら「ロックされた項目をスキップ」も選べる。
    func confirmLockedItems(_ urls: [URL], totalCount: Int, action: LockedItemAction) async -> LockedItemsDecision
    /// 移動しようとした項目のうち `urls` は、元のフォルダへ書けないので取り消しで戻せない。
    /// - Parameter totalCount: 1 回の操作で運ぶ項目の総数(題に使う。`urls` はその一部のことがある)。
    func confirmIrreversibleMove(of urls: [URL], totalCount: Int) async -> IrreversibleMoveDecision
    /// 同じ名前の項目があった。「中止」は `cancellation.request()` してスキップを返す。
    /// - Parameter replacingDeletesImmediately: 宛先にゴミ箱が無く、「置き換える」と元の項目がすぐに消える。
    func resolveConflict(_ conflict: FileConflict, replacingDeletesImmediately: Bool, cancellation: Cancellation) async -> ConflictDecision
    /// 一括リネームのシート。「名称変更」なら入力を、「キャンセル」なら nil を返す。
    func requestBulkRename(_ request: BulkRenameRequest) async -> BulkRenameSettings?
    /// 「保存先を選んで圧縮…」「展開先を選んで展開…」のフォルダ選択。キャンセルなら nil。
    /// 選んだフォルダにはその場で読み書きの許可が付く(サンドボックス。NSOpenPanel)。
    func chooseDestinationFolder(for purpose: ArchiveDestinationPurpose, startingAt folder: URL) async -> URL?
    func showProblem(_ problem: FileBrowserProblem)
}

/// フォルダを選ぶ理由(パネルの文言が変わる)。
enum ArchiveDestinationPurpose: Equatable {
    case compress(count: Int)
    case extract(count: Int)
}

/// 一括リネームのシートに渡すもの(例の行と、使えない名前の判定に使う)。
struct BulkRenameRequest: Equatable {
    /// 対象の名前(表示順)。
    let names: [String]
    /// そのフォルダの名前全部。
    let existingNames: Set<String>
    /// 前回の入力。
    let settings: BulkRenameSettings
}

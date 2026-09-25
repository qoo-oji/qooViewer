import AppKit
import Combine
import Foundation
import QooMetaKit

/// ファイル名からメタデータを作って DB へ書く、**ただ 1 つの役**(アプリで 1 つ。`AppStores`)。2026-09-22。
///
/// ■ なぜ 1 つにしたか(docs/plans/metadata-generator-plan.md)
/// 以前は書き手が 5 つあった(メタデータの編集ウインドウ・スマートライブラリ・本を開いたとき・書誌の取り込み・規則の変更の
/// 読み直し)。見比べる本の範囲(qooMeta の錨)がそれぞれ違うので同じ本でも読みが変わり、DB には最後に書いた側の値が残った。
/// 書くたびの知らせでほかの書き手が集め直して書き、メタデータの編集ウインドウの直しが戻ることもあった(利用者の報告)。
/// 利用者の方針: **メタデータは本の情報で、どの機能の持ち物でもない。作るのは 1 か所。機能は本の一覧を記録するだけ、画面は読むだけ。**
///
/// ■ 母体(読む本)
/// このアプリが知っている本(読書位置・ブックマーク・レイアウト・お気に入り ―― `knownBooks`)・メタデータの行のある本・
/// 機能が記録した本の一覧(コレクションの本・スマートライブラリの対象フォルダの本 ―― `MetadataCorpusStore`)・この起動で開いた本。
/// **機能の ON/OFF では変わらない**(記録は OFF の間も残る)。対象外のフォルダ(`MetadataRulesStore.excludedFolders`)の本は入れない。
/// 行の無い本は、**記録どおりの場所に今あると確かめられた本だけ**を並べる(読書位置やコレクションは、アプリの外で消した・名前を
/// 変えた本の古いパスを覚えていることがある ―― 2026-09-22 の報告)。スマートライブラリが探した本と、この起動で開いた本は確かめ済み。
/// 確かめるのは 1 冊につき起動中に 1 度(ボリュームを付けたら、無かった本を確かめ直す)。
///
/// ■ 書くもの
/// 全冊を 1 つの qooMeta の索引(`ProposalIndex`)で読む(錨はいつも同じ母体で決まる)。行の無い本はロックせずに作り、ロックして
/// いない行は読みが変わったら値を書き直す。**ロックした行・直した欄・ロック・ルールセットは書かない**(それを書くのは利用者の操作の
/// 側 ―― メタデータの編集ウインドウ・1 冊ぶんのシート・書誌の取り込み・保存データの読み込み)。この起動の間に利用者が消した行は
/// 作り直さない(`BookMetadataStore.deletedThisSession`)。
///
/// ■ 動く契機(まとめて 1 本ずつ)
/// 行の形の変化(`bookMetadataDidChange`。自分の書き込みの知らせは読まない)・規則・対象外のフォルダ・記録した一覧・本を開いた・
/// ボリュームの着脱。メタデータの編集ウインドウは直したあと `update()` を待って、変わった本の提案を `updates` で受け取る。
@MainActor
final class MetadataGenerator {
    /// 読み終えた回の知らせ。`changedIDs` は提案が変わった本と、並びに加わった・外れた本。`isFull` なら全冊を読み直した(規則が変わった)。
    struct Update {
        let changedIDs: Set<String>
        let isFull: Bool
    }

    let updates = PassthroughSubject<Update, Never>()

    /// アプリの 1 つ(`AppStores` が起動時に入れる)。本を開いた知らせ(`ViewerViewModel`)がここへ届く。テストの中では nil。
    static weak var appWide: MetadataGenerator?

    /// 最後に読んだ規則。
    private(set) var rules: CompiledRules
    /// 並べている本(パスの順)。
    private(set) var listedBookIDs: [String] = [] {
        didSet { listedBookIDSet = Set(listedBookIDs) }
    }
    /// `listedBookIDs` を引くための写し(本を開くたびに並びの中を線形に探さない)。
    private var listedBookIDSet: Set<String> = []
    private(set) var proposals: [String: BookProposal] = [:]
    /// 索引に渡した入力(名前・ルールセット・確定した内容)。
    private(set) var inputs: [String: BookInput] = [:]
    /// 一度でも読み終えたか。
    private(set) var hasCompletedRun = false
    /// 自分が DB へ書いている最中(その知らせでは動かない)。
    private(set) var isWriting = false

    private let metadataStore: BookMetadataStore
    private let rulesStore: MetadataRulesStore
    private let corpusStore: MetadataCorpusStore
    /// このアプリが知っている本のうち、機能に属さないもの(読書位置・ブックマーク・レイアウト・お気に入り)。
    private let knownBooks: () -> Set<String>
    /// 行の無い本のうち、記録どおりの場所に今ある本を返す(ブロッキングする確かめは呼ばれた側が画面の外で)。
    private let probe: ([String]) async -> Set<String>

    private var index: ProposalIndex?
    private var indexRulesHash: String?
    /// 利用者がルールセットを選んでいた本(自動に戻されたら、自動の選択を選び直す)。
    private var overridden: Set<String> = []
    /// 記録どおりの場所にあると確かめた本 / 無かった本。
    private var verified: Set<String> = []
    private var absent: Set<String> = []
    private var tail: Task<Void, Never>?
    /// まだ始まっていない回が並んでいる(続けて頼まれても 1 回)。
    private var isQueued = false
    private var scheduled: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []

    init(metadataStore: BookMetadataStore, rulesStore: MetadataRulesStore, corpusStore: MetadataCorpusStore,
         knownBooks: @escaping () -> Set<String>, probe: @escaping ([String]) async -> Set<String>) {
        self.metadataStore = metadataStore
        self.rulesStore = rulesStore
        self.corpusStore = corpusStore
        self.knownBooks = knownBooks
        self.probe = probe
        rules = rulesStore.rules
    }

    /// 契機を受け始め、最初の回を頼む。
    func start(initialDelay: Duration = .zero) {
        guard subscriptions.isEmpty, observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .bookMetadataDidChange, object: metadataStore, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isWriting else { return }
                self.schedule()
            }
        })
        // 付け替えたロックしていない行(新しいファイル名で読み直す)。
        observers.append(center.addObserver(forName: .bookMetadataUnlockedRowsRelocated, object: metadataStore,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        })
        for name in [MetadataRulesStore.rulesDidChange, MetadataRulesStore.excludedFoldersDidChange] {
            observers.append(center.addObserver(forName: name, object: rulesStore, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // 付けたボリュームの本は、無かったのではなく見えなかっただけかもしれない。
                self?.absent = []
                self?.schedule()
            }
        })
        corpusStore.changes.sink { [weak self] in self?.schedule() }.store(in: &subscriptions)
        schedule(delay: initialDelay)
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        subscriptions = []
        scheduled?.cancel()
        scheduled = nil
    }

    /// 本を開いた(記録の残るウインドウで)。その本は記録どおりの場所にある。行を作るときは、その URL から本の場所の手がかり
    /// (ブックマークと識別子)も持たせる(アプリの外で名前を変えても行が付いていけるように。以前の `registerParsed` と同じ)。
    func noteBookOpened(_ bookID: String, sourceURL: URL? = nil) {
        verified.insert(bookID)
        absent.remove(bookID)
        if let sourceURL { sourceURLs[bookID] = sourceURL }
        // もう並べていて行もある本(2 度目以降に開いた本のほとんど)なら、回を頼まない(2026-09-25 の監査)。この本が加わっても
        // 母体・並び・入力・書くものは変わらない(並べている本は「確かめた」かどうかに関わらず並ぶ。行の中身が変われば
        // `bookMetadataDidChange` が回を頼む)のに、1 回ぶん(DB の全行の読み出し 2〜3 回・知っている本の収集・書く前の全冊の
        // 見比べ ―― 数千冊で約 0.1 秒)がメインで、最初の見開きを読んでいる最中に走っていた。
        // 消した本は別(開き直せばまた登録する。利用者の指示 2026-09-22: 削除しても覚えてはおかない)。ここで登録し直しの印を
        // 付けないのは、消していない本に印が残ると、後で利用者が消したときに次の回が作り直してしまうため。
        if hasCompletedRun, listedBookIDSet.contains(bookID), metadataStore.isRegistered(bookID: bookID),
           !metadataStore.deletedThisSession.contains(bookID) {
            return
        }
        reregistering.insert(bookID)
        schedule(delay: .milliseconds(100))
    }

    /// 本が移った・消えた(アプリの中の操作・アプリの外での移動を見つけた・開いたときの追従)。確かめ済みの本・無かった本・
    /// 開いた本の URL・登録し直す本を新しいパスへ付け替え、その場所から無くなった本は外す(2026-09-23 の 3 回目の監査の低)。
    /// 以前は付け替えなかったので、開いた本の名前を変えると、古いパスが「確かめ済み」のまま残って行の無い本として並び、
    /// 実在しないパスに読みだけの行を作った(その起動の間、メタデータの編集ウインドウに「見つからない」本として出た)。
    func relocate(using change: FileSystemChange) {
        let displaced = change.displacedPathSet
        guard !displaced.isEmpty else { return }
        func moved(_ id: String) -> String? {
            guard FileSystemChange.mayAffect(id, displaced: displaced) else { return id }
            if let path = change.relocatedPath(for: id) { return path }
            return change.displaces(id) ? nil : id
        }
        verified = Set(verified.compactMap(moved))
        absent = Set(absent.compactMap(moved))
        reregistering = Set(reregistering.compactMap(moved))
        var urls: [String: URL] = [:]
        for (id, url) in sourceURLs {
            guard let new = moved(id) else { continue }
            urls[new] = new == id ? url : URL(fileURLWithPath: new)
        }
        sourceURLs = urls
    }

    /// 開いた本の URL(行を作るときに渡す)。
    private var sourceURLs: [String: URL] = [:]
    /// この起動で利用者が消した本のうち、次の回で登録し直す本(開き直した・メタデータの編集ウインドウを開き直した)。
    /// ほかの契機(知らせ・規則の変更)では、消した本を作り直さない(消したそばから戻らないように)。
    private var reregistering: Set<String> = []

    /// 消した本を、次の回で登録し直す(メタデータの編集ウインドウを開いたとき。利用者の指示 2026-09-22: 窓を開き直せば
    /// また登録される)。
    func reregisterDeletedBooks() {
        reregistering.formUnion(metadataStore.deletedThisSession)
    }

    /// 少し待ってから読む(続けて頼まれたら最後から数える)。
    func schedule(delay: Duration = .milliseconds(300)) {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            self?.enqueue()
        }
    }

    /// すぐ読む(並んでいる回があればそれに乗る)。終わるまで待つ。
    func update() async {
        scheduled?.cancel()
        scheduled = nil
        enqueue()
        await settle()
    }

    /// 並んでいる回がすべて終わるまで待つ。
    func settle() async {
        while let current = tail {
            await current.value
            if tail == current { break }
        }
    }

    /// 索引を変えずに、入力を替えたら提案がどう変わるかを見る(メタデータの編集ウインドウの確かめ・鍵を外すとき)。
    func preview(_ changes: [BookChange]) async -> ProposalDelta? {
        await settle()
        guard let index else { return nil }
        return try? await index.preview(changes)
    }

    func proposal(for bookID: String) -> BookProposal? { proposals[bookID] }

    func input(for bookID: String) -> BookInput? { inputs[bookID] }

    private func enqueue() {
        guard !isQueued else { return }
        isQueued = true
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            self.isQueued = false
            await self.run()
        }
    }

    // MARK: - 1 回ぶん

    private func run() async {
        let rules = rulesStore.rules
        let sameRules = index != nil && indexRulesHash == rules.contentHash
        var records = metadataStore.allRecords()
        let smart = corpusStore.smartLibraryBookIDs
        var corpus = knownBooks()
        corpus.formUnion(corpusStore.collectionBookIDs)
        corpus.formUnion(smart)
        corpus.formUnion(records.keys)
        corpus.formUnion(verified)
        corpus = corpus.filter { !rulesStore.isExcluded(bookID: $0) }

        // 行の無い本は、記録どおりの場所にあるかを確かめてから(1 冊につき起動中に 1 度)。
        let toProbe = corpus.filter {
            records[$0] == nil && !smart.contains($0) && !verified.contains($0) && !absent.contains($0)
        }
        if !toProbe.isEmpty {
            let existing = await probe(toProbe.sorted())
            verified.formUnion(existing)
            absent.formUnion(toProbe.subtracting(existing))
            records = metadataStore.allRecords()
        }
        // 登録し直す本は、この回の始めの分だけを片付ける(読んでいる間に頼まれた分は次の回へ残す。同じ監査の低 ――
        // 以前は回の終わりに全部消していて、読んでいる間に開いた・編集ウインドウを開いた分の頼みが消えた)。
        let reregisteringNow = reregistering
        let deleted = metadataStore.deletedThisSession.subtracting(reregisteringNow)
        let listed = corpus.filter { id in
            records[id] != nil || ((smart.contains(id) || verified.contains(id)) && !deleted.contains(id))
        }.sorted()

        let previousInputs = sameRules ? inputs : [:]
        let previousOverridden = sameRules ? overridden : []
        let next = await Task.detached(priority: .userInitiated) {
            Self.inputs(for: listed, records: records, reusing: previousInputs,
                        previouslyOverridden: previousOverridden, rules: rules)
        }.value

        var nextProposals = sameRules ? proposals : [:]
        var changed = Set<String>()
        var isFull = false
        do {
            if sameRules, let index {
                let changes = Self.changes(from: previousInputs, to: next)
                if !changes.isEmpty {
                    let delta = try await index.apply(changes)
                    for proposal in delta.changed {
                        nextProposals[proposal.id] = proposal
                        changed.insert(proposal.id)
                    }
                    for id in delta.removedBooks {
                        nextProposals[id] = nil
                        changed.insert(id)
                    }
                }
            } else {
                let index = ProposalIndex(rules: rules, dictionaries: MetadataRulesStore.dictionaries)
                try await index.load(next.ordered)
                nextProposals = Dictionary(await index.snapshot().proposals.map { ($0.id, $0) },
                                           uniquingKeysWith: { _, b in b })
                self.index = index
                indexRulesHash = rules.contentHash
                isFull = true
            }
        } catch {
            return
        }
        let previousListed = listedBookIDSet
        changed.formUnion(Set(listed).symmetricDifference(previousListed))
        inputs = next.byID
        overridden = Set(next.byID.keys.filter { records[$0]?.ruleSet != nil })
        proposals = nextProposals
        self.rules = rules
        listedBookIDs = listed

        await write(listed: listed, snapshot: records, deleted: deleted)
        reregistering.subtract(reregisteringNow)
        hasCompletedRun = true
        if isFull || !changed.isEmpty { updates.send(Update(changedIDs: changed, isFull: isFull)) }
    }

    /// 読みを DB へ書く。行の無い本は作り、ロックしていない行は値が違えば書き直す。**読んでいる間に行の形(ロック・直した欄・
    /// ルールセット)が変わった本は書かない**(その変化で次の回が走り、新しい形で読み直す)。
    private func write(listed: [String], snapshot: [String: BookMetadataRecord], deleted: Set<String>) async {
        let current = metadataStore.allRecords()
        var entries: [BookMetadataStore.BatchEntry] = []
        for id in listed {
            guard let proposal = proposals[id] else { continue }
            let values = BookMetadataValues(proposal.metadata).trimmed
            switch (snapshot[id], current[id]) {
            case (nil, nil):
                guard !values.isEmpty, !deleted.contains(id) else { continue }
                entries.append(.init(bookID: id, values: values, sourceURL: sourceURLs[id],
                                     state: BookMetadataRowState(isLocked: false)))
            case let (before?, now?):
                // 読みが空になっても行は消さない(空の値の書き込みは行の削除になり、直した欄・ルールセット・取り込みの印まで消えた。
                // 2026-09-23 の 3 回目の監査の低)。
                guard !values.isEmpty, !now.isLocked, now.rowState == before.rowState, now.values != values else { continue }
                entries.append(.init(bookID: id, values: values, onlyIfUnlocked: true))
            default:
                continue
            }
        }
        var start = 0
        while start < entries.count {
            let end = min(start + BookMetadataStore.registrationBatchSize, entries.count)
            isWriting = true
            metadataStore.upsertAll(Array(entries[start..<end]))
            isWriting = false
            start = end
            if start < entries.count { try? await Task.sleep(for: .milliseconds(1)) }
        }
    }

    // MARK: - qooMeta へ渡す本

    /// 渡す本の一覧(入れる順 = パスの順)と、id からの引き。
    nonisolated struct Inputs: Sendable {
        var ordered: [BookInput] = []
        var byID: [String: BookInput] = [:]
    }

    /// 本ごとの入力。ロックした本は DB の値をすべて確定した内容として渡し(錨として、ほかの本のシリーズも決める)、
    /// ロックしていない本は直した欄とルールセットを渡す(`BookMetadataRecord.confirmation`)。
    /// 名前とルールセットの自動の選択は、`reusing` に同じ本があればそれを使う(規則が同じ間だけ渡される)。
    /// 利用者が選んだルールセットを自動に戻した本(`previouslyOverridden` にあり、今は選んでいない)は、使い回さずに自動の選択を
    /// 選び直す(2026-09-22 の監査。以前は前のルールセットのまま読み、その値を DB へ書いた ―― 規則が変わるか起動し直すまで)。
    nonisolated static func inputs(for paths: [String], records: [String: BookMetadataRecord],
                                   reusing previous: [String: BookInput], previouslyOverridden: Set<String> = [],
                                   rules: CompiledRules) -> Inputs {
        let ids = Set(paths).sorted()
        // 新しい本の名前とルールセットの自動の選択は並列に(2,439 冊を順に選ぶと 0.7 秒かかった。どちらも本ごとに独立した計算)。
        let fresh = ids.filter { previous[$0] == nil || (previouslyOverridden.contains($0) && records[$0]?.ruleSet == nil) }
        var readings = [(name: String, preset: String?)](repeating: ("", nil), count: fresh.count)
        let autoRules = MetadataRulesStore.autoPresetRules(of: rules)
        readings.withUnsafeMutableBufferPointer { buffer in
            // 各反復は自分の添字にだけ書く(重ならない)ので、同時に書いても安全。
            nonisolated(unsafe) let buffer = buffer
            DispatchQueue.concurrentPerform(iterations: fresh.count) { i in
                let name = MetadataRulesStore.parsingName(forBookID: fresh[i])
                buffer[i] = (name, MetadataRulesStore.autoPreset(forBookID: fresh[i], name: name, autoRules: autoRules))
            }
        }
        let freshByID = Dictionary(uniqueKeysWithValues: zip(fresh, readings))
        var result = Inputs()
        for id in ids {
            let record = records[id]
            let confirmation = record?.confirmation ?? .none
            let input: BookInput
            if let old = previous[id], freshByID[id] == nil {
                input = BookInput(id: id, name: old.name, preset: record?.ruleSet ?? old.preset, confirmation: confirmation)
            } else {
                let reading = freshByID[id] ?? (MetadataRulesStore.parsingName(forBookID: id), nil)
                input = BookInput(id: id, name: reading.name, preset: record?.ruleSet ?? reading.preset,
                                  confirmation: confirmation)
            }
            result.ordered.append(input)
            result.byID[id] = input
        }
        return result
    }

    /// 前に渡した本と今の本の差(足した・変わった本は upsert、無くなった本は remove)。
    nonisolated static func changes(from previous: [String: BookInput], to current: Inputs) -> [BookChange] {
        var changes: [BookChange] = []
        for input in current.ordered where previous[input.id] != input { changes.append(.upsert(input)) }
        for id in previous.keys.sorted() where current.byID[id] == nil { changes.append(.remove(id: id)) }
        return changes
    }
}

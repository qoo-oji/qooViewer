import Foundation
import Observation
import QooMetaKit
import QooMetaRules

/// 一覧の 1 冊(提案 + 利用者の修正)。画面はこれだけを見る。
///
/// qooMeta のアプリの `MetadataBookRow`(App/qooMeta/MetadataWorkspace.swift)を移したもの。違いは、本の ID がフルパス(qooViewer の
/// bookID)であることと、登録済みか(`isRegistered`)を持つこと。
nonisolated struct MetadataBookRow: Identifiable, Hashable, Sendable {
    /// 本の ID(bookID = フルパス)。
    let id: String
    /// 拡張子を除いたファイル名(型で読んだもの。隠せない列)。
    let fileName: String
    /// 名前が、どれかの型に合ったか。**型で読んだ結果そのもの(欄の位置など)は持たない** ―― 要るのは詳細に出す
    /// 1 冊ぶんだけで、その場で読み直せば済む。
    let matchedFormat: Bool
    /// 今の値(提案 + 利用者が直した欄。シリーズと巻は中核が導いたもの)。
    var metadata: QMBookMetadata
    /// 利用者の修正(欄・シリーズ・巻)。
    var confirmation: Confirmation
    var seriesID: SeriesID?
    var flags: Set<BookProposal.Flag>
    /// DB に登録してあるか(qooViewer のメタデータの行があるか)。**登録 = ロック**(利用者の決定 2026-09-21、案 A):
    /// 鍵を掛けた時点の値で登録し、鍵が掛かっている間は直せない。
    let isRegistered: Bool
    /// 本の実体が見つからない(灰色で出し、右クリックから保存データを削除できる)。
    let isMissing: Bool

    // 並べ替えの鍵(1 冊につき 1 度だけ作る。理由は qooMeta の MetadataBookRow のコメント)。
    private let authorsKey: String
    private let volumeKey: String
    private let seriesKey: String
    private let searchText: String
    /// ファイル名順での順位(小さいほうが先)。開いたときに 1 度だけ決める。
    let fileRank: Int
    /// 中身の見分け(1 冊につき 1 度だけ作る)。
    private let contentID: Int

    static func == (a: MetadataBookRow, b: MetadataBookRow) -> Bool { a.id == b.id && a.contentID == b.contentID }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init(_ proposal: BookProposal, confirmation: Confirmation, isRegistered: Bool, isMissing: Bool = false,
         fileRank: Int = 0) {
        self.fileRank = fileRank
        id = proposal.id
        fileName = proposal.name
        matchedFormat = proposal.reading.formatIndex != nil
        metadata = proposal.metadata
        self.confirmation = confirmation
        seriesID = proposal.seriesID
        flags = proposal.flags
        self.isRegistered = isRegistered
        self.isMissing = isMissing
        authorsKey = proposal.metadata.authors.count == 1 ? proposal.metadata.authors[0]
            : proposal.metadata.authors.joined(separator: "、")
        if let n = proposal.metadata.volumeSort {
            volumeKey = String(format: "%012.3f", n)
        } else {
            volumeKey = proposal.metadata.volume.isEmpty ? "\u{10FFFF}" : "~" + proposal.metadata.volume
        }
        seriesKey = proposal.metadata.series.isEmpty
            ? "\u{10FFFF}" + proposal.metadata.title : proposal.metadata.series + "\u{1}" + volumeKey
        searchText = ([proposal.name] + QMBookMetadata.Field.allCases.flatMap { proposal.metadata.values($0) })
            .joined(separator: "\u{1}")
        var hasher = Hasher()
        hasher.combine(proposal.metadata)
        hasher.combine(confirmation)
        hasher.combine(proposal.seriesID)
        hasher.combine(proposal.flags)
        hasher.combine(proposal.name)
        hasher.combine(isRegistered)
        hasher.combine(isMissing)
        contentID = hasher.finalize()
    }

    /// 提案はそのまま、確定した内容と登録の有無だけを替えた行。
    func with(confirmation: Confirmation, isRegistered: Bool, isMissing: Bool) -> MetadataBookRow {
        MetadataBookRow(copying: self, confirmation: confirmation, isRegistered: isRegistered, isMissing: isMissing)
    }

    private init(copying row: MetadataBookRow, confirmation: Confirmation, isRegistered: Bool, isMissing: Bool) {
        id = row.id
        fileName = row.fileName
        matchedFormat = row.matchedFormat
        metadata = row.metadata
        self.confirmation = confirmation
        seriesID = row.seriesID
        flags = row.flags
        self.isRegistered = isRegistered
        self.isMissing = isMissing
        authorsKey = row.authorsKey
        volumeKey = row.volumeKey
        seriesKey = row.seriesKey
        searchText = row.searchText
        fileRank = row.fileRank
        var hasher = Hasher()
        hasher.combine(row.contentID)
        hasher.combine(confirmation)
        hasher.combine(isRegistered)
        hasher.combine(isMissing)
        contentID = hasher.finalize()
    }

    func matches(_ query: String) -> Bool { searchText.localizedCaseInsensitiveContains(query) }

    /// 利用者が直した(確定した)欄。
    var edited: Set<QMBookMetadata.Field> { Set(confirmation.fields.values.keys) }

    /// 直したが、まだロック(登録)していない欄があるか(一覧で青く出す)。
    var hasUnregisteredEdits: Bool { !isRegistered && (!edited.isEmpty || hasConfirmedSeries) }

    /// シリーズか巻を利用者が確定しているか(一覧と詳細の印)。
    var hasConfirmedSeries: Bool {
        switch confirmation {
        case .none, .fields: false
        case .series, .notInSeries: true
        }
    }

    subscript(text field: QMBookMetadata.Field) -> String {
        metadata.values(field).joined(separator: "、")
    }

    var volumeSortText: String {
        metadata.volumeSort.map(QMBookMetadata.volumeSortText) ?? ""
    }

    subscript(sortKey field: QMBookMetadata.Field) -> String {
        switch field {
        case .authors: authorsKey
        case .volume: volumeKey
        case .series: seriesKey
        default: metadata[field]
        }
    }

    /// DB に書く値。
    var values: BookMetadataValues { BookMetadataValues(metadata) }
}

/// 絞り込みの値: 値か「(空)」。
nonisolated enum MetadataValueKey: Hashable, Comparable {
    case empty
    case value(String)

    var label: String {
        switch self {
        case .empty: "(empty)".ui
        case .value(let v): v
        }
    }
}

/// 「メタデータの編集」ウインドウの中身: このアプリが知っている本の一覧と、それへの修正。
///
/// qooMeta のアプリの 3 ページ目(確認・編集)の `MetadataWorkspace` を移したもの(docs/plans/qoometa-smart-library-plan.md)。
/// 本当の持ちものは「本ごとの入力(名前・ルールセット・確定した内容)」で、画面に出す提案は qooMeta が導いたもの。
/// 直すたびに全冊を計算し直さず、変更の索引(`ProposalIndex`)に変わった本だけを渡す。
///
/// ■ qooViewer での違い
/// - **ロック = 登録**(利用者の決定 2026-09-21、案 A。最初は「直したらすぐ登録」だったが、ロックと登録が別の考えに見えて
///   分かりにくかった)。直した値は DB へは書かず下書き(`MetadataDraftStore`。窓を閉じても残る)として持ち、鍵を掛けた時点の
///   値で登録する。登録した本は**すべての欄を確定した内容**として渡す(`BookMetadataValues.confirmation`)ので、規則を変えても
///   値は変わらず、鍵を外すまで直せない。鍵を外すと DB の行を消し、見えていた値は下書きに残る。
/// - 取り消し(⌘Z)は下書きの直しだけ。ロックと削除は DB へ書く操作なので歩みに入れない。
/// - ルールセットは本ごとに自動で選ぶ(qooMeta の段 2 の「自動」と同じ条件。決まらない本は既定のルールセット)。
///   右クリックの「読み直す」で本ごとに替えられる(替えたルールセットも下書きに残る)。
@MainActor @Observable
final class MetadataWorkspace {
    private(set) var books: [MetadataBookRow] = []
    /// 計算し直している最中か。
    var isWorking: Bool { working > 0 }
    private var working = 0

    private(set) var rules: CompiledRules
    private(set) var formats: FormatPresets
    /// 本ごとの入力(ID → 名前・ルールセット・確定した内容)。これが持ちもの。
    private var inputs: [String: BookInput]
    /// 自動で選んだルールセット(決まらなければ nil)。規則を替えたら選び直す。
    private var autoPresets: [String: String]
    /// 利用者が右クリックで選んだルールセット(自動より優先)。
    private var presetOverrides: [String: String] = [:]
    /// 登録済みの本。
    private var registered: Set<String>
    /// 実体が見つからない本(窓を開いたあとに、画面の外で確かめた結果)。
    private var missing: Set<String> = []
    /// 入れた順。
    private var order: [String]
    private var positionByID: [String: Int] = [:]
    private var sortedPositions: [Int] = []
    private var fileRanks: [String: Int] = [:]
    private var isBatching = false
    private var pendingSearch: Task<Void, Never>?
    private var reloading: Task<[MetadataBookRow]?, Never>?
    private let index: ProposalIndex
    /// 索引への変更は入れた順に流す。
    private var tail: Task<Void, Never>?
    /// DB へ書く口(登録・登録を外す)。書いた結果として届く変更の知らせを、自分の変更として無視するための印も持つ。
    @ObservationIgnored var writeBack: (([BookMetadataStore.BatchEntry]) -> Void)?
    /// 直したが登録していない値(下書き)が変わった本を知らせる口(持ち主がファイルへ残す。MetadataDraftStore)。
    @ObservationIgnored var draftsChanged: (([String: MetadataDraftStore.Draft?]) -> Void)?
    /// いま DB へ書いている最中(その知らせで、自分の行を読み直さない)。
    @ObservationIgnored private(set) var isWritingBack = false

    var genreFilter: MetadataValueKey? { didSet { if genreFilter != oldValue { filtersChanged(countsToo: true) } } }
    var authorFilter: MetadataValueKey? { didSet { if authorFilter != oldValue { filtersChanged() } } }
    var stateFilter: StateFilter = .all { didSet { if stateFilter != oldValue { filtersChanged() } } }
    var searchText = "" { didSet { if searchText != oldValue { searchChanged() } } }
    var selection: Set<MetadataBookRow.ID> = [] { didSet { if selection != oldValue { selectionChanged() } } }
    var sortOrder: [KeyPathComparator<MetadataBookRow>] = [KeyPathComparator(\MetadataBookRow.fileRank)] {
        didSet { if sortOrder != oldValue { sortAll(); applyFilters() } }
    }

    private(set) var selectedBooks: [MetadataBookRow] = []
    private(set) var selectionToken = 0
    private(set) var visiblePositions: [Int] = []
    var rows: [MetadataBookRow] { visiblePositions.map { books[$0] } }
    private(set) var genreValues: [(key: MetadataValueKey, count: Int)] = []
    private(set) var authorValues: [(key: MetadataValueKey, count: Int)] = []

    /// 本の状態での絞り込み(qooMeta の「シリーズを確定した本」は持たない ―― 確定という段階は、ロック = 登録と紛らわしいので
    /// 右クリックからも外した。利用者の指示 2026-09-21)。qooViewer では「型に合わなかった」(2 ページ目を持たない代わりの入口。利用者の指示
    /// 2026-09-21)と、登録の有無を足した。
    enum StateFilter: String, CaseIterable, Identifiable {
        case all, unmatched, missing, notRegistered, registered, notInSeries, noVolume, edited
        var id: Self { self }
        var label: String {
            switch self {
            case .all: "All".ui
            case .unmatched: "Matched no file name format".ui
            case .missing: "Book not found".ui
            case .notRegistered: "Not locked".ui
            case .registered: "Locked".ui
            case .notInSeries: "Not in a series".ui
            case .noVolume: "No volume".ui
            case .edited: "Edited but not locked".ui
            }
        }
        func contains(_ book: MetadataBookRow) -> Bool {
            switch self {
            case .all: true
            case .unmatched: !book.matchedFormat
            case .missing: book.isMissing
            case .notRegistered: !book.isRegistered
            case .registered: book.isRegistered
            case .notInSeries: book.seriesID == nil && book.metadata.series.isEmpty
            case .noVolume: book.metadata.volume.isEmpty
            case .edited: book.hasUnregisteredEdits
            }
        }
    }

    // MARK: - 開く

    /// 1 冊ぶんの入口。
    struct Entry: Sendable {
        let bookID: String
        /// 登録済みならその値(すべて確定した内容として渡す)。
        let registeredValues: BookMetadataValues?
        /// 直したが登録していない値(下書き)。
        var draft: MetadataDraftStore.Draft?
    }

    private init(inputs: [BookInput], autoPresets: [String: String], registered: Set<String>,
                 overrides: [String: String], rules: CompiledRules) {
        presetOverrides = overrides
        self.rules = rules
        formats = rules.formats
        self.inputs = Dictionary(inputs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.autoPresets = autoPresets
        self.registered = registered
        var seen = Set<String>()
        order = inputs.map(\.id).filter { seen.insert($0).inserted }
        index = ProposalIndex(rules: rules, dictionaries: MetadataRulesStore.dictionaries)
    }

    /// 開く(最初の計算まで待つ)。名前の正規化とルールセットの自動の選択も main の外で行う。
    static func open(_ entries: [Entry], rules: CompiledRules) async -> MetadataWorkspace {
        let prepared = await Task.detached(priority: .userInitiated) { () -> ([BookInput], [String: String], Set<String>) in
            var inputs: [BookInput] = []
            var autos: [String: String] = [:]
            var registered = Set<String>()
            inputs.reserveCapacity(entries.count)
            let autoRules = MetadataRulesStore.autoPresetRules(of: rules)
            for entry in entries {
                let name = MetadataRulesStore.parsingName(forBookID: entry.bookID)
                let auto = MetadataRulesStore.autoPreset(forBookID: entry.bookID, name: name, autoRules: autoRules)
                if let auto { autos[entry.bookID] = auto }
                if entry.registeredValues != nil { registered.insert(entry.bookID) }
                // 登録済み(ロック)ならその値、そうでなければ下書き(直したが登録していない値)。
                let draft = entry.registeredValues == nil ? entry.draft : nil
                inputs.append(BookInput(id: entry.bookID, name: name, preset: draft?.preset ?? auto,
                                        confirmation: entry.registeredValues?.confirmation ?? draft?.confirmation ?? .none))
            }
            return (inputs, autos, registered)
        }.value
        var overrides: [String: String] = [:]
        for entry in entries where entry.registeredValues == nil {
            if let preset = entry.draft?.preset { overrides[entry.bookID] = preset }
        }
        let workspace = MetadataWorkspace(inputs: prepared.0, autoPresets: prepared.1, registered: prepared.2,
                                          overrides: overrides, rules: rules)
        await workspace.recomputeAll()
        return workspace
    }

    /// 規則を替える(規則の窓で方針や型を変えたとき)。すべての本を読み直し、ルールセットの自動の選択もやり直す。
    ///
    /// **本の修正と同じ列(`tail`)に並べる**(qooMeta の MetadataWorkspace.setRules のコメント)。
    func setRules(_ rules: CompiledRules) async {
        guard rules.contentHash != self.rules.contentHash else { return }
        self.rules = rules
        formats = rules.formats
        reloading?.cancel()
        let previous = tail
        working += 1
        let task = Task { [index] in
            await previous?.value
            // ルールセットの自動の選択をやり直し、変わった本の入力を替えてから読み直す(読み直しは 1 回で済む)。
            let names = self.inputs.mapValues(\.name)
            let autos = await Task.detached { () -> [String: String] in
                var autos: [String: String] = [:]
                let autoRules = MetadataRulesStore.autoPresetRules(of: rules)
                for (id, name) in names {
                    if let auto = MetadataRulesStore.autoPreset(forBookID: id, name: name, autoRules: autoRules) { autos[id] = auto }
                }
                return autos
            }.value
            self.autoPresets = autos
            // ルールセットが変わった本の入力。**`inputs` へ書くのは読み直しが通ってから**(2026-09-22 の監査で指摘): 先に
            // 書いてから次の規則の変更で取り消されると、索引は前のルールセットのまま `inputs` だけ新しくなり、次の
            // `setRules` は「変わっていない」と見て渡さなかった(その本は前のルールセットで読まれ続け、鍵を掛けるとその
            // 読みで登録された)。書かずに取り消されても、次の `setRules` がもう一度渡す(同じ入力の upsert は何度でもよい)。
            var updated: [String: BookInput] = [:]
            var changed: [BookChange] = []
            for id in self.order {
                let preset = self.presetOverrides[id] ?? autos[id]
                guard var input = self.inputs[id], input.preset != preset else { continue }
                input.preset = preset
                updated[id] = input
                changed.append(.upsert(input))
            }
            let confirmations = self.inputs.mapValues(\.confirmation), ranks = self.fileRanks, registered = self.registered
            let missing = self.missing
            let work = Task.detached { () -> [MetadataBookRow]? in
                do {
                    if !changed.isEmpty { try await index.apply(changed) }
                    try await index.reload(rules: rules, dictionaries: MetadataRulesStore.dictionaries)
                } catch { return nil }
                return await index.snapshot().proposals.map {
                    MetadataBookRow($0, confirmation: confirmations[$0.id] ?? .none,
                                    isRegistered: registered.contains($0.id),
                                    isMissing: missing.contains($0.id), fileRank: ranks[$0.id] ?? 0)
                }
            }
            self.reloading = work
            if let rows = await work.value {
                for (id, input) in updated { self.inputs[id] = input }
                self.replaceBooks(rows)

            }
            self.working -= 1
        }
        tail = task
        await task.value
    }

    // MARK: - 計算

    private func recomputeAll() async {
        working += 1
        let all = order.compactMap { inputs[$0] }
        let confirmations = inputs.mapValues(\.confirmation), registered = self.registered
        let missing = self.missing
        let (rows, ranks) = await Task.detached { [index] in
            try? await index.load(all)
            let byName = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let ranks = Dictionary(byName.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
            let rows = await index.snapshot().proposals.map {
                MetadataBookRow($0, confirmation: confirmations[$0.id] ?? .none,
                                isRegistered: registered.contains($0.id),
                                isMissing: missing.contains($0.id), fileRank: ranks[$0.id] ?? 0)
            }
            return (rows, ranks)
        }.value
        fileRanks = ranks
        replaceBooks(rows)
        working -= 1
    }

    /// 変わった本だけを索引へ渡す。着いたら、登録済みの本の DB を行に合わせる(`alsoWrite` は、提案が変わらなくても
    /// 書き直す本 ―― 登録を外した本・登録した本)。
    private func push(_ changedIDs: [String], alsoWrite: Set<String> = []) {
        let changes = changedIDs.compactMap { inputs[$0] }.map { BookChange.upsert($0) }
        guard !changes.isEmpty || !alsoWrite.isEmpty else { return }
        let previous = tail
        working += 1
        tail = Task { [index] in
            await previous?.value
            let delta = changes.isEmpty ? nil : await Task.detached { try? await index.apply(changes) }.value
            if let delta { self.absorb(delta) }
            // 錨の効果で、選んでいない本の提案も変わる。登録済みの本なら、その値も DB へ。
            var toWrite = alsoWrite
            for proposal in delta?.changed ?? [] where self.registered.contains(proposal.id) { toWrite.insert(proposal.id) }
            self.writeRows(toWrite)
            self.working -= 1
        }
    }

    /// 登録の有無と行の値を DB へ書く(登録済みなら行の値、そうでなければ行を消す)。
    private func writeRows(_ ids: Set<String>) {
        guard let writeBack, !ids.isEmpty else { return }
        let entries = ids.sorted().compactMap { id -> BookMetadataStore.BatchEntry? in
            guard let row = row(id) else { return nil }
            return BookMetadataStore.BatchEntry(bookID: id, values: registered.contains(id) ? row.values : nil)
        }
        isWritingBack = true
        writeBack(entries)
        isWritingBack = false
    }

    private func absorb(_ delta: ProposalDelta) {
        var changed: [Int] = []
        var books = self.books
        self.books = []
        for proposal in delta.changed {
            guard let position = positionByID[proposal.id] else { continue }
            books[position] = MetadataBookRow(proposal, confirmation: inputs[proposal.id]?.confirmation ?? .none,
                                              isRegistered: registered.contains(proposal.id),
                                              isMissing: missing.contains(proposal.id),
                                              fileRank: fileRanks[proposal.id] ?? 0)
            changed.append(position)
        }
        self.books = books
        resort(changed)
        booksChanged()
    }

    /// 提案は変わらず、登録の有無だけが変わった本の行を作り直す。
    private func refreshRegistration(_ ids: some Sequence<String>) {
        var changed: [Int] = []
        for id in ids {
            guard let position = positionByID[id] else { continue }
            let old = books[position]
            guard old.isRegistered != registered.contains(id) || old.confirmation != inputs[id]?.confirmation
                    || old.isMissing != missing.contains(id) else { continue }
            // 提案そのものは変わっていないので、行の中の提案の値から作り直す。
            books[position] = old.with(confirmation: inputs[id]?.confirmation ?? .none, isRegistered: registered.contains(id),
                                       isMissing: missing.contains(id))
            changed.append(position)
        }
        guard !changed.isEmpty else { return }
        resort(changed)
        booksChanged()
    }

    private func replaceBooks(_ rows: [MetadataBookRow]) {
        books = rows
        positionByID = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        sortAll()
        booksChanged()
    }

    private func booksChanged() {
        isBatching = true
        rebuildCounts()
        if let g = genreFilter, !genreValues.contains(where: { $0.key == g }) {
            genreFilter = nil
            rebuildCounts()
        }
        if let a = authorFilter, !authorValues.contains(where: { $0.key == a }) { authorFilter = nil }
        isBatching = false
        applyFilters()
    }

    // MARK: - ほかの画面が DB を変えたとき

    /// 1 冊ぶんのシート・保存データの読み込み・ビューアの取り込みなど、この窓の外で DB が変わったとき、その本の
    /// 入力を DB に合わせる(`values` が nil なら登録が外れた)。取り消しの歩みには入れない。
    func applyExternalChanges(_ changes: [String: BookMetadataValues?]) {
        var changedIDs: [String] = []
        for (id, values) in changes {
            guard var input = inputs[id] else { continue }
            let wasRegistered = registered.contains(id)
            if let values {
                registered.insert(id)
                let confirmation = values.confirmation
                // 同じ値なら何もしない(この窓が書いた値が知らせとして戻ってきただけ)。
                if wasRegistered, row(id)?.values == values.trimmed { continue }
                input.confirmation = confirmation
            } else {
                guard wasRegistered else { continue }
                registered.remove(id)
                input.confirmation = .none
                presetOverrides[id] = nil
                input.preset = autoPresets[id]
            }
            inputs[id] = input
            changedIDs.append(id)
        }
        guard !changedIDs.isEmpty else { return }
        refreshRegistration(changedIDs)
        push(changedIDs)
    }

    /// 流している変更(索引への反映と DB への書き戻し)がすべて終わるまで待つ(テストと、書き出す前の確かめ用)。
    func settle() async {
        while let current = tail {
            await current.value
            if tail == current { break }
        }
    }

    /// その本が一覧にあるか。
    func contains(_ id: String) -> Bool { inputs[id] != nil }

    /// 一覧にある本の ID(外の変更を確かめるとき)。
    var bookIDs: [String] { order }

    // MARK: - まとめて書き換える

    func set(_ field: QMBookMetadata.Field, to newValues: [String], for ids: Set<MetadataBookRow.ID>) {
        let values = newValues.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        edit("Change %@".ui(field.labelKey.ui), ids) { input in
            var fields = input.confirmation.fields
            fields[field] = values
            input.confirmation = input.confirmation.withFields(fields)
        }
    }

    func revert(_ field: QMBookMetadata.Field, for ids: Set<MetadataBookRow.ID>) {
        edit("Revert %@ to the proposal".ui(field.labelKey.ui), ids) { input in
            var fields = input.confirmation.fields
            fields[field] = nil
            input.confirmation = input.confirmation.withFields(fields)
        }
    }

    // MARK: - シリーズの操作

    func suggestedSeriesName(for ids: Set<MetadataBookRow.ID>) -> String? {
        BulkEdit.suggestedSeriesName(forTitles: ids.compactMap { positionByID[$0] }.sorted().map { books[$0].metadata.title },
                                     rules: rules)
    }

    func setSeries(_ name: String, for ids: Set<MetadataBookRow.ID>) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        edit("Set the series to “%@”".ui(trimmed), ids) { input in
            let volume = self.row(input.id).flatMap(Self.confirmedVolume)
            input.confirmation = .series(name: trimmed, volume: volume, fields: input.confirmation.fields)
        }
    }

    func removeFromSeries(_ ids: Set<MetadataBookRow.ID>) {
        edit("Remove from the series".ui, ids) { input in
            input.confirmation = .notInSeries(fields: input.confirmation.fields)
        }
    }

    func numberSequentially(_ orderedIDs: [MetadataBookRow.ID], start: Int = 1, step: Int = 1, width: Int = 0) {
        var numbers: [String: (name: String, volume: String)] = [:]
        var number = start
        for id in orderedIDs {
            guard let name = row(id).map(Self.currentSeriesName), !name.isEmpty else { continue }
            let digits = String(abs(number))
            numbers[id] = (name, (number < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - digits.count)) + digits)
            number += step
        }
        edit("Number the volumes again".ui, numbers.keys) { input in
            guard let (name, volume) = numbers[input.id] else { return }
            input.confirmation = .series(name: name, volume: volume, fields: input.confirmation.fields)
        }
    }

    func setVolumes(_ volume: String, for ids: Set<MetadataBookRow.ID>) {
        edit("Set the volume".ui, ids) { input in
            guard let name = self.row(input.id).map(Self.currentSeriesName), !name.isEmpty else { return }
            input.confirmation = .series(name: name, volume: volume, fields: input.confirmation.fields)
        }
    }

    func clearVolumes(_ ids: Set<MetadataBookRow.ID>) {
        edit("Clear the volume".ui, ids) { input in
            guard let name = self.row(input.id).map(Self.currentSeriesName), !name.isEmpty else { return }
            input.confirmation = .series(name: name, volume: "", fields: input.confirmation.fields)
        }
    }

    func revertSeries(_ ids: Set<MetadataBookRow.ID>) {
        edit("Revert the series to the proposal".ui, ids) { input in
            let fields = input.confirmation.fields
            input.confirmation = fields.values.isEmpty ? .none : .fields(fields)
        }
    }

    /// ファイル名から解析・抽出し直す: 直した値(下書き)を捨てて、qooMeta の提案に戻す(ルールセットの選び直しは残す)。
    /// **ロックした本は触らない**。取り消せる 1 歩(下書きの直しなので)。
    /// 鍵を外した元の登録の値(以前のアプリで登録した、ジャンルなどが空の値)を、新しい解析でやり直すための口
    /// (利用者の指示 2026-09-21)。
    func reparseFromFileNames(_ ids: Set<MetadataBookRow.ID>) {
        edit("Redo parsing and extraction".ui, ids) { input in
            input.confirmation = .none
        }
    }

    /// 直した値(下書き)を持つ、ロックしていない本。
    var unlockedEditedIDs: Set<String> {
        Set(books.lazy.filter(\.hasUnregisteredEdits).map(\.id))
    }

    /// ツールバーの「メタデータを再生成」の相手: **選んだ本のうち**ロックしていない本(選んでいなければ無し。一覧の全部に
    /// かけたいときは「すべて選択」してから。利用者の理解に合わせた 2026-09-21)。
    var regenerationTargets: Set<String> {
        Set(selectedBooks.lazy.filter { !$0.isRegistered }.map(\.id))
    }

    /// 一覧に出ている本がすべて選ばれているか(ツールバーの全選択 / 全選択解除)。
    var isEveryVisibleBookSelected: Bool {
        !visiblePositions.isEmpty && selection.count >= visiblePositions.count
            && visiblePositions.allSatisfy { selection.contains(books[$0].id) }
    }

    /// 一覧に出ている本をすべて選ぶ。すでに全部選ばれていれば、選択を外す。
    func toggleSelectAll() {
        selection = isEveryVisibleBookSelected ? [] : Set(visiblePositions.map { books[$0].id })
    }

    /// メタデータを削除する: DB の行を消し、確定をすべて捨てて提案に戻す(右クリックの「メタデータを削除…」)。
    /// **ロック(登録)していても消す**(削除は利用者が確かめてから行う)。取り消しの歩みには入れない。
    func unregister(_ ids: Set<MetadataBookRow.ID>) {
        let targets = ids.filter { inputs[$0] != nil }
        guard !targets.isEmpty else { return }
        var drafts: [String: MetadataDraftStore.Draft?] = [:]
        for id in targets {
            registered.remove(id)
            presetOverrides[id] = nil
            inputs[id]?.confirmation = .none
            inputs[id]?.preset = autoPresets[id]
            drafts[id] = .some(nil)
        }
        forgetUndo(for: targets)
        draftsChanged?(drafts)
        refreshRegistration(targets)
        push(Array(targets), alsoWrite: targets)
    }

    func previewSetSeries(_ name: String, for ids: Set<MetadataBookRow.ID>) async -> SeriesChangePreview {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return SeriesChangePreview() }
        let changes = ids.sorted().compactMap { id -> BookChange? in
            guard var input = inputs[id] else { return nil }
            input.confirmation = .series(name: trimmed, volume: row(id).flatMap(Self.confirmedVolume), fields: input.confirmation.fields)
            return .upsert(input)
        }
        let delta = await Task.detached { [index] in try? await index.preview(changes) }.value
        var preview = SeriesChangePreview()
        for proposal in delta?.changed ?? [] {
            let old = row(proposal.id)?.metadata.series ?? ""
            guard old != proposal.metadata.series else { continue }
            if ids.contains(proposal.id) { preview.selected += 1 } else { preview.others += 1 }
            if old.isEmpty { preview.gained += 1 } else if proposal.metadata.series.isEmpty { preview.lost += 1 }
        }
        return preview
    }

    struct SeriesChangePreview: Hashable {
        var selected = 0
        var others = 0
        var gained = 0
        var lost = 0
        var isEmpty: Bool { selected == 0 && others == 0 }
    }

    func row(_ id: String) -> MetadataBookRow? { positionByID[id].map { books[$0] } }

    static func currentSeriesName(_ book: MetadataBookRow) -> String {
        if case .series(let name, _, _) = book.confirmation { return name }
        return book.metadata.series
    }

    static func confirmedVolume(_ book: MetadataBookRow) -> String? {
        if case .series(_, let volume?, _) = book.confirmation { return volume }
        guard !book.metadata.volume.isEmpty, !book.flags.contains(.inferredVolume) else { return nil }
        return book.metadata.volume
    }

    // MARK: - ルールセット

    /// その本の名前を読んだ型の並び。
    func formats(for id: String) -> FilenameFormats { formats[inputs[id]?.preset] }

    /// その本を読んでいるルールセットの名前(割り当てが無ければ既定のもの)。
    func presetName(for id: String) -> String { inputs[id]?.preset ?? formats.defaultName }

    /// その本のルールセットを利用者が選んだか(自動ではなく)。
    func hasPresetOverride(_ id: String) -> Bool { presetOverrides[id] != nil }

    /// 選んだ本に使うルールセット(ファイル名の解析ルール)を切り替える(一覧の右クリック)。nil なら自動に戻す。
    /// **変更した値は捨てない** ―― 切り替えで変わるのは、変更していない欄の提案だけ。変更した値ごと読み直すのは
    /// 「メタデータを再生成」(利用者の指示 2026-09-21: 切り替えと再解析を分ける)。ロックした本は変えない。
    func setRuleSet(_ ids: Set<MetadataBookRow.ID>, to name: String?) {
        let title = name.map { "Use the rule set “%@”".ui(formats.displayName(of: $0)) } ?? "Choose the rule set automatically".ui
        edit(title, ids, presetChange: { _ in name }) { _ in }
    }

    // MARK: - ロック・実体・削除

    /// ロック(= 登録)してあるか。
    func isLocked(_ id: String) -> Bool { registered.contains(id) }

    /// ロックする / 外す(**ロック = 登録**。利用者の決定 2026-09-21、案 A)。
    /// - 掛ける: いま見えている値で DB に登録し、すべての欄を確定した内容にする(規則を変えても変わらない)。下書きは消す。
    /// - 外す: DB の行を消す。**見えていた値は下書きとして残す**(直してからまた掛けられるように)。
    /// 取り消しの歩みには入れない(DB へ書く操作なので)。その本の前の歩みも捨てる。
    ///
    /// **欄がすべて空の本には掛けない**(2026-09-22 の監査で指摘)。DB は空の値の行を作らない(`BookMetadataStore.applyUpsert`)
    /// ので、掛けると鍵の印だけが付いて何も登録されず、開き直すと外れていた。
    func setLocked(_ ids: Set<String>, _ lock: Bool) {
        let targets = ids.filter { id in
            guard inputs[id] != nil, registered.contains(id) != lock else { return false }
            return !lock || row(id)?.values.isEmpty == false
        }
        guard !targets.isEmpty else { return }
        var drafts: [String: MetadataDraftStore.Draft?] = [:]
        for id in targets {
            guard let row = row(id) else { continue }
            let confirmation = row.values.confirmation
            inputs[id]?.confirmation = confirmation
            if lock {
                registered.insert(id)
                drafts[id] = .some(nil)
            } else {
                registered.remove(id)
                drafts[id] = MetadataDraftStore.Draft(confirmation: confirmation, preset: presetOverrides[id])
            }
        }
        forgetUndo(for: targets)
        draftsChanged?(drafts)
        refreshRegistration(targets)
        push(Array(targets), alsoWrite: targets)
    }

    /// 実体が見つからなかった本を知らせる(窓の持ち主が画面の外で確かめた結果)。
    func setMissing(_ ids: Set<String>) {
        let changed = ids.symmetricDifference(missing)
        guard !changed.isEmpty else { return }
        missing = ids
        refreshRegistration(changed)
    }

    /// 一覧から本を外す(保存データを削除した本)。取り消しの歩みからも除く。
    func removeBooks(_ ids: Set<String>) {
        let targets = ids.filter { inputs[$0] != nil }
        guard !targets.isEmpty else { return }
        for id in targets {
            inputs[id] = nil
            registered.remove(id)
            missing.remove(id)
            presetOverrides[id] = nil
            autoPresets[id] = nil
        }
        order.removeAll { targets.contains($0) }
        selection.subtract(targets)
        forgetUndo(for: targets)
        replaceBooks(books.filter { !targets.contains($0.id) })
        let changes = targets.map { BookChange.remove(id: $0) }
        let previous = tail
        working += 1
        tail = Task { [index] in
            await previous?.value
            let delta = await Task.detached { try? await index.apply(changes) }.value
            if let delta { self.absorb(delta) }
            self.working -= 1
        }
    }

    // MARK: - 絞り込みと一覧

    static func keys(_ values: [String]) -> Set<MetadataValueKey> {
        values.isEmpty ? [.empty] : Set(values.map(MetadataValueKey.value))
    }

    static func matches(_ values: [String], _ key: MetadataValueKey) -> Bool {
        switch key {
        case .empty: values.isEmpty
        case .value(let value): values.contains(value)
        }
    }

    static func counts(_ books: [MetadataBookRow], _ values: (MetadataBookRow) -> [String]) -> [(key: MetadataValueKey, count: Int)] {
        var counts: [MetadataValueKey: Int] = [:]
        for book in books {
            let values = values(book)
            if values.count <= 1 { counts[values.first.map(MetadataValueKey.value) ?? .empty, default: 0] += 1 }
            else { for key in keys(values) { counts[key, default: 0] += 1 } }
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    func setGenreFilter(_ key: MetadataValueKey?) {
        isBatching = true
        genreFilter = key
        rebuildCounts()
        if let a = authorFilter, !authorValues.contains(where: { $0.key == a }) { authorFilter = nil }
        isBatching = false
        applyFilters()
    }

    var visibleCount: Int { visiblePositions.count }

    /// 型に合わなかった本の数(絞り込みの帯に出す)。
    var unmatchedCount: Int { books.lazy.filter { !$0.matchedFormat }.count }

    private func matchesGenre(_ book: MetadataBookRow) -> Bool {
        switch genreFilter {
        case nil: true
        case .empty?: book.metadata.genre.isEmpty
        case .value(let genre)?: book.metadata.genre == genre
        }
    }

    private func rebuildCounts() {
        genreValues = Self.counts(books) { $0.metadata.values(.genre) }
        authorValues = Self.counts(genreFilter == nil ? books : books.filter(matchesGenre)) { $0.metadata.authors }
    }

    private func filtersChanged(countsToo: Bool = false) {
        guard !isBatching else { return }
        if countsToo { rebuildCounts() }
        applyFilters()
    }

    private func searchChanged() {
        pendingSearch?.cancel()
        guard !searchText.isEmpty else { return applyFilters() }
        pendingSearch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.applyFilters()
        }
    }

    private func precedes(_ a: Int, _ b: Int) -> Bool {
        // ファイル名フォーマットと合致しなかった本は、並べ替えに関わらず上にまとめる(利用者の指示 2026-09-21)。
        if books[a].matchedFormat != books[b].matchedFormat { return !books[a].matchedFormat }
        for comparator in sortOrder {
            switch comparator.compare(books[a], books[b]) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: continue
            }
        }
        return a < b
    }

    private func sortAll() {
        sortedPositions = books.indices.sorted(by: precedes)
    }

    private func resort(_ changed: [Int]) {
        guard !changed.isEmpty else { return }
        guard sortedPositions.count == books.count, changed.count * 8 < books.count else { return sortAll() }
        let moving = Set(changed)
        sortedPositions.removeAll(where: moving.contains)
        for position in changed.sorted() {
            var low = 0, high = sortedPositions.count
            while low < high {
                let middle = (low + high) / 2
                if precedes(sortedPositions[middle], position) { low = middle + 1 } else { high = middle }
            }
            sortedPositions.insert(position, at: low)
        }
    }

    private func applyFilters() {
        pendingSearch?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let plain = genreFilter == nil && authorFilter == nil && stateFilter == .all && query.isEmpty
        visiblePositions = plain ? sortedPositions : sortedPositions.filter { position in
            let book = books[position]
            guard matchesGenre(book) else { return false }
            if let a = authorFilter, !Self.matches(book.metadata.authors, a) { return false }
            guard stateFilter.contains(book) else { return false }
            return query.isEmpty || book.matches(query)
        }
        selectionChanged()
    }

    private func selectionChanged() {
        let picked = selection.isEmpty ? [] : visiblePositions.lazy.map { self.books[$0] }.filter { self.selection.contains($0.id) }
        if picked.map(\.id) != selectedBooks.map(\.id) { selectionToken += 1 }
        if picked != selectedBooks { selectedBooks = picked }
    }

    // MARK: - 取り消し

    /// 取り消せる操作。**持つのは、その操作で変わった本の、前の入力と選んだルールセットだけ**
    /// (qooMeta の Workspace.Step のコメント)。取り消せるのは下書き(ロックしていない本の直し)だけ ―― ロックと削除は DB へ
    /// 書く操作なので歩みに入れず、その本の歩みは捨てる(`forgetUndo`)。
    private struct Step {
        let name: String
        let inputs: [String: BookInput]
        let overrides: [String: String?]

        /// その本を除いた歩み(残りが無ければ nil)。
        func removing(_ ids: Set<String>) -> Step? {
            let kept = inputs.filter { !ids.contains($0.key) }
            guard !kept.isEmpty else { return nil }
            return Step(name: name, inputs: kept, overrides: overrides.filter { !ids.contains($0.key) })
        }
    }

    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []
    private static let undoLimit = 50

    var undoName: String? { undoSteps.last?.name }
    var redoName: String? { redoSteps.last?.name }
    var canUndo: Bool { !undoSteps.isEmpty }
    var canRedo: Bool { !redoSteps.isEmpty }

    /// その本の歩みを捨てる(ロック・削除・一覧から外したとき)。
    private func forgetUndo(for ids: Set<String>) {
        undoSteps = undoSteps.compactMap { $0.removing(ids) }
        redoSteps = redoSteps.compactMap { $0.removing(ids) }
    }

    /// 本ごとの入力を書き換える操作を、取り消せる 1 歩として行う。**ロック(登録)した本は変えない**。
    /// 直した値は DB へは書かず、下書きとして持ち主へ知らせる(鍵を掛けるまで登録しない。案 A)。
    /// `presetChange` は、その本のルールセットの選び直し(nil を返せば選択を外す)。
    private func edit(_ name: String, _ ids: some Sequence<String>,
                      presetChange: ((String) -> String?)? = nil, _ change: (inout BookInput) -> Void) {
        var previous: [String: BookInput] = [:]
        var previousOverrides: [String: String?] = [:]
        var changed: [String] = []
        for id in ids {
            guard let before = inputs[id], !registered.contains(id) else { continue }
            var input = before
            change(&input)
            let override = presetChange.map { $0(id) } ?? presetOverrides[id]
            input.preset = override ?? autoPresets[id]
            guard input != before || override != presetOverrides[id] else { continue }
            previous[id] = before
            previousOverrides[id] = presetOverrides[id]
            inputs[id] = input
            presetOverrides[id] = override
            changed.append(id)
        }
        guard !changed.isEmpty else { return }
        pushUndo(Step(name: name, inputs: previous, overrides: previousOverrides))
        reportDrafts(changed)
        refreshRegistration(changed)
        push(changed)
    }

    /// 下書き(直したが登録していない値)を持ち主へ知らせる。
    private func reportDrafts(_ ids: some Sequence<String>) {
        var drafts: [String: MetadataDraftStore.Draft?] = [:]
        for id in ids where !registered.contains(id) {
            guard let input = inputs[id] else { continue }
            let override = presetOverrides[id]
            drafts[id] = input.confirmation == .none && override == nil
                ? .some(nil) : MetadataDraftStore.Draft(confirmation: input.confirmation, preset: override)
        }
        if !drafts.isEmpty { draftsChanged?(drafts) }
    }

    private func pushUndo(_ step: Step) {
        undoSteps.append(step)
        if undoSteps.count > Self.undoLimit { undoSteps.removeFirst() }
        redoSteps.removeAll()
    }

    func undo() {
        guard let step = undoSteps.popLast() else { return }
        redoSteps.append(restore(step))
    }

    func redo() {
        guard let step = redoSteps.popLast() else { return }
        undoSteps.append(restore(step))
    }

    /// その操作の前へ戻し、逆向きの 1 歩(戻す前の値)を返す。
    private func restore(_ step: Step) -> Step {
        var currentInputs: [String: BookInput] = [:]
        var currentOverrides: [String: String?] = [:]
        for (id, input) in step.inputs where !registered.contains(id) {
            currentInputs[id] = inputs[id]
            currentOverrides[id] = presetOverrides[id]
            inputs[id] = input
            presetOverrides[id] = step.overrides[id] ?? nil
        }
        let reverse = Step(name: step.name, inputs: currentInputs, overrides: currentOverrides)
        let ids = order.filter { currentInputs[$0] != nil }
        reportDrafts(ids)
        refreshRegistration(ids)
        push(ids)
        return reverse
    }
}

extension Confirmation {
    /// 欄の値だけを入れ替える(シリーズと巻の確定はそのまま)。
    func withFields(_ fields: ConfirmedFields) -> Confirmation {
        switch self {
        case .none, .fields: fields.values.isEmpty ? .none : .fields(fields)
        case .series(let name, let volume, _): .series(name: name, volume: volume, fields: fields)
        case .notInSeries: .notInSeries(fields: fields)
        }
    }

    /// すべての欄とシリーズ・巻が確定しているか(登録済みの本を開いたときの形)。
    var isFullyConfirmed: Bool {
        let editable: [QooMetaKit.BookMetadata.Field] = [.title, .authors, .genre, .event, .source, .info]
        switch self {
        case .none, .fields: return false
        case .series(_, let volume, let fields):
            return volume != nil && editable.allSatisfy { fields[$0] != nil }
        case .notInSeries(let fields):
            return editable.allSatisfy { fields[$0] != nil }
        }
    }
}

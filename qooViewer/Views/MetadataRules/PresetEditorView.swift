import QooMetaKit
import SwiftUI

/// ファイル名フォーマットのプリセット(名前を付けた型の並び)を見て、直す。規則の窓の 1 枚。
///
/// 直すのは手元の下書きで、**「保存」か「名前をつけて保存」を押すまで設定には入らない**(型は書きかけのあいだ読めない形に
/// なるので、1 文字ごとに効かせると一覧が読み直しを繰り返す)。
/// - 保存: いまのプリセットを上書きする。同梱のプリセットも直せて、「初期化」で同梱の中身に戻せる。
/// - 名前をつけて保存: 下書きを新しいプリセットにする。**同じ名前のプリセットは 2 つ作れない。**
/// - 削除: 利用者が作ったプリセットだけ消せる。
struct FormatsPane: View {
    var editing: RulesEditing
    var catalog: PresetCatalog
    /// 巻数とみなせるかの判定(規則の側が決めたもの)。`@volume` の型を試し読み・一覧で本物どおりに当てるために要る。
    var isVolume: VolumeTest

    @State private var selection: String?
    /// 右ペインに出す組(中央ペインで選ぶ)。
    @State private var group: EditorGroup = .formats
    /// 解析のテストに打った名前。**プリセットを選び直しても消さない**(同じ名前で見比べるため)。
    @State private var sample = ""
    @State private var draft = PresetDraft()
    /// 下書きの元(保存してあるもの)。下書きがこれと違えば、保存していない変更がある。
    @State private var saved = PresetDraft()
    @State private var pendingSelection: String?
    @State private var showsSaveAs = false
    @State private var confirmsReset = false
    @State private var confirmsDelete = false

    @State private var picked = MetadataRulesPicked.shared

    private var isDirty: Bool { draft.preset != saved.preset }

    /// 開いたときに選ぶルールセット: 段 2 で選んだもの(この並びに無ければ既定のもの)。
    private var wanted: String {
        if let name = picked.ruleSet, catalog.names.contains(name) { return name }
        return catalog.defaultPreset
    }

    var body: some View {
        let entry = catalog.entries.first { $0.id == selection }
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: Binding(get: { selection }, set: { select($0) })) {
                    Section("Bundled rule sets") {
                        ForEach(catalog.entries.filter(\.isBuiltIn)) { PresetRow(entry: $0).tag($0.id) }
                    }
                    let mine = catalog.entries.filter { !$0.isBuiltIn }
                    Section("Your rule sets") {
                        if mine.isEmpty {
                            Text("Change a rule set and choose “Save As…” and it appears here.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(mine) { PresetRow(entry: $0).tag($0.id) }
                    }
                }
            }
            // 幅は中身で決める: いちばん長い見出しと、その下の「名前 ・ N 通り」が収まれば足りる。
            // **上限を付けないと、窓を広げた分がここに入ってしまう**(右の型が読めない幅に潰れる。
            // 2026-09-20、利用者の指摘)。説明の文は折り返すので、幅を決める根拠にしない。
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)

            Group {
                if let entry {
                    VStack(spacing: 0) {
                        // 下半分は、直したものを**実際に選んだ名前へ当てた結果**(2026-09-21、利用者の指示)。
                        // 直しながら効果が見えるように、編集の場と同じ画面に置く。
                        VSplitView {
                            // 組の一覧(中央)と、その組だけの編集(右)に分かれるのは**上半分だけ**。
                            // 下のプレビューは両方の幅をまたいで使う(2026-09-20、利用者の指示)。
                            HSplitView {
                                // 中央も中身の分だけ。組の名前(いちばん長いもの)と数のバッジ、表示名の欄が収まればよい。
                                PresetGroupList(draft: $draft, group: $group)
                                    .frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
                                // 余った幅はここへ。型の 1 行(番号・型の文字列・釦 4 つ)が切れずに見えるだけの幅が要る。
                                PresetGroupEditor(draft: $draft, group: group,
                                                  others: catalog.entries.filter { $0.id != entry.id }
                                                      .map { AutoRuleEditor.Other(id: $0.id, title: $0.preset.displayName, rule: $0.preset.auto) })
                                    .frame(minWidth: 420, idealWidth: 620, maxWidth: .infinity)
                            }
                            .frame(minHeight: 220, idealHeight: 380)
                            PreviewPane(sample: $sample, draft: $draft, saved: saved, isVolume: isVolume)
                                .frame(minHeight: 220, idealHeight: 300)
                        }
                        Divider()
                        actions(entry)
                    }
                } else {
                    ContentUnavailableView("Select a rule set", systemImage: "textformat.abc")
                }
            }
            .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { load(wanted) } }
        // 窓がもう開いているときも、段 2 から開き直されたら選び直す(直している途中なら、いつもどおり確かめてから)。
        .onChange(of: picked.ruleSetToken) { select(wanted) }
        // 保存・初期化のあと、保存してある中身が変わったら下書きを取り直す(直している途中の下書きは、そのまま)。
        .onChange(of: entry?.preset) { _, now in
            guard let now, now != saved.preset else { return }
            let wasDirty = isDirty
            saved = PresetDraft(now)
            if !wasDirty { draft = saved }
        }
        .confirmationDialog("There are unsaved changes", isPresented: Binding(get: { pendingSelection != nil }, set: { if !$0 { pendingSelection = nil } })) {
            Button("Discard the changes and move on", role: .destructive) { if let next = pendingSelection { load(next) } }
        } message: {
            Text("The changes you made to “%@” take effect only once you save them.".ui(draft.preset.displayName))
        }
    }

    @ViewBuilder private func actions(_ entry: PresetCatalog.Entry) -> some View {
        let problems = draft.problems
        HStack {
            if entry.isBuiltIn {
                Button("Reset…") { confirmsReset = true }
                    .disabled(!entry.isModified)
                    .help("Puts the bundled contents back")
                    .confirmationDialog("Reset “%@” to the bundled contents?".ui(entry.preset.displayName), isPresented: $confirmsReset) {
                        Button("Reset it", role: .destructive) {
                            editing.change { $0.removePreset(entry.id) }
                            if editing.errors.isEmpty, let original = entry.original { saved = PresetDraft(original); draft = saved }
                        }
                    } message: { Text("The changes you saved to this rule set are lost. The ones you saved under a name of your own stay.") }
            } else {
                Button("Delete…", role: .destructive) { confirmsDelete = true }
                    .confirmationDialog("Delete “%@”?".ui(entry.preset.name), isPresented: $confirmsDelete) {
                        Button("Delete it", role: .destructive) {
                            editing.change { $0.removePreset(entry.id) }
                            if editing.errors.isEmpty { load(catalog.builtInDefaultPreset) }
                        }
                    } message: { Text("Folders this rule set was assigned to are read with the default one from now on.") }
            }
            if let first = problems.first { Label(first, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red) }
            else if isDirty { Text("There are unsaved changes").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Discard changes") { draft = saved }.disabled(!isDirty)
            Button("Save As New Rule Set…") { showsSaveAs = true }
                .disabled(!problems.isEmpty)
                .popover(isPresented: $showsSaveAs, arrowEdge: .top) {
                    SaveAsView(existing: catalog.names) { name, label in
                        showsSaveAs = false
                        var copy = draft.preset
                        copy.name = name
                        copy.label = label
                        editing.change { $0.setPreset(copy, original: nil) }
                        if editing.errors.isEmpty { saved = PresetDraft(copy); draft = saved; selection = name }
                    }
                }
            Button("Save") {
                editing.change { $0.setPreset(draft.preset, original: entry.original) }
                if editing.errors.isEmpty { saved = draft }
            }
            .disabled(!isDirty || !problems.isEmpty)
        }
        .padding(10)
    }

    private func select(_ name: String?) {
        guard let name, name != selection else { return }
        if isDirty { pendingSelection = name } else { load(name) }
    }

    private func load(_ name: String) {
        pendingSelection = nil
        guard let entry = catalog.entries.first(where: { $0.id == name }) ?? catalog.entries.first else { return }
        selection = entry.id
        saved = PresetDraft(entry.preset)
        draft = saved
    }
}

private struct PresetRow: View {
    var entry: PresetCatalog.Entry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.preset.displayName)
                Text("%1$@ · %2$lld formats".ui(entry.preset.name, entry.preset.formats.count)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            ModifiedDot(isModified: entry.isModified)
        }
    }
}

/// 下書き。型の行は並べ替えるので、行ごとに変わらない ID を持たせる(中身が同じ行が 2 つあっても区別できるように)。
struct PresetDraft {
    struct Row: Identifiable {
        let id = UUID()
        var format: PresetCatalog.Format
    }

    var name = ""
    var label = ""
    var note = ""
    var separators: [String]?
    var defaults: [String: String] = [:]
    var plain = PlainText.none
    /// 題の途中の括弧を読み残しに数えないか(既定は数えない)。
    var ignoresBracketsInsideTitle = true
    /// 段 2 の「自動」で、このルールセットを選ぶ条件。
    var auto = PresetAutoRule.none
    var rows: [Row] = []

    init() {}

    init(_ preset: PresetCatalog.Preset) {
        name = preset.name
        label = preset.label
        note = preset.note
        separators = preset.separators
        defaults = preset.defaults
        plain = preset.plain
        ignoresBracketsInsideTitle = preset.ignoresBracketsInsideTitle
        auto = preset.auto
        rows = preset.formats.map { Row(format: $0) }
    }

    var preset: PresetCatalog.Preset {
        PresetCatalog.Preset(name: name, label: label.trimmingCharacters(in: .whitespaces), note: note.trimmingCharacters(in: .whitespaces),
                             separators: separators, defaults: defaults.filter { !$0.value.isEmpty }, plain: plain,
                             ignoresBracketsInsideTitle: ignoresBracketsInsideTitle,
                             auto: PresetAutoRule(words: auto.words.filter { !$0.isEmpty },
                                                  headRequired: auto.headRequired.filter { !$0.isEmpty },
                                                  headExcluded: auto.headExcluded.filter { !$0.isEmpty }),
                             formats: rows.map(\.format))
    }

    /// 下書きの型の並びを、いま読める形にしたもの。**書きかけで読めない型は飛ばす**(1 文字打つたびに読めなくなるため)。
    /// `lines` は、残った型が下書きの何行目かの並び(画面に出す番号は、下書きの行の番号のまま)。
    ///
    /// 巻数とみなせるかの判定(`isVolume`)は規則の側が決めるので、外から渡す ―― 渡さないと `@volume` の型が
    /// どの名前にも当たらず、試し読みと一覧が本物と食い違う。
    func usable(isVolume: VolumeTest) -> Usable {
        func fields(_ values: [String: String]) -> [QMBookMetadata.Field: [String]] {
            Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
                QMBookMetadata.Field(rawValue: key).map { ($0, [value]) } })
        }
        var compiled: [FilenameFormat] = []
        var lines: [Int] = []
        var texts: [String] = []
        for (index, row) in rows.enumerated() {
            guard let format = try? FilenameFormat(row.format.text, separators: row.format.separators,
                                                   defaults: fields(row.format.defaults), plain: row.format.plain) else { continue }
            compiled.append(format)
            lines.append(index)
            texts.append(row.format.text)
        }
        return Usable(formats: FilenameFormats(formats: compiled, separators: separators ?? FilenameFormats.defaultSeparators,
                                               defaults: fields(defaults), plain: plain,
                                               ignoresBracketsInsideTitle: ignoresBracketsInsideTitle, isVolume: isVolume),
                      lines: lines, texts: texts)
    }

    struct Usable {
        var formats: FilenameFormats
        var lines: [Int]
        var texts: [String]

        /// 型の番号(読めた並びの中)→ 画面に出す行の番号(1 から)。
        func line(_ index: Int?) -> Int { index.map { lines.indices.contains($0) ? lines[$0] + 1 : $0 + 1 } ?? 0 }
        func text(_ index: Int?) -> String { index.flatMap { texts.indices.contains($0) ? texts[$0] : nil } ?? "" }
    }

    /// 型の書き方の誤り(行の番号つき)。あれば保存できない。
    func problem(of row: Row) -> String? {
        do { _ = try FilenameFormat(row.format.text); return nil } catch { return error.description }
    }

    var problems: [String] {
        var result = rows.enumerated().compactMap { index, row in problem(of: row).map { "Line %1$lld: %2$@".ui(index + 1, $0) } }
        let texts = rows.map(\.format.text)
        if Set(texts).count != texts.count { result.append("The same format appears twice".ui) }
        if rows.isEmpty { result.append("There is no format at all".ui) }
        if let separators, separators.isEmpty { result.append("There is no separator at all".ui) }
        return result
    }
}

/// 右ペインを分ける組。プリセット 1 つの中身は 4 つの持ちものに分かれていて、いちどに全部は要らないので、
/// 中央ペインで 1 つ選んで右ペインに出す(2026-09-20、利用者の指示)。
///
/// **解析のテストはここに入れない。** どの組を直しているときにも見たいものなので、下のプレビューに置く。
private enum EditorGroup: String, CaseIterable, Identifiable {
    case formats, separators, defaults, plain, auto

    var id: String { rawValue }

    /// 中央ペインに出す短い名前。
    var title: String {
        switch self {
        case .formats: "Formats"
        case .separators: "Author separators"
        case .defaults: "Default values"
        case .plain: "Excluded text"
        case .auto: "Automatic choice"
        }
    }

    /// 右ペインの見出し(短い名前より詳しい)。
    var heading: String {
        switch self {
        case .formats: "Format list"
        case .separators: "Author separators"
        case .defaults: "Values for fields the name does not carry"
        case .plain: "Text excluded while parsing"
        case .auto: "When “Automatic” chooses this rule set"
        }
    }

    var symbol: String {
        switch self {
        case .formats: "list.number"
        case .separators: "scissors"
        case .defaults: "text.badge.plus"
        case .plain: "eye.slash"
        case .auto: "wand.and.stars"
        }
    }

    /// 中央ペインの行に出す数(その組にいま何が入っているか)。
    func count(in draft: PresetDraft) -> Int {
        switch self {
        case .formats: draft.rows.count
        case .separators: (draft.separators ?? FilenameFormats.defaultSeparators).count
        case .defaults: draft.defaults.filter { !$0.value.isEmpty }.count
        case .plain: draft.plain.words.count + draft.plain.patterns.count
        case .auto: draft.auto.words.count
        }
    }
}

/// 中央ペイン: このプリセットの見出しと説明、そして右ペインに出す組の一覧。
private struct PresetGroupList: View {
    @Binding var draft: PresetDraft
    @Binding var group: EditorGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 見出しと説明はどの組にも属さない(プリセットそのものの名札)ので、組の一覧の上に置く。
            VStack(alignment: .leading, spacing: 8) {
                LabeledBox("Display name") {
                    TextField("Display name", text: $draft.label, prompt: Text(key: draft.bundledName))
                }
                LabeledBox("Description") {
                    TextField("Description", text: $draft.note, prompt: Text(key: draft.bundledNote), axis: .vertical)
                        .lineLimit(1...3)
                }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            List(selection: Binding(get: { Optional(group) }, set: { if let picked = $0 { group = picked } })) {
                ForEach(EditorGroup.allCases) { item in
                    Label(key: item.title, systemImage: item.symbol)
                        .badge(item.count(in: draft))
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

/// 小さな見出しを付けた入れもの(狭いペインでは、欄の名前を左に置くと欄が細くなるので上に置く)。
private struct LabeledBox<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key: title).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}

/// 説明の文の折り返し幅。**ペインの幅はこれで決めない**: 1 行に伸ばした長さが「ちょうどいい幅」として
/// 効いてしまうと、説明の長い組ほどペインが広くなる(2026-09-20、利用者の指摘)。読みやすい長さで折り返す。
private let helpWidth: CGFloat = 560

/// 右ペイン: 中央ペインで選んだ組だけを直す。
private struct PresetGroupEditor: View {
    @Binding var draft: PresetDraft
    var group: EditorGroup
    /// ほかのルールセットの自動の条件(保存してあるもの)。自動の判定の組で、組み合わせた結果を見せるのに使う。
    var others: [AutoRuleEditor.Other]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(key: group.heading).font(.headline)
                switch group {
                case .formats: formats
                case .separators: separators
                case .defaults: defaults
                case .plain: plain
                case .auto: auto
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    @ViewBuilder private var formats: some View {
        Text("Formats are tried **from the top down**, and the first one that matches the whole name reads it. Put the shapes with more fields above the ones with fewer.")
            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: helpWidth, alignment: .leading)
        Text("Reserved words: @title @author @genre @event @source @info @series @volume @ignore. @author and @ignore may appear any number of times; a format needs either @title or @series.")
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            .frame(maxWidth: helpWidth, alignment: .leading)
        VStack(spacing: 4) {
            // 行は ID で指す(番号で指すと、消した直後に無い番号を読んで落ちる)。
            ForEach($draft.rows) { $row in
                let index = draft.rows.firstIndex { $0.id == row.id } ?? 0
                FormatRowView(index: index, count: draft.rows.count, row: $row, problem: draft.problem(of: row),
                              move: { offset in
                                  guard let i = draft.rows.firstIndex(where: { $0.id == row.id }),
                                        draft.rows.indices.contains(i + offset) else { return }
                                  draft.rows.swapAt(i, i + offset)
                              },
                              remove: { draft.rows.removeAll { $0.id == row.id } })
            }
        }
        .padding(.top, 4)
        Button { draft.rows.append(.init(format: .init(text: "[@author] @title"))) } label: { Label("Add a format", systemImage: "plus") }
    }

    @ViewBuilder private var plain: some View {
        // 題の途中の括弧は、どの型でも欄になりようがない(型が括弧を読むのは名前の頭・著者の直後・末尾だけ)。
        // 数えると直しようのない警告になるので、既定では数えない。数えたい利用者のために入切を置く
        // (2026-09-20、利用者の指示)。
        Toggle(isOn: $draft.ignoresBracketsInsideTitle) {
            Text("Treat a bracket inside the title as part of the title")
        }
        Text("A format reads a bracket as a field only at the head of a name, right after the authors, or at the end. A bracket in the middle of a title could never have become a field, so it is not counted as left over. The ones at the title's head and end are still counted — they may have been a source work or a volume.")
            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: helpWidth, alignment: .leading)
        Divider().padding(.vertical, 4)
        PlainTextEditor(plain: $draft.plain)
    }

    @ViewBuilder private var auto: some View {
        AutoRuleEditor(rule: $draft.auto, id: draft.name, title: draft.preset.displayName, others: others)
    }

    @ViewBuilder private var separators: some View {
        Text("The characters that split the authors read from a name. A format can set its own instead.")
            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: helpWidth, alignment: .leading)
        InlineArrayEditor(items: draft.separators ?? FilenameFormats.defaultSeparators,
                          placeholder: "Separator") { draft.separators = $0 }
    }

    @ViewBuilder private var defaults: some View {
        Text("A field read from the name is never overwritten. These also go into names that matched no format.")
            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: helpWidth, alignment: .leading)
        DefaultsFields(defaults: $draft.defaults)
    }
}

/// 自動の判定の組。① フォルダのパスや名前の語 と ② ファイル名の先頭の語句(必須・例外)を並べ、名前を打てば
/// どの条件でどう決まったかを 1 段ずつ見せる。② は**利用者の考え方のまま**「この語句が先頭にあることを必須にするか、
/// 例外にするか」で書く(2026-09-21、利用者の指摘: 「丸括弧で始まるか」の形では、何を決めているのか読めなかった)。
struct AutoRuleEditor: View {
    struct Other: Hashable {
        var id: String
        var title: String
        var rule: PresetAutoRule
    }

    @Binding var rule: PresetAutoRule
    var id: String
    var title: String
    var others: [Other]
    @State private var sample = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("In step 2, “Automatic” reads a book with this rule set when the book meets both ① and ② below. A book that no rule set takes, or that more than one takes, is not decided — and then “Automatic” cannot be chosen.")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: helpWidth, alignment: .leading)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("① Words in the folder path or the name").font(.subheadline.bold())
                    Text("A book whose folders or name contain any one of these. Upper and lower case, and full and half width, are not told apart. With no word, this rule set is never chosen automatically.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: helpWidth, alignment: .leading)
                    InlineArrayEditor(items: rule.words, placeholder: "Word") { rule.words = $0 }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("② Phrases at the start of the file name").font(.subheadline.bold())
                    Text("Narrows the books ① found by how their file names start. Leave both empty and ① alone decides.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: helpWidth, alignment: .leading)
                    Text("Required — only books whose file name starts with one of these").font(.caption.bold()).padding(.top, 2)
                    InlineArrayEditor(items: rule.headRequired, placeholder: "Phrase") { rule.headRequired = $0 }
                    Text("Excluded — not books whose file name starts with one of these").font(.caption.bold()).padding(.top, 2)
                    InlineArrayEditor(items: rule.headExcluded, placeholder: "Phrase") { rule.headExcluded = $0 }
                    Text("A rule set that requires a phrase comes before one that ① alone takes. So when two rule sets share a word and one of them requires “(”, books whose names start with “(” go to that one and the rest to the other.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: helpWidth, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }

            ForEach(overlaps, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: helpWidth, alignment: .leading)
            }

            Divider().padding(.vertical, 2)
            tryout
        }
    }

    /// ほかのルールセットと語が重なり、**どちらも先頭の語句を必須にしていない**とき、その語を含む本は両方に当たって決まらない。
    private var overlaps: [String] {
        let mine = Set(rule.words.map { $0.lowercased() })
        guard !mine.isEmpty, !rule.requiresHead else { return [] }
        return others.compactMap { other in
            guard !other.rule.requiresHead, !mine.isDisjoint(with: other.rule.words.map { $0.lowercased() }) else { return nil }
            return "“%@” has the same word and neither requires a phrase, so a book with that word is taken by both and not decided — unless an excluded phrase keeps it out of one.".ui(other.title)
        }
    }

    /// 名前を打つと、① ② の順にどう判定したかと、ほかのルールセットと合わせた結果(自動で何が選ばれるか)を見せる。
    @ViewBuilder private var tryout: some View {
        Text("Try a book").font(.headline)
        TextField("Path or file name", text: $sample, prompt: Text("For example: /Shelf/Folder/(Event) [Author] Title.zip"))
            .textFieldStyle(.roundedBorder)
        let text = sample.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            let name = ((text as NSString).lastPathComponent as NSString).deletingPathExtension
            let result = rule.explain(path: text, name: name)
            VStack(alignment: .leading, spacing: 4) {
                step(result.word != nil, result.word.map { "① Contains “%@”".ui($0) } ?? "① Contains none of the words".ui)
                if result.hasRequired {
                    step(result.required != nil, result.required.map { "② Starts with “%@”, which is required".ui($0) }
                         ?? "② Starts with none of the required phrases".ui)
                }
                if let excluded = result.excluded {
                    step(false, "② Starts with “%@”, which is excluded".ui(excluded))
                } else if !rule.headExcluded.isEmpty {
                    step(true, "② Starts with none of the excluded phrases".ui)
                }
                Text(result.fits ? "→ This rule set takes the book".ui : "→ This rule set does not take the book".ui)
                    .font(.callout.bold())
                let titles = Dictionary([(id, title)] + others.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
                let decision = PresetAutoChoice.decide(path: text, name: name,
                                                       rules: [(id, rule)] + others.map { ($0.id, $0.rule) })
                Group {
                    switch decision {
                    case .none: Text("With every rule set together: none takes it, so “Automatic” cannot decide it.")
                    case .one(let chosen): Text("With every rule set together: “Automatic” reads it with “%@”.".ui(titles[chosen] ?? chosen))
                    case .many(let all): Text("With every rule set together: %@ all take it, so “Automatic” cannot decide it.".ui(
                        all.map { "“\(titles[$0] ?? $0)”" }.joined(separator: ", ")))
                    }
                }
                .font(.caption)
                .foregroundStyle({ if case .one = decision { AnyShapeStyle(.secondary) } else { AnyShapeStyle(.orange) } }())
            }
        }
    }

    private func step(_ ok: Bool, _ text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .font(.callout).foregroundStyle(ok ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
    }
}

/// 下のプレビュー: **中央ペインと右ペインの幅をまたいで**、直した並びで実際にどう読めるかを見せる。
/// 上は打った名前 1 つの試し読み、下は段 1 で選んだ本の名前ぜんぶ(2026-09-20、利用者の指示)。
private struct PreviewPane: View {
    @Binding var sample: String
    @Binding var draft: PresetDraft
    var saved: PresetDraft
    var isVolume: VolumeTest

    /// 読み残した括弧を、除外する文字列へ足す。すでに入っているものは足さない(並びの順は変えない)。
    private func exclude(_ texts: [String]) {
        var words = draft.plain.words
        for text in texts where !text.isEmpty && !words.contains(text) { words.append(text) }
        guard words.count != draft.plain.words.count else { return }
        draft.plain = PlainText(words: words, patterns: draft.plain.patterns)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 試し読みは打った名前の分だけ背が伸びる。伸びた分は一覧から取らず、自分の高さのまま置く
            // (足りなくなったら仕切りを動かしてもらう)。
            SampleReading(sample: $sample, draft: draft, isVolume: isVolume)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            NameCheckPane(draft: draft, saved: saved, isVolume: isVolume, exclude: exclude)
                .frame(maxHeight: .infinity)
        }
    }
}

private struct DefaultsFields: View {
    @Binding var defaults: [String: String]

    var body: some View {
        Form {
            ForEach(PresetCatalog.defaultFields, id: \.self) { field in
                TextField(LocalizedStringKey(QMBookMetadata.Field(rawValue: field)?.labelKey ?? field),
                          text: Binding(get: { defaults[field] ?? "" }, set: { defaults[field] = $0.isEmpty ? nil : $0 }))
            }
        }
        .formStyle(.columns)
    }
}

/// 型 1 行。番号(優先順位)、型の文字列、その型だけの区切りと既定の欄、上下、削除。
private struct FormatRowView: View {
    var index: Int
    var count: Int
    @Binding var row: PresetDraft.Row
    var problem: String?
    var move: (Int) -> Void
    var remove: () -> Void
    @State private var showsOptions = false

    private var hasOptions: Bool { row.format.separators != nil || !row.format.defaults.isEmpty || !row.format.plain.isEmpty }

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
            TextField("Format", text: $row.format.text).font(.body.monospaced()).textFieldStyle(.roundedBorder)
            if let problem {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(problem)
            }
            Button { showsOptions = true } label: { Image(systemName: hasOptions ? "slider.horizontal.3" : "ellipsis.circle") }
                .buttonStyle(.borderless).foregroundStyle(hasOptions ? Color.accentColor : .secondary)
                .help("Separators and default fields for this format alone")
                .popover(isPresented: $showsOptions, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Acts only on books read with this format").font(.headline)
                        Text("What a format sets beats what the rule set sets.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Set separators for this format alone", isOn: Binding(get: { row.format.separators != nil },
                                                                 set: { row.format.separators = $0 ? [","] : nil }))
                        if let separators = row.format.separators {
                            InlineArrayEditor(items: separators, placeholder: "Separator") { row.format.separators = $0.isEmpty ? nil : $0 }
                        }
                        Text("Values for fields the name does not carry").font(.subheadline)
                        DefaultsFields(defaults: $row.format.defaults)
                        Text("Text excluded while parsing (added by this format)").font(.subheadline)
                        PlainTextEditor(plain: $row.format.plain, showsHelp: false)
                    }
                    .padding(14).frame(width: 420)
                }
            Button { move(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(index == 0).help("Raise its priority")
            Button { move(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(index == count - 1).help("Lower its priority")
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete this format")
        }
    }
}

/// 試し読み: 名前を打つと、下書きの型の並びでどう読めるかをその場で見せる(保存する前に確かめられる)。
private struct SampleReading: View {
    @Binding var sample: String
    var draft: PresetDraft
    var isVolume: VolumeTest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try a name").font(.headline)
            TextField("File name, without the extension", text: $sample, prompt: Text("For example: (Genre) [Studio] Garden of the Moon 3"))
                .textFieldStyle(.roundedBorder)
            let name = sample.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                let usable = draft.usable(isVolume: isVolume)
                let reading = usable.formats.read(name)
                if let matched = reading.formatIndex {
                    Label("Read with the format on line %1$lld: %2$@".ui(usable.line(matched), usable.text(matched)), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                } else {
                    Label("Matches no format; the whole name becomes a provisional title", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.orange).font(.callout)
                    if let nearest = reading.nearest {
                        Text("The closest is the format on line %1$lld; it looked for the next fixed character at character %2$lld and did not find it.".ui(usable.line(nearest.formatIndex), nearest.brokeAt + 1))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(QMBookMetadata.Field.allCases, id: \.self) { field in
                        let values = reading.metadata.values(field)
                        if !values.isEmpty {
                            GridRow {
                                Text(key: field.labelKey).foregroundStyle(.secondary)
                                ValueChips(items: values)
                            }
                        }
                    }
                }
                .font(.callout)
            }
        }
    }
}

/// 型として読まない文字列(語と正規表現)。名前の中のこの部分は、型の照合のあいだだけただの文字として扱い、値には残す。
private struct PlainTextEditor: View {
    @Binding var plain: PlainText
    var showsHelp = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHelp {
                Text("This part of a name is **not read as a format bracket**, even when it is one: it does not divide fields, and it stays in the title or whatever value holds it. Use it so that the “(2026)” of “Garden of the Moon (2026)” becomes neither a source work nor a volume.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: helpWidth, alignment: .leading)
            }
            Text("Words, matched exactly as written").font(.caption.bold())
            InlineArrayEditor(items: plain.words, placeholder: "For example: (draft)") { plain = PlainText(words: $0, patterns: plain.patterns) }
            Text("Regular expressions").font(.caption.bold())
            InlineArrayEditor(items: plain.patterns, placeholder: "Regular expression (ICU)") { plain = PlainText(words: plain.words, patterns: $0) }
        }
    }
}

/// 名前をつけて保存。同じ名前のプリセットは作れない。
private struct SaveAsView: View {
    var existing: Set<String>
    var save: (String, String) -> Void
    @State private var name = ""

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let problem: String? = trimmed.isEmpty ? nil
            : existing.contains(trimmed) ? "A rule set of that name already exists".ui
            : trimmed.hasPrefix("$") ? "A name cannot start with “$”".ui
            : trimmed.count > 100 ? "That name is too long".ui : nil
        Form {
            TextField("Name of the rule set", text: $name, prompt: Text("For example: My shelf"))
            Text("Saves what you have on screen as a new rule set. The one you started from is left alone.").font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                // 見出しは名前と同じにする(あとで直せる)。元の見出しのままだと、一覧で見分けが付かない。
                Button("Save") { save(trimmed, trimmed) }.keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty || problem != nil)
            }
        }
        .padding(14).frame(width: 340)
    }
}

extension PresetCatalog.Preset {
    /// 画面に出す名前(の鍵)。見出しを付けていなければ、同梱のプリセットの訳。利用者の見出しは、その言葉のまま。
    /// 見出しを付けていなければ、同梱のプリセットの訳。**利用者が付けた見出しは、その言葉のまま**(訳さない)。
    var displayName: String { label.isEmpty ? RuleLabels.preset(name).title.ui : label }
}

extension PresetDraft {
    /// 見出しと説明を空にしたときに、代わりに出る言葉の鍵(同梱のプリセットだけが持つ)。
    var bundledName: String { RuleLabels.preset(name).title }
    var bundledNote: String { RuleLabels.preset(name).help }
}

extension FormatPresets {
    /// 画面に出す名前。`title(of:)` は見出しか名前を返すので、同梱のプリセットはここで訳す。
    func displayName(of name: String) -> String {
        let label = presets[name]?.label ?? ""
        return label.isEmpty ? RuleLabels.preset(name).title.ui : label
    }
}

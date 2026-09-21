import QooMetaKit
import SwiftUI

/// 流れの段 1・段 2 で選んだもののうち、**規則の窓が見たいもの**の置き場。窓をまたいで使うので、
/// 場面(Scene)ではなくここに置く ―― ファイル名解析の窓は一覧の窓とは別の場面で、段で選んだものを直には見られない。
///
/// 持つのは本の名前と、選んだルールセットの名前だけ(パスは持たない)。書き出しにも保存にも使わない、画面のための写し。
@MainActor @Observable
final class MetadataRulesPicked {
    static let shared = MetadataRulesPicked()

    private(set) var names: [String] = []
    /// 中身が入れ替わったかを軽く見分ける印(名前の並びを毎回比べずに済ませる)。
    private(set) var token = 0
    /// 段 2 で選んだルールセットの名前。
    private(set) var ruleSet: String?
    /// 規則の窓を開いた回数。**窓がもう開いているときにも選び直させる**ための印。
    ///
    /// 段 2 で同人誌のルールセットを選んでいるのに、そこから開いた窓では商業誌が選ばれている、という食い違いがあった
    /// (2026-09-20、利用者の指摘)。開くたびに、いま選んでいるものへ合わせる。
    private(set) var ruleSetToken = 0

    func set(_ names: [String]) {
        self.names = names
        token += 1
    }

    /// 規則の窓を開く直前に、いま選んでいるルールセットを渡す。
    func open(ruleSet: String) {
        self.ruleSet = ruleSet
        ruleSetToken += 1
    }
}

// MARK: - 数え直し

/// 選んだ名前を、**直す前**と**いまの下書き**の両方で読んで、1 行ずつ突き合わせる。
///
/// 直したことで良くなった名前・悪くなった名前がその場で分かるように、いつも 2 通りで読む
/// (2026-09-21、利用者の指示)。読み直しは打つたびに走るので、少し待ってからまとめて、画面の外で行う。
@MainActor @Observable
final class NameCheck {
    nonisolated struct Row: Identifiable, Sendable {
        var id: Int
        var name: String
        /// いまの下書きで読んだ結果。
        var now: FormatCheck
        /// 直す前(保存してある並び)の読めぐあい。
        var before: FormatOutcome

        /// 直したことで良くなったか・悪くなったか。
        var change: Change {
            if now.outcome == before { return .same }
            return now.outcome < before ? .better : .worse
        }

        /// 読み残した括弧の文字列(どの欄にもならず題に残ったもの)。**除外する文字列にそのまま登録できる形**。
        var leftoverBrackets: [String] {
            guard now.outcome == .leftover else { return [] }
            let chars = Array(name)
            return now.problems.filter { $0.upperBound <= chars.count }.map { String(chars[$0]) }
        }
    }

    enum Change { case same, better, worse }

    nonisolated struct Counts: Sendable {
        var read = 0, leftover = 0, unread = 0
        var total: Int { read + leftover + unread }

        mutating func add(_ outcome: FormatOutcome) {
            switch outcome {
            case .read: read += 1
            case .leftover: leftover += 1
            case .unread: unread += 1
            }
        }

        func count(of outcome: FormatOutcome) -> Int {
            switch outcome {
            case .read: read
            case .leftover: leftover
            case .unread: unread
            }
        }
    }

    private(set) var rows: [Row] = []
    private(set) var now = Counts()
    private(set) var before = Counts()
    private(set) var better = 0
    private(set) var worse = 0
    private(set) var isWorking = false

    private var task: Task<Void, Never>?
    private var last: Int?
    /// 「直す前」の読めぐあい(保存してある並びと名前が同じあいだは使い回す。下書きを 1 文字打つたびに、
    /// 変わっていない側まで全冊を読み直さない)。
    private var beforeKey: Int?
    private var beforeOutcomes: [FormatOutcome] = []

    /// 下書きか、選んだ名前が変わったら読み直す。中身が同じなら何もしない(画面は何度も描き直されるため)。
    func update(now: FilenameFormats, before: FilenameFormats, names: [String], token: Int) {
        var hasher = Hasher()
        hasher.combine(now)
        hasher.combine(before)
        hasher.combine(token)
        let key = hasher.finalize()
        guard key != last else { return }
        last = key
        task?.cancel()
        guard !names.isEmpty else {
            rows = []; self.now = Counts(); self.before = Counts(); better = 0; worse = 0; isWorking = false
            return
        }
        isWorking = true
        var beforeHasher = Hasher()
        beforeHasher.combine(before)
        beforeHasher.combine(token)
        beforeHasher.combine(names.count)
        let newBeforeKey = beforeHasher.finalize()
        let known = newBeforeKey == beforeKey && beforeOutcomes.count == names.count ? beforeOutcomes : nil
        task = Task { [weak self] in
            // 打っている途中の型で何度も読み直さない(1 文字ごとに蔵書ぜんぶを読むことになる)。
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                var rows: [Row] = []
                rows.reserveCapacity(names.count)
                var nowCounts = Counts(), beforeCounts = Counts()
                for (index, name) in names.enumerated() {
                    let check = now.check(name)
                    let was = known?[index] ?? before.check(name).outcome
                    nowCounts.add(check.outcome)
                    beforeCounts.add(was)
                    rows.append(Row(id: index, name: name, now: check, before: was))
                }
                return (rows, nowCounts, beforeCounts)
            }.value
            guard !Task.isCancelled else { return }
            self?.rows = result.0
            self?.beforeKey = newBeforeKey
            self?.beforeOutcomes = result.0.map(\.before)
            self?.now = result.1
            self?.before = result.2
            self?.better = result.0.count { $0.change == .better }
            self?.worse = result.0.count { $0.change == .worse }
            self?.isWorking = false
        }
    }
}

// MARK: - 画面

/// 直している並びで、選んだ本の名前が**実際にどう読めるか**の一覧。
///
/// 型を直すとき、どの名前がまだ読めていないのかと、直して何が良くなったのかを見る手立てが無かった
/// (2026-09-21、利用者の指摘)。その 2 つを 1 つの表で兼ねる: 読めぐあいごとの数は「直す前 → いま」で出し、
/// 行には**問題の場所**を色で示す。
struct NameCheckPane: View {
    var draft: PresetDraft
    var saved: PresetDraft
    var isVolume: VolumeTest
    /// 読み残した括弧を、**除外する文字列**へ足す(重なりは呼ばれた側で落とす)。
    ///
    /// 題の中の括弧で読み残しになる名前が多く、直す手立ては「その文字列を除外に登録する」しかなかった。
    /// 見えている読み残しから 1 押しで登録できるようにする(2026-09-20、利用者の指示)。
    var exclude: ([String]) -> Void

    @State private var check = NameCheck()
    @State private var filter: Filter = .problems
    @State private var picked = MetadataRulesPicked.shared

    enum Filter: String, CaseIterable, Identifiable {
        case problems, changed, all
        var id: String { rawValue }

        var title: String {
            switch self {
            case .problems: "Not read in full"
            case .changed: "Changed by your edit"
            case .all: "All"
            }
        }
    }

    /// まだ除外していない読み残しの括弧(出てきた順、重なりは 1 つ)。
    private var unregistered: [String] {
        var seen = Set(draft.plain.words)
        var result: [String] = []
        for row in check.rows {
            for text in row.leftoverBrackets where seen.insert(text).inserted { result.append(text) }
        }
        return result
    }

    private var rows: [NameCheck.Row] {
        switch filter {
        case .problems: check.rows.filter { !$0.now.isRead }
        case .changed: check.rows.filter { $0.change != .same }
        case .all: check.rows
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if picked.names.isEmpty {
                // 外の VStack は左そろえなので、そのままだと知らせが左端に寄る。空いている所の真ん中に置く。
                ContentUnavailableView {
                    Label("No books chosen yet", systemImage: "books.vertical")
                } description: {
                    Text("Choose the books in step 1 and their names appear here, so you can see which ones this rule set fails to read.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView {
                    Label(filter == .changed ? "Your edit changed nothing yet" : "Every name was read in full", systemImage: "checkmark.circle")
                } description: {
                    Text(filter == .changed ? "Nothing here reads differently from the saved rule set." : "No name was left with a bracket that became no field.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let usable = draft.usable(isVolume: isVolume)
                List(rows) { row in
                    NameCheckRow(row: row, usable: usable, exclude: exclude).listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }
        }
        .onChange(of: draft.preset) { recompute() }
        .onChange(of: saved.preset) { recompute() }
        .onChange(of: picked.token) { recompute() }
        .onAppear { recompute() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            ForEach(FormatOutcome.allCases, id: \.self) { outcome in
                CountDelta(outcome: outcome, before: check.before.count(of: outcome), now: check.now.count(of: outcome))
            }
            if check.better > 0 || check.worse > 0 {
                Divider().frame(height: 18)
                if check.better > 0 {
                    Label("%lld better".ui(check.better), systemImage: "arrow.up.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                }
                if check.worse > 0 {
                    Label("%lld worse".ui(check.worse), systemImage: "arrow.down.circle.fill")
                        .font(.callout).foregroundStyle(.red)
                }
            }
            if check.isWorking { ProgressView().controlSize(.small) }
            Spacer()
            // 読み残しは、ほとんどが題の中の括弧。1 つずつ足すのは骨なので、見えている分をまとめて足せるようにする。
            let pending = unregistered
            if !pending.isEmpty {
                Button { exclude(pending) } label: {
                    Label("Exclude %lld brackets".ui(pending.count), systemImage: "eye.slash")
                }
                .help("Adds every bracket left over in these names to the excluded text, so each one stays in the title".ui)
            }
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text(key: $0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func recompute() {
        check.update(now: draft.usable(isVolume: isVolume).formats, before: saved.usable(isVolume: isVolume).formats,
                     names: picked.names, token: picked.token)
    }
}

/// 読めぐあい 1 つの「直す前 → いま」。
private struct CountDelta: View {
    var outcome: FormatOutcome
    var before: Int
    var now: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(key: outcome.title, systemImage: outcome.symbol)
                .font(.caption).foregroundStyle(outcome.color)
            HStack(spacing: 4) {
                if before != now {
                    Text(verbatim: "\(before)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                }
                Text(verbatim: "\(now)").font(.title3.monospacedDigit().weight(.semibold))
                if before != now {
                    // 良い側が増えた・悪い側が減ったときが「良くなった」。
                    let improved = outcome == .read ? now > before : now < before
                    Text(verbatim: now > before ? "+\(now - before)" : "\(now - before)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(improved ? .green : .red)
                }
            }
        }
    }
}

/// 名前 1 行。問題のある文字を色で示し、なぜそうなったかを 1 行で添える。
private struct NameCheckRow: View {
    var row: NameCheck.Row
    /// いま読める型の並び(何行目の型で読んだかを出すため)。
    var usable: PresetDraft.Usable
    var exclude: ([String]) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.now.outcome.symbol).foregroundStyle(row.now.outcome.color)
                .help(row.now.outcome.title.ui)
            VStack(alignment: .leading, spacing: 2) {
                Text(marked).font(.body.monospaced()).textSelection(.enabled).lineLimit(2)
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            // 読み残しの行だけ、その括弧を除外する文字列へ足す釦を出す。
            let brackets = row.leftoverBrackets
            if !brackets.isEmpty {
                Button { exclude(brackets) } label: { Image(systemName: "eye.slash") }
                    .buttonStyle(.borderless)
                    .help("Adds the marked bracket to the excluded text, so it stays in the title".ui)
            }
            switch row.change {
            case .same: EmptyView()
            case .better:
                Label("Better", systemImage: "arrow.up.circle.fill").labelStyle(.iconOnly)
                    .foregroundStyle(.green).help("This name reads better than with the saved rule set".ui)
            case .worse:
                Label("Worse", systemImage: "arrow.down.circle.fill").labelStyle(.iconOnly)
                    .foregroundStyle(.red).help("This name reads worse than with the saved rule set".ui)
            }
        }
        .padding(.vertical, 3)
    }

    /// 名前に印を付ける: 読めた部分は欄の色、**問題の部分は赤地**(どこを直せばよいかが分かるように)。
    private var marked: AttributedString {
        let chars = Array(row.name)
        var word = [FormatWord?](repeating: nil, count: chars.count)
        for span in row.now.spans { for i in span.range where i < chars.count { word[i] = span.word } }
        var bad = [Bool](repeating: false, count: chars.count)
        for range in row.now.problems { for i in range where i < chars.count { bad[i] = true } }

        var result = AttributedString()
        var i = 0
        while i < chars.count {
            var j = i
            while j < chars.count, bad[j] == bad[i], word[j] == word[i] { j += 1 }
            var part = AttributedString(String(chars[i..<j]))
            if bad[i] {
                part.backgroundColor = row.now.outcome.color.opacity(0.28)
                part.underlineStyle = .single
            } else if let w = word[i] {
                part.backgroundColor = w.color.opacity(0.18)
            }
            result += part
            i = j
        }
        return result
    }

    private var reason: String {
        switch row.now.outcome {
        case .read:
            return "Read with the format on line %1$lld: %2$@".ui(usable.line(row.now.formatIndex), usable.text(row.now.formatIndex))
        case .leftover:
            return "Read with the format on line %1$lld, but the marked bracket became no field and stayed in the title.".ui(usable.line(row.now.formatIndex))
        case .unread:
            guard let index = row.now.formatIndex else {
                return "No format came close. The whole name becomes a provisional title.".ui
            }
            let at = row.now.problems.first?.lowerBound ?? 0
            return "The closest format is the one on line %1$lld (%2$@); it looked for the next fixed character at character %3$lld — the marked part.".ui(usable.line(index), usable.text(index), at + 1)
        }
    }
}

nonisolated extension FormatOutcome {
    var title: String {
        switch self {
        case .read: "Read in full"
        case .leftover: "Bracket left over"
        case .unread: "Matched no format"
        }
    }

    var symbol: String {
        switch self {
        case .read: "checkmark.circle.fill"
        case .leftover: "exclamationmark.triangle.fill"
        case .unread: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .read: .green
        case .leftover: .orange
        case .unread: .red
        }
    }
}

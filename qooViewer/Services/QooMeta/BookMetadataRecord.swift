import Foundation
import QooMetaKit

/// DB のメタデータの行を、qooMeta との受け渡しの形で読んだもの(2026-09-22)。
///
/// 利用者の指示(2026-09-22): **解析した本はすべて DB に登録し、ロックしたら変えない、削除したら消す**。「表示されて
/// いるが保存されていない」値は利用者には意味が分からない。そこで行は 2 種類になった:
/// - ロックした行: 値そのものが確定(規則を変えても・再生成しても・ファイルから取り込んでも変わらない)。
/// - ロックしていない行: 値は「ファイル名の解析 + 利用者が直した欄(`edits`)」から作り直される。直した欄は残る。
nonisolated struct BookMetadataRecord: Hashable, Sendable {
    var values: BookMetadataValues
    var isLocked: Bool
    /// 利用者が直した欄(ロックしていない行だけが持つ)。
    var edits: Confirmation = .none
    /// 利用者が選んだルールセット(nil なら自動)。ロックした行も持ち続ける(外したときに戻るように)。
    var ruleSet: String?

    /// qooMeta へ渡す確定した内容。ロックした行はすべての欄(`BookMetadataValues.confirmation`)、していない行は直した欄だけ。
    var confirmation: Confirmation { isLocked ? values.confirmation : edits }

    /// ロック・直した欄・ルールセット(DB の行の形。`BookMetadata.rowState` と同じ)。
    var rowState: BookMetadataRowState { BookMetadataRowState(isLocked: isLocked, edits: edits, ruleSet: ruleSet) }
}

/// 行のロックと直した欄(`BookMetadataStore.BatchEntry.state`)。
nonisolated struct BookMetadataRowState: Hashable, Sendable {
    var isLocked: Bool
    var edits: Confirmation = .none
    var ruleSet: String?

    static let locked = BookMetadataRowState(isLocked: true)

    /// DB に書いたあとの形(ロックした行は直した欄を持たない ―― `BookMetadata.apply(_:)`)。
    var normalized: BookMetadataRowState {
        isLocked ? BookMetadataRowState(isLocked: true, ruleSet: ruleSet) : self
    }
}

extension BookMetadata {
    var record: BookMetadataRecord {
        BookMetadataRecord(values: values, isLocked: isLocked, edits: isLocked ? .none : edits, ruleSet: ruleSet)
    }

    /// 直した欄(`editsData` を読んだもの。読めなければ無し)。
    var edits: Confirmation {
        get { editsData.flatMap { try? JSONDecoder().decode(Confirmation.self, from: $0) } ?? .none }
        set { editsData = newValue == .none ? nil : try? JSONEncoder().encode(newValue) }
    }

    /// ファイル名の読みだけから作った行か(ロックも直した欄も利用者のルールセットも無く、ファイルの書誌も取り込んでいない)。
    /// 消しても、その本がまた解析されれば同じ行ができる(`BookMetadataStore.pruneParsedOnlyRows`)。
    var isParsedOnly: Bool {
        !isLocked && editsData == nil && ruleSet == nil && !didImportSourceMetadata
    }

    var rowState: BookMetadataRowState {
        BookMetadataRowState(isLocked: isLocked, edits: isLocked ? .none : edits, ruleSet: ruleSet)
    }

    /// ロックと直した欄を書く(ロックした行は直した欄を持たない ―― 値そのものが確定しているので)。
    func apply(_ state: BookMetadataRowState) {
        isLocked = state.isLocked
        edits = state.isLocked ? .none : state.edits
        ruleSet = state.ruleSet
    }
}

/// ファイル名から読んだ値を DB へ登録するための計算(画面を持たない所 ―― 本を開いたとき・規則の変更・スマートライブラリ)。
nonisolated enum MetadataParsing {
    /// 1 冊をファイル名から読み、直した欄を重ねた値。同じ書き手のほかの本と見比べないので、番号の無いシリーズは
    /// 見つからない(メタデータの編集ウインドウやスマートライブラリが全冊で読み直すと見つかる)。
    static func values(forBookID bookID: String, edits: Confirmation = .none, ruleSet: String? = nil,
                       rules: CompiledRules) -> BookMetadataValues {
        let name = MetadataRulesStore.parsingName(forBookID: bookID)
        let preset = ruleSet ?? MetadataRulesStore.autoPreset(forBookID: bookID, name: name, rules: rules)
        let input = BookInput(id: bookID, name: name, preset: preset, confirmation: edits)
        let set = proposeSync([input], rules: rules, dictionaries: MetadataRulesStore.dictionaries)
        return BookMetadataValues(set[bookID]?.metadata ?? edits.fields.applied(
            to: parseName(name, rules: rules, preset: preset).metadata))
    }

    /// 1 冊ぶんのシートで変えた欄を、直した欄に足す(変えていない欄は今の直した欄のまま)。
    static func edits(changing old: BookMetadataValues, to new: BookMetadataValues, in edits: Confirmation) -> Confirmation {
        var fields = edits.fields
        func single(_ field: QooMetaKit.BookMetadata.Field, _ old: String, _ new: String) {
            if old != new { fields[field] = new.isEmpty ? [] : [new] }
        }
        single(.title, old.title, new.title)
        if old.authors != new.authors { fields[.authors] = new.authors }
        single(.genre, old.genre, new.genre)
        single(.event, old.event, new.event)
        single(.source, old.source, new.source)
        single(.info, old.info, new.info)
        // 巻数(並べ替え用)を変えたら、その数を確定する(無しにしたら確定を外し、表記から読んだ数に戻す)。変えずに巻の表記を
        // 変えたら、確定した数は外す(新しい表記と食い違った数を残さない)。
        if old.volumeSort != new.volumeSort, !new.series.isEmpty {
            fields.volumeSort = new.volumeSort
        } else if old.volume != new.volume {
            fields.volumeSort = nil
        }
        guard old.series != new.series || old.volume != new.volume else { return edits.withFields(fields) }
        guard !new.series.isEmpty else {
            // シリーズではない本の巻は、欄として持つ(`BookMetadataValues.confirmation` と同じ)。
            single(.volume, old.volume, new.volume)
            return .notInSeries(fields: fields)
        }
        return .series(name: new.series, volume: new.volume, fields: fields)
    }

    /// 読み(`parsed`)と違う欄だけを直した欄にしたもの(鍵を外したとき。`MetadataWorkspace.unlock`・1 冊ぶんのシート)。
    static func edits(from parsed: BookMetadataValues, to values: BookMetadataValues) -> Confirmation {
        edits(changing: parsed, to: values, in: .none)
    }

    /// ファイル(EPUB/PDF/ComicInfo.xml)の書誌情報を、直した欄へ重ねる。**利用者が直した欄は変えない**
    /// (利用者の指示 2026-09-22: ロックしていない本はファイル内の値で上書きし、手で直した欄は残す)。
    static func merging(_ source: SourceBookMetadata, into edits: Confirmation) -> Confirmation {
        var fields = edits.fields
        let title = source.title.trimmingCharacters(in: .whitespaces)
        let author = source.author.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, fields[.title] == nil { fields[.title] = [title] }
        if !author.isEmpty, fields[.authors] == nil { fields[.authors] = [author] }
        let series = source.series.trimmingCharacters(in: .whitespaces)
        let volume = source.seriesIndex.trimmingCharacters(in: .whitespaces)
        switch edits {
        case .series, .notInSeries:
            // シリーズを利用者が決めている。
            return edits.withFields(fields)
        case .none, .fields:
            guard !series.isEmpty else { return edits.withFields(fields) }
            return .series(name: series, volume: volume.isEmpty ? nil : volume, fields: fields)
        }
    }
}

/// 直した欄を、保存データの JSON に入れる形(qooMeta の `Confirmation` をそのまま書く)。JSON の型を書くファイルが
/// qooMeta を取り込まずに済むように包んである(取り込むと qooMeta の `BookMetadata` と名前が重なる)。
nonisolated struct MetadataEdits: Codable, Hashable, Sendable {
    var confirmation: Confirmation

    init(_ confirmation: Confirmation) { self.confirmation = confirmation }

    /// 読めない形(qooMeta の版が上がって `Confirmation` の形が変わった、など)は「直した欄は無い」として読む
    /// (ファイル全体の読み込みを止めない)。
    init(from decoder: any Decoder) throws { confirmation = (try? Confirmation(from: decoder)) ?? .none }

    func encode(to encoder: any Encoder) throws { try confirmation.encode(to: encoder) }
}

extension MetadataEdits {
    /// 書き出す直した欄(ロックした行・直した欄の無い行は nil)。
    static func exporting(_ metadata: BookMetadata) -> MetadataEdits? {
        metadata.isLocked || metadata.edits == .none ? nil : MetadataEdits(metadata.edits)
    }
}

nonisolated extension BookMetadataRowState {
    /// 保存データの JSON から読んだ、ロックしていない行。
    static func unlocked(edits: MetadataEdits?, ruleSet: String?) -> BookMetadataRowState {
        BookMetadataRowState(isLocked: false, edits: edits?.confirmation ?? .none, ruleSet: ruleSet)
    }
}

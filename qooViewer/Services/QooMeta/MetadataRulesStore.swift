import Foundation
import Observation
import QooMetaKit
import QooMetaRules
import Synchronization

/// qooMeta の欄(`QooMetaKit.BookMetadata`)。qooViewer 自身の `BookMetadata`(SwiftData の行)と名前が重なるので、
/// qooMeta のほうはこの名前で呼ぶ(このモジュールの型が、取り込んだモジュールの同名の型より優先されるため)。
typealias QMBookMetadata = QooMetaKit.BookMetadata

/// ファイル名からメタデータを作る規則(qooMeta)の設定と、それを組み立てたもの。アプリに 1 つ(`AppStores`)。
///
/// 2026-09-21、ファイル名の解析を qooMeta へ置き換えたときに、`MetadataFormatStore`(3 種の正規表現の規則を
/// UserDefaults に持っていた)と入れ替えた(docs/plans/qoometa-smart-library-plan.md)。
///
/// 持つもの・保存の仕方は qooMeta のアプリの設定(`AppSettings`)をそのまま移した:
/// - 規則の差分(同梱の既定値に重ねる、rules-bundle の JSON)。**組み立てられなかった差分も文字のまま持ち続ける**
///   (捨てると次の保存で利用者の規則が黙って消える。qooMeta の 2026-09-21 の監査)。
/// - スタンプ(よく使う欄の値をまとめて押すもの)。
///
/// 保存先はサンドボックスのコンテナの Application Support/qooMeta/settings.json。**蔵書の名前が入りうる**
/// (スタンプの値・規則に足した語)ので、コンテナの外へは書かない。
///
/// qooMeta の画面(規則の 2 つの窓・メタデータの編集)を移植したものが `@Bindable` で読むので、
/// ほかのストア(ObservableObject)と違って `@Observable` にしてある。
@MainActor @Observable
final class MetadataRulesStore {
    /// 画面で変えた規則(同梱の既定値に重ねる差分)。空なら既定のまま。
    private(set) var rulesDiff: String = ""
    /// スタンプ(qooMeta のアプリの機能)。**画面からは外した**(利用者の指示 2026-09-21: 欄をまとめて変更で足りる)が、
    /// 保存してあるものは読み書きし続ける(また使うことになったときに消えていないように)。
    var stamps: [MetadataStamp] = []
    /// メタデータの登録の対象外にするフォルダ(末尾の `/` を持たないパス。その中とサブフォルダの本が対象外)。
    /// 2026-09-21、利用者の指示。メタデータの編集ウインドウに並べず、1 冊ぶんのシートで登録させず、本を開いたときの
    /// EPUB/PDF/ComicInfo からの取り込みもしない。**既に登録してあるメタデータは消さない**(並べないだけ)。
    private(set) var excludedFolders: [String] = []

    /// 規則の差分を組み立てた結果(誤りがあれば既定のまま使い、理由を持つ)。
    private(set) var rules: CompiledRules = .builtin
    private(set) var ruleIssues: [String] = []

    /// 設定ファイルの場所。
    let url: URL

    /// 規則が変わった知らせ(`BookTitleResolver` などの作り置きを捨てる合図)。
    static let rulesDidChange = Notification.Name("qooViewer.metadataRulesDidChange")

    /// 既定の保存先(コンテナの Application Support)。
    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("qooMeta", isDirectory: true).appendingPathComponent("settings.json")
    }

    /// - Parameters:
    ///   - url: 設定ファイル。テストは使い捨ての場所を渡す(共有の状態に触らない)。
    ///   - legacyDefaults: 以前の規則(`MetadataFormatStore`)を読む UserDefaults。nil なら引き継ぎをしない。
    ///   - isAppWide: アプリに 1 つのもの(`AppStores`)。真なら、規則を `appWideRules` にも写す。
    init(url: URL = MetadataRulesStore.defaultURL, legacyDefaults: UserDefaults? = .standard, isAppWide: Bool = false) {
        self.url = url
        self.isAppWide = isAppWide
        load()
        if let legacyDefaults { migrateLegacyFormatsIfNeeded(from: legacyDefaults) }
        if isAppWide {
            Self.appWideRules.withLock { $0 = rules }
            Self.appWideExcludedFolders.withLock { [excludedFolders] in $0 = excludedFolders }
        }
    }

    @ObservationIgnored private let isAppWide: Bool

    /// アプリの規則の写し。ストアを受け取れない所(書き出しのウインドウの ViewModel が、題と著者の初期値をファイル名から
    /// 読むとき)が読む。テストの中で作ったストアは書かない(`isAppWide`)。
    nonisolated static let appWideRules = Mutex<CompiledRules>(.builtin)
    /// アプリの規則の写しの、いまの値。
    nonisolated static var currentAppWideRules: CompiledRules { appWideRules.withLock { $0 } }
    /// 対象外のフォルダの写し(本を開いたときの取り込みが読む。ストアを受け取れないため)。
    nonisolated static let appWideExcludedFolders = Mutex<[String]>([])

    // MARK: - 対象外のフォルダ

    /// その本がメタデータの登録の対象外か(対象外のフォルダの中かサブフォルダにある)。
    func isExcluded(bookID: String) -> Bool { Self.isExcluded(bookID: bookID, in: excludedFolders) }

    nonisolated static func isExcluded(bookID: String, in folders: [String]) -> Bool {
        guard !folders.isEmpty else { return false }
        let path = MountTable.normalized(bookID)
        return folders.contains { MountTable.path(path, isAtOrUnder: $0) }
    }

    /// アプリの設定の写しで確かめる(ストアを持たない所から)。
    nonisolated static func isExcludedAppWide(bookID: String) -> Bool {
        isExcluded(bookID: bookID, in: appWideExcludedFolders.withLock { $0 })
    }

    func addExcludedFolder(_ url: URL) {
        let path = MountTable.normalized(url.standardizedFileURL.path)
        guard !excludedFolders.contains(path) else { return }
        setExcludedFolders(excludedFolders + [path])
    }

    func removeExcludedFolder(_ path: String) {
        setExcludedFolders(excludedFolders.filter { $0 != path })
    }

    /// アプリ自身が名前を変えた・移したフォルダの登録を付け替える(FavoriteLocationStore.relocate と同じ規則)。
    func relocate(using change: FileSystemChange) {
        guard !change.relocations.isEmpty else { return }
        var seen = Set<String>()
        let relocated = excludedFolders.compactMap { path -> String? in
            let new = change.relocatedPath(for: path).map(MountTable.normalized) ?? path
            return seen.insert(new).inserted ? new : nil
        }
        if relocated != excludedFolders { setExcludedFolders(relocated) }
    }

    private func setExcludedFolders(_ folders: [String]) {
        excludedFolders = folders
        if isAppWide { Self.appWideExcludedFolders.withLock { $0 = folders } }
        save()
    }

    /// 辞書(英単語)。規則が名前で指す。初めて読むときに /usr/share/dict/words を読む(約 24 万語)ので、
    /// 起動の直後に画面の外で読ませておく(`warmUp`)。
    nonisolated static var dictionaries: [String: WordSet] { SystemDictionaries.all }

    /// 辞書を画面の外で読んでおく(メタデータの編集ウインドウを初めて開いたときに main で待たないため)。
    nonisolated static func warmUp() {
        Task.detached(priority: .utility) { _ = SystemDictionaries.all }
    }

    // MARK: - 規則の差分

    /// 画面で変えた規則(差分を、操作しやすい形で)。
    var changes: RuleChanges {
        guard !rulesDiff.isEmpty else { return .none }
        // 規則の窓は、描くたびに何度もこれを読む。差分の文字が同じあいだは、JSON を読み直さない。
        if let parsed = parsedChanges, parsed.text == rulesDiff { return parsed.changes }
        let changes = (try? RuleChanges(data: Data(rulesDiff.utf8))) ?? .none
        parsedChanges = (rulesDiff, changes)
        return changes
    }

    @ObservationIgnored private var parsedChanges: (text: String, changes: RuleChanges)?

    /// 保存してある差分が、差分としても読めない(JSON が壊れている・`base`/`kind` が違う)ときの理由。読めれば nil。
    ///
    /// **このあいだは 1 か所ずつの変更を断る**(2026-09-22 の監査で指摘)。`changes` は読めない差分を「変更なし」として返すので、
    /// そのまま 1 か所変えると「変更なし + その 1 か所」で組み立てた差分が保存され、設定ファイルから文字のまま持ち続けていた
    /// 差分(型コメント)が写しも無く消えた。直すのは JSON の欄(差分を丸ごと書き直す)か、すべてを既定に戻すことだけにする。
    private var unparsableDiffIssue: String? {
        guard !rulesDiff.isEmpty else { return nil }
        do {
            _ = try RuleChanges(data: Data(rulesDiff.utf8))
            return nil
        } catch {
            return error.description
        }
    }

    /// 差分としても読めない保存済みの差分(文字のまま)。読めれば nil。JSON の欄はこれを丸ごと見せ、丸ごと書き直させる。
    var unreadableRulesDiff: String? { unparsableDiffIssue == nil ? nil : rulesDiff }

    /// 1 か所ずつの変更を断る理由(`unparsableDiffIssue`)。
    private var refusalForUnparsableDiff: [String]? {
        unparsableDiffIssue.map {
            ["The saved rules could not be read, so they cannot be changed one by one. Correct them in the JSON pane, or reset all the rules: %@".ui($0)]
        }
    }

    /// 規則の半分(ファイル名の解析 / シリーズと巻数)だけを、書いた JSON で差し替える。
    @discardableResult
    func setRulesDiff(_ text: String, for half: RuleChanges.Half) -> [String] {
        if let refusal = refusalForUnparsableDiff { return refusal }
        var next = changes
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            next.reset(half)
        } else {
            do { try next.replace(half, with: Data(trimmed.utf8)) } catch { return [error.description] }
        }
        return setRulesDiff(next.isEmpty ? "" : String(decoding: next.data(), as: UTF8.self))
    }

    /// その半分で、既定から変えている所の数(窓の下の帯に出す)。
    func changedCount(_ half: RuleChanges.Half) -> Int {
        // 変えた値の道筋は、シリーズの規則が段の名前で始まり、ファイル名の解析は presets / separators などで始まる。
        let fileNameRoots = ["presets", "separators", "defaultPreset", "defaults", "plain"]
        return rules.changedPaths.filter { path in
            let root = String(path.prefix { $0 != "." })
            return (half == .fileNames) == fileNameRoots.contains(root)
        }.count
    }

    /// 規則の半分だけを既定に戻す。
    @discardableResult
    func resetRules(_ half: RuleChanges.Half) -> [String] {
        // 読めない差分は半分だけ戻せない(どこが半分か分からない)ので、丸ごと既定に戻す。元の設定ファイルの写しは
        // 読んだときに残してある(load)。
        if unparsableDiffIssue != nil { return setRulesDiff("") }
        var next = changes
        next.reset(half)
        return setRulesDiff(next.isEmpty ? "" : String(decoding: next.data(), as: UTF8.self))
    }

    /// 規則を 1 か所変える。組み立ててみて誤りがあれば、変えずに理由を返す(画面がその場で示す)。
    @discardableResult
    func update(_ body: (inout RuleChanges) -> Void) -> [String] {
        if let refusal = refusalForUnparsableDiff { return refusal }
        var next = changes
        body(&next)
        return setRulesDiff(next.isEmpty ? "" : String(decoding: next.data(), as: UTF8.self))
    }

    /// 規則の差分を入れ替える。読めたら効かせ、誤りがあれば既定のままにして理由を返す。
    ///
    /// `keepingUnreadable` は、設定ファイルから読むときだけ真にする: 組み立てられなかった差分も**文字のまま持ち続ける**。
    @discardableResult
    func setRulesDiff(_ text: String, keepingUnreadable: Bool = false, saving: Bool = true) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousHash = rules.contentHash
        defer {
            if rules.contentHash != previousHash {
                if isAppWide { Self.appWideRules.withLock { [rules] in $0 = rules } }
                NotificationCenter.default.post(name: Self.rulesDidChange, object: self)
            }
        }
        guard !trimmed.isEmpty else {
            rulesDiff = ""
            rules = .builtin
            ruleIssues = []
            if saving { save() }
            return []
        }
        guard let builtIn = try? BuiltInRules.bundled() else {
            if keepingUnreadable { rulesDiff = trimmed }
            return ["The bundled rules could not be read".ui]
        }
        let compiled = CompiledRules.compile(RuleSources(builtIn: builtIn, userChanges: Data(trimmed.utf8)),
                                             dictionaries: Set(Self.dictionaryNames))
        guard let compiledRules = compiled.rules else {
            ruleIssues = compiled.errors.map(\.description)
            if keepingUnreadable { rulesDiff = trimmed }
            return ruleIssues
        }
        rulesDiff = trimmed
        rules = compiledRules
        ruleIssues = compiled.warnings.map(\.description)
        if saving { save() }
        return []
    }

    /// 規則が名前で指せる辞書(辞書そのものは読まない ―― 組み立ては名前だけで確かめる)。
    private nonisolated static let dictionaryNames = ["english"]

    // MARK: - 1 冊ぶんの読み取り(一覧を持たない所から)

    /// bookID(フルパス)から、解析に使う「拡張子を除いたファイル名」を求める。
    ///
    /// 単純に`deletingPathExtension()`を使うと、拡張子を持たないフォルダ名の一部が拡張子として
    /// 削られてしまう(例: 「作品名 vol.3」というフォルダが「作品名 vol」になり、巻数が
    /// 取れなくなる)。qooViewerが本として開けるファイル形式の拡張子である場合にだけ削ることで、
    /// フォルダ名を壊さないようにする。
    ///
    /// 元は `MetadataEditorViewModel.baseName(forBookID:)`(2026-09-21 に窓の作り直しでここへ移した)。表紙の名前の照合
    /// (`KnownBooks.matchKey` など)も使うので、**正規化はしない**(qooMeta へ渡す形は `parsingName`)。
    nonisolated static func baseName(forBookID bookID: String) -> String {
        let url = URL(fileURLWithPath: bookID)
        let fileName = url.lastPathComponent
        guard isArchiveFile(fileName) || isPDFFile(fileName) || isEpubFile(fileName) else { return fileName }
        return url.deletingPathExtension().lastPathComponent
    }

    /// qooMeta へ渡す名前: `baseName` を合成済みの形へ揃えたもの(`BookName.normalized`。macOS はファイル名を分解形で
    /// 返すことがあり、そのままだと濁点を含む語が規則の語と当たらない)。
    nonisolated static func parsingName(forBookID bookID: String) -> String {
        BookName.normalized(baseName(forBookID: bookID))
    }

    /// 本ごとに自動で選ぶルールセット(qooMeta のアプリの段 2 の「自動」と同じ条件)。**決まらない本は nil**
    /// (既定のルールセットで読む)。qooMeta のアプリは全冊が決まるときだけ「自動」を選ばせるが、qooViewer には段 2 が
    /// 無いので、決まらない本は既定で読み、型に合わなかった本を絞り込んで直してもらう(利用者の指示 2026-09-21)。
    nonisolated static func autoPreset(forBookID bookID: String, name: String, rules: CompiledRules) -> String? {
        autoPreset(forBookID: bookID, name: name, autoRules: autoPresetRules(of: rules))
    }

    /// ルールセットの自動の選択の条件(`rules.presetCatalog.autoRules`)。**多くの本を続けて選ぶときは 1 度だけ作って渡す** ――
    /// `presetCatalog` は読むたびに全ルールセットを JSON から組み立て直すので、本ごとに読むと冊数ぶん組み立てていた
    /// (2026-09-22 の監査)。
    nonisolated static func autoPresetRules(of rules: CompiledRules) -> AutoPresetRules {
        rules.presetCatalog.autoRules
    }

    typealias AutoPresetRules = [(name: String, rule: PresetAutoRule)]

    nonisolated static func autoPreset(forBookID bookID: String, name: String, autoRules: AutoPresetRules) -> String? {
        guard autoRules.contains(where: { $0.rule.isActive }) else { return nil }
        if case .one(let preset) = PresetAutoChoice.decide(path: bookID, name: name, rules: autoRules) { return preset }
        return nil
    }

    /// 1 冊をファイル名だけで読む(型の並びだけ。シリーズと巻は `@series`・`@volume` で読めたときだけ入る)。
    /// 題の解決のように、1 冊ずつすぐに要る所で使う。
    nonisolated static func reading(forBookID bookID: String, rules: CompiledRules) -> FormatReading {
        let name = parsingName(forBookID: bookID)
        return parseName(name, rules: rules, preset: autoPreset(forBookID: bookID, name: name, rules: rules))
    }

    /// 1 冊だけの提案(型で読んだ欄 + その 1 冊から導けるシリーズと巻)。1 冊ぶんのシートの初期値に使う。
    /// 同じ書き手のほかの本と見比べないので、番号の無いシリーズは見つからない(一覧のウインドウなら見つかる)。
    nonisolated static func singleProposal(forBookID bookID: String, rules: CompiledRules) -> QMBookMetadata {
        let name = parsingName(forBookID: bookID)
        let input = BookInput(id: bookID, name: name, preset: autoPreset(forBookID: bookID, name: name, rules: rules))
        let set = proposeSync([input], rules: rules, dictionaries: dictionaries)
        return set[bookID]?.metadata ?? parseName(name, rules: rules, preset: input.preset).metadata
    }

    // MARK: - 以前の規則の引き継ぎ

    private static let legacyFilenameFormatsKey = "qooViewer.metadata.filenameFormats"
    private static let legacyVolumeRulesKey = "qooViewer.metadata.volumeRules"
    private static let legacyExclusionRulesKey = "qooViewer.metadata.exclusionRules"
    private static let legacyMigratedKey = "qooViewer.metadata.migratedToQooMeta"
    /// 以前の規則から作るルールセットの名前。
    static let legacyPresetName = "qooviewer-legacy"

    /// 以前の既定のファイル名フォーマット(`MetadataFilenameFormat.defaults`、2026-09-21 に廃止)。
    /// 利用者がこれを変えていたときだけ引き継ぐ(変えていなければ qooMeta の同梱のルールセットのほうが細かい)。
    private static let legacyDefaultFormats = [
        "(@ignore) [@author (@ignore)] @title (@ignore) [@ignore]",
        "(@ignore) [@author (@ignore)] @title (@ignore)",
        "(@ignore) [@author (@ignore)] @title",
        "(@ignore) [@author] @title (@ignore) [@ignore]",
        "(@ignore) [@author] @title (@ignore)",
        "(@ignore) [@author] @title",
        "[@author (@ignore)] @title (@ignore) [@ignore]",
        "[@author (@ignore)] @title (@ignore)",
        "[@author (@ignore)] @title",
        "[@author] @title (@ignore) [@ignore]",
        "[@author] @title (@ignore)",
        "[@author] @title",
    ]

    /// 以前の JSON の形(`MetadataFilenameFormat`)。読むだけ。
    private struct LegacyFormat: Decodable { var pattern: String }

    /// 以前の「ファイル名フォーマット」を、利用者のルールセットとして 1 度だけ引き継ぐ。
    ///
    /// 巻数フォーマットと除外文字列の正規表現は引き継がない ―― qooMeta はシリーズと巻をタイトルから別の規則で
    /// 導くので、同じ意味の置き場が無い(抽出の設定の窓で、語の規則として足し直してもらう)。
    ///
    /// **引き継げたと確かめるまで以前の値を消さない**(2026-09-22 の監査で指摘)。以前は `defer` で必ず消していたので、
    /// 組み立てに失敗すると以前の規則が黙って全部失われた。qooMeta の型は以前の書式より厳しい(`@title` か `@series` が
    /// 要る・欄と欄のあいだに区切りの文字が要る)ので、以前は通った書式が 1 つ混じるだけでルールセットごと断られる。
    /// - qooMeta が読めない書式は外して、残りを引き継ぐ。外したものはルールセットの説明に書き残す(解析の設定の窓で見える)。
    /// - 以前の値を消すのは、全部を引き継げたときだけ。1 つでも外したら残す(引き継ぎ済みの旗は立てる ―― 同じ書式で
    ///   毎回やり直さない)。
    /// - 組み立てに失敗したら旗も立てない(次の起動でやり直す。qooMeta の版が上がれば通るかもしれない)。
    private func migrateLegacyFormatsIfNeeded(from defaults: UserDefaults) {
        guard !defaults.bool(forKey: Self.legacyMigratedKey) else { return }
        guard let data = defaults.data(forKey: Self.legacyFilenameFormatsKey),
              let formats = try? JSONDecoder().decode([LegacyFormat].self, from: data).map(\.pattern),
              !formats.isEmpty, formats != Self.legacyDefaultFormats,
              !rules.presetCatalog.names.contains(Self.legacyPresetName) else {
            finishLegacyMigration(in: defaults, removingLegacyValues: true)
            return
        }
        let (usable, unusable) = Self.partitionLegacyFormats(formats)
        guard !usable.isEmpty else {
            // 1 つも読めない: 引き継ぐ先が無い。以前の値は残す(手で書き直せるように)。
            NSLog("qooViewer: none of the %ld legacy file name formats can be read by qooMeta; they are kept", formats.count)
            finishLegacyMigration(in: defaults, removingLegacyValues: false)
            return
        }
        let builtInDefault = rules.presetCatalog.builtInDefaultPreset
        let errors = update { changes in
            changes.setPreset(Self.legacyPreset(formats: usable, unusable: unusable), original: nil)
            // 自動で決まらない本は、これまでの読み方で読む。
            changes.setDefaultPreset(Self.legacyPresetName, builtIn: builtInDefault)
        }
        guard errors.isEmpty else {
            NSLog("qooViewer: migrating the legacy file name formats failed: %@", errors.joined(separator: " / "))
            return
        }
        finishLegacyMigration(in: defaults, removingLegacyValues: unusable.isEmpty)
    }

    private func finishLegacyMigration(in defaults: UserDefaults, removingLegacyValues: Bool) {
        defaults.set(true, forKey: Self.legacyMigratedKey)
        guard removingLegacyValues else { return }
        defaults.removeObject(forKey: Self.legacyFilenameFormatsKey)
        defaults.removeObject(forKey: Self.legacyVolumeRulesKey)
        defaults.removeObject(forKey: Self.legacyExclusionRulesKey)
    }

    /// 以前の書式を、qooMeta が型として読めるもの・読めないものに分ける(順は保つ)。
    nonisolated static func partitionLegacyFormats(_ formats: [String]) -> (usable: [String], unusable: [String]) {
        var usable: [String] = [], unusable: [String] = []
        for format in formats {
            if (try? FilenameFormat(format)) != nil { usable.append(format) } else { unusable.append(format) }
        }
        return (usable, unusable)
    }

    /// 以前の書式から作るルールセット。読めなかった書式は説明に書き残す。
    ///
    /// **読めなかった書式を説明の先頭に置く**: 解析の設定の窓の説明欄は 3 行までしか見せないので、後ろに付けると
    /// 欄の中を送らないと見えなかった(2026-09-22 の実機検証)。由来の 1 行はルールセットの名前からも分かる。
    private static func legacyPreset(formats: [String], unusable: [String]) -> PresetCatalog.Preset {
        var note = "The file name formats you used before qooViewer switched to qooMeta".ui
        if !unusable.isEmpty {
            note = "These formats could not be carried over because qooMeta cannot read them: %@".ui(
                unusable.joined(separator: "  /  ")) + "\n" + note
        }
        return PresetCatalog.Preset(
            name: legacyPresetName, label: "qooViewer (previous settings)".ui, note: note,
            formats: formats.map { PresetCatalog.Format(text: $0) })
    }

    // MARK: - 保存

    private struct Stored: Codable {
        var rulesDiff: String = ""
        var stamps: [MetadataStamp] = []
        var excludedFolders: [String] = []

        init(rulesDiff: String, stamps: [MetadataStamp], excludedFolders: [String]) {
            self.rulesDiff = rulesDiff
            self.stamps = stamps
            self.excludedFolders = excludedFolders
        }

        /// **鍵が無くても、知らない値があっても、読める所だけを読む**(qooMeta の `AppSettings.Stored` と同じ)。
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            var skipped = false
            func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                guard c.contains(key) else { return fallback }
                if let value = try? c.decode(T.self, forKey: key) { return value }
                skipped = true
                return fallback
            }
            rulesDiff = read(.rulesDiff, "")
            let readStamps = read(.stamps, [Lossy<MetadataStamp>]())
            stamps = readStamps.compactMap(\.value)
            excludedFolders = read(.excludedFolders, [String]())
            skippedSomething = skipped || stamps.count != readStamps.count
        }

        var skippedSomething = false

        enum CodingKeys: String, CodingKey { case rulesDiff, stamps, excludedFolders }
    }

    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }

    /// 設定ファイルの読み書きで起きた問題。
    enum StorageIssue: Hashable {
        case unreadableKept(String)
        case partlyReadKept(String)
        case unreadableNotKept
        case notSaved(String)
    }

    private(set) var storageIssue: StorageIssue?

    var storageIssueText: String? {
        switch storageIssue {
        case nil: nil
        case .unreadableKept(let name):
            "The metadata rules file could not be read, so the default rules are used. The unreadable file was kept as “%@”.".ui(name)
        case .partlyReadKept(let name):
            "Part of the metadata rules file could not be read and was skipped. The file as it was is kept as “%@”.".ui(name)
        case .unreadableNotKept:
            "The metadata rules file could not be read, and no copy of it could be kept. Changes to the rules are not saved.".ui
        case .notSaved(let reason): "The metadata rules could not be saved: %@".ui(reason)
        }
    }

    /// 読めなかった設定ファイルを、まだ退避できていない。このあいだは上書きしない。
    private var holdsSaving = false

    func dismissStorageIssue() { storageIssue = nil }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: url))
            if stored.skippedSomething { keepCopy(partly: true) }
            stamps = stored.stamps
            excludedFolders = stored.excludedFolders
            setRulesDiff(stored.rulesDiff, keepingUnreadable: true, saving: false)
            // 差分としても読めない差分を持ち続けるなら、書き直される前に写しを残す(`unparsableDiffIssue`)。
            if !stored.skippedSomething, unparsableDiffIssue != nil { keepCopy(partly: true) }
        } catch {
            keepCopy(partly: false)
        }
    }

    /// 読めなかった(または一部を読み落とした)設定ファイルの写しを、隣に残す。残せなければ、上書きを止める。
    private func keepCopy(partly: Bool) {
        let folder = url.deletingLastPathComponent(), prefix = "settings.unreadable-"
        let original = try? Data(contentsOf: url)
        let kept = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
        if let original, let same = kept.first(where: { (try? Data(contentsOf: $0)) == original }) {
            storageIssue = partly ? .partlyReadKept(same.lastPathComponent) : .unreadableKept(same.lastPathComponent)
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let copy = folder.appendingPathComponent("\(prefix)\(stamp).json")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            storageIssue = partly ? .partlyReadKept(copy.lastPathComponent) : .unreadableKept(copy.lastPathComponent)
        } catch {
            holdsSaving = true
            storageIssue = .unreadableNotKept
        }
    }

    func save() {
        guard !holdsSaving else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(Stored(rulesDiff: rulesDiff, stamps: stamps, excludedFolders: excludedFolders))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            storageIssue = .notSaved(error.localizedDescription)
        }
    }

    // MARK: - 保存データの JSON

    /// 保存データの JSON に入れる規則の差分(rules-bundle)。変えていなければ nil。
    var exportableRulesBundle: String? { rulesDiff.isEmpty ? nil : rulesDiff }

    /// 保存データの JSON から読んだ規則の差分で置き換える。誤りがあれば置き換えずに理由を返す。
    @discardableResult
    func replaceRules(withBundle text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return setRulesDiff("") }
        guard let builtIn = try? BuiltInRules.bundled() else { return ["The bundled rules could not be read".ui] }
        let compiled = CompiledRules.compile(RuleSources(builtIn: builtIn, userChanges: Data(trimmed.utf8)),
                                             dictionaries: Set(Self.dictionaryNames))
        guard compiled.rules != nil else { return compiled.errors.map(\.description) }
        return setRulesDiff(trimmed)
    }

    /// 以前の保存データ(formatVersion 3・4 の `metadataFormats`)のファイル名フォーマットを、
    /// 利用者のルールセット「qooViewer(以前の設定)」として取り込む(すでにあれば置き換える)。
    /// qooMeta が読めない書式は外し、説明に書き残す(`migrateLegacyFormatsIfNeeded` と同じ扱い)。
    @discardableResult
    func importLegacyFilenameFormats(_ formats: [String]) -> [String] {
        let cleaned = formats.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return [] }
        let (usable, unusable) = Self.partitionLegacyFormats(cleaned)
        guard !usable.isEmpty else {
            return ["These formats could not be carried over because qooMeta cannot read them: %@".ui(
                unusable.joined(separator: "  /  "))]
        }
        let original = rules.presetCatalog.entries.first { $0.id == Self.legacyPresetName }?.original
        return update { $0.setPreset(Self.legacyPreset(formats: usable, unusable: unusable), original: original) }
    }
}

/// スタンプ: よく使う欄の値をまとめて、選んだ本へ一度に押すもの(qooMeta のアプリの `Stamp` を移した)。
/// 値の無い欄は触らない。
nonisolated struct MetadataStamp: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// 欄 → 値(並びの欄は値の並び)。
    var values: [QMBookMetadata.Field: [String]]

    init(id: UUID = UUID(), name: String, values: [QMBookMetadata.Field: [String]]) {
        self.id = id
        self.name = name
        self.values = values
    }

    /// 押したときに何が変わるかの短い説明。
    var summary: String {
        QMBookMetadata.Field.allCases.compactMap { field in
            guard let value = values[field], !value.isEmpty else { return nil }
            return "\(field.labelKey.ui): \(value.joined(separator: ", "))"
        }.joined(separator: " / ")
    }

    // 欄は文字列の鍵にする(Swift の既定の書き方だと鍵と値が交互に並ぶ配列になり、手で直せない)。
    enum CodingKeys: String, CodingKey { case id, name, values }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        let raw = try c.decodeIfPresent([String: [String]].self, forKey: .values) ?? [:]
        values = raw.reduce(into: [:]) { result, pair in
            guard let field = QMBookMetadata.Field(rawValue: pair.key) else { return }
            result[field] = pair.value
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }), forKey: .values)
    }
}

// MARK: - qooViewer の行 ↔ qooMeta の欄

nonisolated extension BookMetadataValues {
    /// qooMeta の欄から。
    init(_ metadata: QMBookMetadata) {
        self.init(title: metadata.title, authors: metadata.authors, genre: metadata.genre, event: metadata.event,
                  source: metadata.source, info: metadata.info, series: metadata.series, volume: metadata.volume,
                  volumeSort: metadata.volumeSort)
    }

    /// 登録済みの本を qooMeta へ渡すときの確定した内容。**登録済み = すべての欄が確定**
    /// (従来の約束「登録したメタデータは、規則を変えても変わらない」を保つ)。
    /// シリーズがあれば `.series`(巻が空なら「巻は無い」と確定)、無ければ「シリーズではない」。
    ///
    /// **シリーズの無い巻は、確定した欄の巻として渡す**(2026-09-22 の監査で指摘)。`.notInSeries` には巻の置き場が無く、
    /// 以前はここで巻を落としていた ―― 行の値は提案から作るので、以前の 4 つの欄のシートや ComicInfo/EPUB/PDF の取り込みで
    /// 登録した「シリーズ名は無いが巻はある」本(「上」「下」など)は、メタデータの編集ウインドウで巻が見えず、鍵を掛け直すと
    /// 巻の無い値で書き直された。qooMeta は確定した欄を名前の読みに重ね、シリーズに入らない本の巻はそのまま残す。
    var confirmation: Confirmation {
        var fields = ConfirmedFields()
        fields[.title] = title.isEmpty ? [] : [title]
        fields[.authors] = authors
        fields[.genre] = genre.isEmpty ? [] : [genre]
        fields[.event] = event.isEmpty ? [] : [event]
        fields[.source] = source.isEmpty ? [] : [source]
        fields[.info] = info.isEmpty ? [] : [info]
        guard !series.isEmpty else {
            fields[.volume] = volume.isEmpty ? [] : [volume]
            return .notInSeries(fields: fields)
        }
        return .series(name: series, volume: volume, fields: fields)
    }
}

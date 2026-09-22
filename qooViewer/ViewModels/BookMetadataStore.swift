import Foundation
import SwiftData
import Combine
import QooMetaKit

/// 書誌メタデータ(BookMetadata)の永続化・操作を、特定の本に限らず横断的に担当する。
/// LayoutStore/BookmarkStoreと同じ設計(SwiftDataを直接操作し、変更を
/// Notification.Name.bookMetadataDidChange経由で他のウインドウ/ViewerViewModelへ伝える)を
/// 踏襲する。
///
/// このクラス自体は「本を開いているかどうか」を意識しない。今開いている本のツールバー表示への
/// 反映は、ViewerViewModel側がbookMetadataDidChangeを購読して行う。
///
/// ModelContextはFavoritesStore/BookmarkStore/LayoutStoreと同じ、アプリ全体で1つだけの
/// `QooViewerApp.modelContainer.mainContext`を共有する(CLAUDE.md / QooViewerApp.init()の
/// コメント参照。コンテキストを分けると、一方のコンテキストのオブジェクトに対する更新・削除が
/// もう一方に反映されず静かに失敗する)。
@MainActor
final class BookMetadataStore: ObservableObject {
    private let modelContext: ModelContext

    /// メタデータが登録されている本のbookID一覧。「メタデータの編集」ウインドウの行の
    /// 色分け、およびEPUB/PDF出力ウインドウの対象判定・インジケータ表示に使う。
    ///
    /// LayoutStore.layoutBookIDsと同じく、このストアがBookMetadataの唯一の書き込み口である
    /// ことを前提に、各更新メソッドの最後で(saveAndNotify経由で)更新する。
    @Published private(set) var registeredBookIDs: Set<String> = []

    /// 「メタデータのどれかが変わった」ことだけを表す通し番号。**値そのものに意味は無い**
    /// (CollectionStore.revisionと同じ)。
    ///
    /// DBの内容から作った値を手元に覚えている側(BookTitleResolverのタイトルのキャッシュ)が、
    /// **読むその場で**古くなっていないかを確かめるために使う。.bookMetadataDidChangeの購読でも
    /// 捨てられるが、あの通知はメインキューへ積まれる = 画面の描き直しとの前後が保証されない
    /// ため、1フレームだけ古い文字が出うる。
    @Published private(set) var revision: UInt64 = 0

    /// 全件フェッチ結果をbookIDで引ける形にしてキャッシュしたもの。nilは「キャッシュ未構築」。
    /// LayoutStore.cachedSettingsByBookIDと同じ考え方・同じ理由(絞り込みフェッチではなく
    /// 全件フェッチ+Swift側での仕分け、かつinsert/deleteのたびに差分だけをキャッシュへ反映)。
    private var cachedByBookID: [String: BookMetadata]?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        registeredBookIDs = Set(metadataByBookID().keys)
    }

    // MARK: - 読み取り

    /// 指定したbookIDの登録済みメタデータ(未登録ならnil)。
    private func metadataByBookID() -> [String: BookMetadata] {
        if let cachedByBookID { return cachedByBookID }
        let fetched = (try? modelContext.fetch(FetchDescriptor<BookMetadata>())) ?? []
        var byBookID: [String: BookMetadata] = [:]
        byBookID.reserveCapacity(fetched.count)
        // 同じbookIDの行が万一複数あった場合は、フェッチ順で最初の1件を採用する
        // (LayoutStore.settingsByBookIDと同じ扱い)。
        for metadata in fetched where byBookID[metadata.bookID] == nil {
            byBookID[metadata.bookID] = metadata
        }
        cachedByBookID = byBookID
        return byBookID
    }

    func metadata(forBookID bookID: String) -> BookMetadata? {
        metadataByBookID()[bookID]
    }

    /// 登録済みのメタデータ全件(順不同)。JSONエクスポートなど、横断的に扱う経路でのみ使う。
    func allMetadata() -> [BookMetadata] {
        Array(metadataByBookID().values)
    }

    /// その本の行を、qooMeta との受け渡しの形で(ロックと直した欄つき)。
    func record(forBookID bookID: String) -> BookMetadataRecord? {
        metadata(forBookID: bookID)?.record
    }

    /// すべての行を、qooMeta との受け渡しの形で。
    func allRecords() -> [String: BookMetadataRecord] {
        metadataByBookID().mapValues(\.record)
    }

    /// この本にメタデータが登録されているか。
    func isRegistered(bookID: String) -> Bool {
        registeredBookIDs.contains(bookID)
    }

    // MARK: - 書き込み

    /// メタデータを登録(既に登録済みなら上書き)する。
    ///
    /// 4項目すべてが空の内容で登録しようとした場合は、行を作らず(既にあれば削除して)
    /// 未登録状態へ戻す。「登録済みだが中身が何も無い」行は、一覧の色分け上は登録済みに
    /// 見えるのに実際には何の情報も持たないという分かりにくい状態になるため。
    ///
    /// - Parameter sourceURL: 分かる場合は本の実URL。セキュリティスコープ付きブックマークと
    ///   ファイルノード識別子の生成に使う(今この本を開けている=このURLへのアクセス権を
    ///   持っている、という前提。LayoutStore.existingOrNewSettingsと同じ考え方)。
    ///   一覧から登録する場合など、URLが手元に無い場合はnilでよい。
    @discardableResult
    func upsert(bookID: String, values: BookMetadataValues, sourceURL: URL? = nil,
                fieldsVersion: Int = BookMetadata.currentFieldsVersion) -> BookMetadata? {
        switch applyUpsert(bookID: bookID, values: values, sourceURL: sourceURL, fieldsVersion: fieldsVersion) {
        case .updated(let metadata):
            saveAndNotify(bookID: bookID)
            return metadata
        case .removed:
            saveAndNotify(bookID: bookID)
            return nil
        case .noChange:
            return nil
        }
    }

    /// 従来の 4 つの欄だけを登録する入り口(EPUB/PDF/ComicInfo からの取り込みなど、4 つの欄しか持たない経路)。
    /// **ほかの欄(ジャンル・原作・2 人目以降の著者など)は、既にある行の値を保つ**(4 つの欄の取り込みで消さない)。
    ///
    /// `volumeSort` は巻数(並べ替え用)。EPUB/PDF/ComicInfo からの取り込みは、ファイルに書かれた巻数が
    /// 「シリーズの中の位置」の数なので、それを渡す(書き出しは並べ替え用の数を書くため、書き出したファイルを
    /// 読み込み直したときに並べ替え用の数として戻す。BookMetadata.exportableVolumeSort)。nil なら、巻数が
    /// 変わったときに捨てるだけ。
    @discardableResult
    func upsert(
        bookID: String,
        author: String,
        title: String,
        series: String,
        seriesIndex: String,
        volumeSort: Double? = nil,
        sourceURL: URL? = nil
    ) -> BookMetadata? {
        // 4 つの欄だけの登録は、以前の版の欄の登録と同じ扱い(空の欄を埋めるかを、メタデータの編集ウインドウで尋ねる)。
        // 既にいまの版の行なら、その版のまま。
        upsert(bookID: bookID, values: mergedLegacyValues(bookID: bookID, author: author, title: title,
                                                         series: series, seriesIndex: seriesIndex,
                                                         volumeSort: volumeSort),
               sourceURL: sourceURL, fieldsVersion: metadata(forBookID: bookID)?.fieldsVersion ?? 0)
    }

    /// 4 つの欄を、既にある行のほかの欄に重ねたもの。
    private func mergedLegacyValues(bookID: String, author: String, title: String, series: String,
                                    seriesIndex: String, volumeSort: Double?) -> BookMetadataValues {
        var values = metadata(forBookID: bookID)?.values ?? BookMetadataValues()
        var authors = values.authors
        let trimmedAuthor = author.trimmingCharacters(in: .whitespaces)
        if trimmedAuthor.isEmpty {
            authors = []
        } else if authors.first != trimmedAuthor {
            authors = [trimmedAuthor] + authors.dropFirst()
        }
        values.authors = authors
        values.title = title
        values.series = series
        if values.volume != seriesIndex.trimmingCharacters(in: .whitespaces) { values.volumeSort = nil }
        values.volume = seriesIndex
        if let volumeSort { values.volumeSort = volumeSort }
        return values
    }

    /// まとめて登録するための入り口(JSONインポート用)。取り込んだ件数を返す。
    ///
    /// upsert(...)を1件ずつ呼ぶと、そのたびにsave()とbookMetadataDidChange通知が出る。
    /// 通知1件につき、それを購読しているウインドウ(「メタデータの編集」「EPUB出力」「PDF出力」・
    /// 開いている本のビューア)のreload()が1回走り、EPUB/PDF出力のreload()は対象の本ごとに
    /// セキュリティスコープ付きブックマークの解決まで行うため、件数の二乗に比例したディスクI/Oに
    /// なっていた。save()も通知もそれぞれ1回にまとめる
    /// (FavoritesStore.removeFavorites(forBookID:)が1件ずつのsave()を避けているのと同じ考え方)。
    ///
    /// `values` が nil の件は登録を外す(メタデータの編集ウインドウの「登録を外す」と取り消し)。
    @discardableResult
    func upsertAll(_ entries: [BatchEntry]) -> Int {
        var changedBookIDs: [String] = []
        var importedCount = 0
        for entry in entries {
            let outcome: UpsertOutcome
            if let values = entry.values {
                outcome = applyUpsert(bookID: entry.bookID, values: values, sourceURL: entry.sourceURL,
                                      fieldsVersion: entry.fieldsVersion, state: entry.state,
                                      onlyIfUnlocked: entry.onlyIfUnlocked)
            } else if let existing = metadata(forBookID: entry.bookID) {
                modelContext.delete(existing)
                cachedByBookID?[entry.bookID] = nil
                outcome = .removed
            } else {
                outcome = .noChange
            }
            switch outcome {
            case .updated:
                importedCount += 1
                changedBookIDs.append(entry.bookID)
            case .removed:
                changedBookIDs.append(entry.bookID)
            case .noChange:
                break
            }
        }
        guard !changedBookIDs.isEmpty else { return 0 }

        do {
            try modelContext.save()
            lastSaveErrorMessage = nil
        } catch {
            logSaveFailure("upsertAll() failed for \(changedBookIDs.count) book(s): \(error)")
        }
        // `registeredBookIDs` は写しの上で直してから 1 度だけ差し替える(`@Published` の集合へ 1 件ずつ入れると、そのたびに
        // 知らせが飛ぶ。2,207 件の初回登録でここだけ 76 ms だった ―― 2026-09-22 の 2 回目の監査の実測)。
        let byBookID = metadataByBookID()
        var registered = registeredBookIDs
        for bookID in changedBookIDs {
            if byBookID[bookID] != nil {
                registered.insert(bookID)
            } else {
                registered.remove(bookID)
            }
        }
        if registered != registeredBookIDs { registeredBookIDs = registered }
        revision &+= 1
        // どの本かを特定しない通知として1回だけ投げる(全件リセットと同じ形。
        // 購読側は"bookID"が無い通知を「本を問わず対象」として扱う。BookMetadata.swift参照)。
        // 1 冊だけのときは、その本の通知にする(開いている本のビューアが、自分の本かどうかを見分けられるように)。
        let userInfo: [String: Any]? = changedBookIDs.count == 1 ? ["bookID": changedBookIDs[0]] : nil
        NotificationCenter.default.post(name: .bookMetadataDidChange, object: self, userInfo: userInfo)
        return importedCount
    }

    /// 画面を持たない自動の登録(スマートライブラリ・メタデータの編集ウインドウを開いたとき)を区切る件数
    /// (`upsertAllInBatches`)。
    nonisolated static let registrationBatchSize = 500

    /// `upsertAll` を `batchSize` 件ずつ、合間にメインを譲りながら書く(2026-09-22 の 2 回目の監査の 2)。
    ///
    /// 解析した本はすべて行を持つので、スマートライブラリを初めて出したとき・メタデータの編集ウインドウを初めて開いたときに、
    /// 数千冊を一度に登録する。実測(本番の写し、2,207 行): 1 回の `upsertAll` で 362 ms(適用 88 / save 191 /
    /// `registeredBookIDs` 76)、その間メインが止まった(最大 506 ms)。区切れば 1 回の止まりは 1 区切りぶんになる。
    /// 知らせは区切りごとに出る(受け手は bookID の無い知らせとして読み直す)。取り消されたら残りは書かない(次に解析された
    /// ときに書かれる ―― 登録は何度やっても同じ結果になる)。
    /// - Parameter didWrite: 1 区切りを書き終えるたびに、その区切りの件を渡す(どこまで書けたかを控える側のため)。
    @discardableResult
    func upsertAllInBatches(_ entries: [BatchEntry], batchSize: Int = registrationBatchSize,
                            didWrite: ([BatchEntry]) -> Void = { _ in }) async -> Int {
        var total = 0
        var start = 0
        while start < entries.count, !Task.isCancelled {
            let end = min(start + max(1, batchSize), entries.count)
            let batch = Array(entries[start..<end])
            total += upsertAll(batch)
            didWrite(batch)
            start = end
            // `Task.yield()` ではなく眠る: 譲った先がメインキューの同じ汲み出しの中で戻ってくると、入力の処理が挟まらない。
            if start < entries.count { try? await Task.sleep(for: .milliseconds(1)) }
        }
        return total
    }

    /// upsertAll(_:)へ渡す1件分。
    struct BatchEntry {
        let bookID: String
        /// 登録する値。nil なら登録を外す。
        let values: BookMetadataValues?
        /// 分かる場合は本の実URL(upsert(...)のsourceURLと同じ意味)。
        let sourceURL: URL?
        /// 欄の版(BookMetadata.fieldsVersion)。以前の保存データの JSON から読んだ行は 0。
        let fieldsVersion: Int
        /// ロックと直した欄。nil なら今の行のまま(新しい行は、`onlyIfUnlocked` でなければロックして作る ―― 保存データの
        /// 読み込みのように、利用者が登録した値を入れる経路)。
        var state: BookMetadataRowState?
        /// ファイル名から読み直した値を書く経路(規則の変更・スマートライブラリ)。**ロックした行には書かない**。
        /// 新しい行はロックせずに作る。
        var onlyIfUnlocked = false

        init(bookID: String, values: BookMetadataValues?, sourceURL: URL? = nil,
             fieldsVersion: Int = BookMetadata.currentFieldsVersion, state: BookMetadataRowState? = nil,
             onlyIfUnlocked: Bool = false) {
            self.bookID = bookID
            self.values = values
            self.sourceURL = sourceURL
            self.fieldsVersion = fieldsVersion
            self.state = state
            self.onlyIfUnlocked = onlyIfUnlocked
        }
    }

    /// 1件ぶんの登録内容を反映する。**save()も通知も行わない**(呼び出し側がまとめて行う)。
    private enum UpsertOutcome {
        case updated(BookMetadata)
        /// すべての欄が空だったため、既存の行を削除した。
        case removed
        /// すべての欄が空で、かつ元から行が無かった(DBに触れていない)。値が同じだった場合も。
        case noChange
    }

    private func applyUpsert(bookID: String, values: BookMetadataValues, sourceURL: URL?,
                             fieldsVersion: Int, state: BookMetadataRowState? = nil,
                             onlyIfUnlocked: Bool = false) -> UpsertOutcome {
        let values = values.trimmed
        if onlyIfUnlocked, metadata(forBookID: bookID)?.isLocked == true { return .noChange }

        guard !values.isEmpty else {
            guard let existing = metadata(forBookID: bookID) else { return .noChange }
            modelContext.delete(existing)
            cachedByBookID?[bookID] = nil
            return .removed
        }

        if let existing = metadata(forBookID: bookID) {
            // 同じ値なら書かない(メタデータの編集ウインドウは、行が変わるたびに登録済みの本を書き直す)。
            let unchanged = existing.values == values && existing.fieldsVersion == fieldsVersion
                && (state == nil || existing.rowState == state)
            if !unchanged {
                existing.values = values
                existing.fieldsVersion = fieldsVersion
                if let state { existing.apply(state) }
                existing.updatedAt = Date()
            }
            // 識別子・ブックマークは、これまで取れていなかった場合にだけ補完する
            // (既存の値を、解決できないかもしれない新しい値で上書きしない)。
            var filled = false
            if let sourceURL {
                if existing.bookmarkData == nil {
                    existing.bookmarkData = Self.makeBookmarkData(for: sourceURL)
                    filled = existing.bookmarkData != nil
                }
                if FileNodeIdentifier.needsBackfill(existing.fileNodeIdentifier),
                   let identifier = FileNodeIdentifier.current(for: sourceURL) {
                    existing.inodeNumber = identifier.inodeNumber
                    existing.volumeDeviceNumber = identifier.volumeDeviceNumber
                    existing.volumeUUID = identifier.volumeUUID
                    filled = true
                }
            }
            return unchanged && !filled ? .noChange : .updated(existing)
        }

        let created = BookMetadata(
            bookID: bookID,
            bookmarkData: sourceURL.flatMap(Self.makeBookmarkData(for:)),
            fileNodeIdentifier: sourceURL.flatMap(FileNodeIdentifier.current(for:))
        )
        created.values = values
        created.fieldsVersion = fieldsVersion
        created.apply(state ?? (onlyIfUnlocked ? BookMetadataRowState(isLocked: false) : .locked))
        modelContext.insert(created)
        cachedByBookID?[bookID] = created
        return .updated(created)
    }

    // MARK: - ファイル名の解析・ファイルの書誌情報の登録(2026-09-22)

    /// 行の無い本を、ファイル名から読んだ値で登録する(ロックせずに。本を開いたとき)。行があれば何もしない。
    func registerParsed(bookID: String, rules: CompiledRules, sourceURL: URL? = nil) {
        guard metadata(forBookID: bookID) == nil else { return }
        let values = MetadataParsing.values(forBookID: bookID, rules: rules)
        upsertAll([BatchEntry(bookID: bookID, values: values, sourceURL: sourceURL,
                              state: BookMetadataRowState(isLocked: false))])
    }

    /// ファイル(EPUB/PDF/ComicInfo.xml)の書誌情報を取り込む。**1 冊につき 1 度だけ、ロックしていない行にだけ**。
    /// 利用者が直した欄は変えず、それ以外をファイルの値にする(利用者の指示 2026-09-22)。取り込んだ値は直した欄として持つ
    /// (規則を変えてもファイル名の読みに戻らない。「メタデータを再生成」ではファイル名の読みに戻る)。
    /// - Returns: 取り込んだか。
    @discardableResult
    func importSourceMetadata(bookID: String, source: SourceBookMetadata, rules: CompiledRules,
                              sourceURL: URL? = nil) -> Bool {
        let row = metadata(forBookID: bookID)
        guard row?.isLocked != true, row?.didImportSourceMetadata != true else { return false }
        let current = row?.rowState ?? BookMetadataRowState(isLocked: false)
        var state = current
        state.edits = MetadataParsing.merging(source, into: current.edits)
        let values = MetadataParsing.values(forBookID: bookID, edits: state.edits, ruleSet: state.ruleSet, rules: rules)
        let outcome = applyUpsert(bookID: bookID, values: values, sourceURL: sourceURL,
                                  fieldsVersion: BookMetadata.currentFieldsVersion, state: state)
        guard let imported = metadata(forBookID: bookID) else {
            if case .removed = outcome { saveAndNotify(bookID: bookID) }
            return false
        }
        imported.didImportSourceMetadata = true
        saveAndNotify(bookID: bookID)
        return true
    }

    /// ファイルの書誌情報を取り込み済みの印を立てる(保存データの JSON の読み込み。`ExportedBookMetadataEntry.importedSourceMetadata`)。
    /// ロックした行にも立てる(外したときに取り込み直さないように)。
    func markSourceMetadataImported(_ bookIDs: Set<String>) {
        let rows = bookIDs.compactMap { metadata(forBookID: $0) }.filter { !$0.didImportSourceMetadata }
        guard !rows.isEmpty else { return }
        for row in rows { row.didImportSourceMetadata = true }
        do {
            try modelContext.save()
            lastSaveErrorMessage = nil
        } catch {
            logSaveFailure("markSourceMetadataImported() failed for \(rows.count) book(s): \(error)")
        }
    }

    /// ほかに覚えている理由の無い、ファイル名の読みだけの行を消す(`BookMetadata.isParsedOnly`。2026-09-22 の 2 回目の監査の 3)。
    ///
    /// 解析した本はすべて行を持つ(本を開いた・スマートライブラリに並んだ・メタデータの編集ウインドウに並んだ)が、読書位置
    /// (「データを保持する本の数」で間引かれる)と違い、行は間引かれなかった。メタデータの編集ウインドウの一覧は「このアプリが
    /// 知っている本」(`KnownBooks`)で、そこには行を持つ本も入るので、**行があるから一覧に出て、一覧に出るから行が残る** ――
    /// 読書位置を間引かれた本・スマートライブラリの対象から外したフォルダの本・消した本の行が一覧に並び続け、窓を開くたびの
    /// 読み直し(`ProposalIndex`)と登録の量も増え続けた。
    ///
    /// 消すのは、ロックも直した欄も無く(消しても同じ行がまたできる)、`known`(行のほかに本を覚えている理由 ―― 読書位置・
    /// ブックマーク・レイアウト・お気に入り・コレクション)にも無く、`folders`(スマートライブラリの対象フォルダ。機能を OFF にして
    /// いても残す)の中にも無い本の行だけ。
    /// - Returns: 消した行の数。
    @discardableResult
    func pruneParsedOnlyRows(keeping known: Set<String>, keepingFolders folders: [String]) -> Int {
        let targets = metadataByBookID().values.filter { row in
            row.isParsedOnly && !known.contains(row.bookID)
                && !folders.contains { MountTable.path(row.bookID, isAtOrUnder: $0) }
        }
        guard !targets.isEmpty else { return 0 }
        for row in targets {
            cachedByBookID?[row.bookID] = nil
            modelContext.delete(row)
        }
        do {
            try modelContext.save()
            lastSaveErrorMessage = nil
        } catch {
            logSaveFailure("pruneParsedOnlyRows() failed for \(targets.count) book(s): \(error)")
        }
        registeredBookIDs.subtract(targets.map(\.bookID))
        revision &+= 1
        NotificationCenter.default.post(name: .bookMetadataDidChange, object: self, userInfo: nil)
        return targets.count
    }

    /// ロックしていない行を、いまの規則で読み直して書く(規則を変えたとき。全行を互いの錨にして読む)。
    /// - Returns: 書き直した行の数。
    @discardableResult
    func reparseUnlockedRows(rules: CompiledRules) async -> Int {
        let records = allRecords()
        guard records.values.contains(where: { !$0.isLocked }) else { return 0 }
        let parsed = await MetadataParsing.values(for: records, rules: rules)
        let entries = records.keys.sorted().compactMap { id -> BatchEntry? in
            // 読み直している間に消えた・ロックされた行は書かない(`onlyIfUnlocked` と行の有無で確かめる)。
            guard let values = parsed[id], let record = self.record(forBookID: id), !record.isLocked,
                  record.values != values.trimmed else { return nil }
            return BatchEntry(bookID: id, values: values, onlyIfUnlocked: true)
        }
        guard !entries.isEmpty else { return 0 }
        return upsertAll(entries)
    }

    /// 以前の版の欄で登録した行(`fieldsVersion` がいまより古い)の bookID。
    var outdatedFieldBookIDs: Set<String> {
        Set(metadataByBookID().values.filter { $0.fieldsVersion < BookMetadata.currentFieldsVersion }.map(\.bookID))
    }

    /// 以前の版の欄で登録した行の、**空の欄だけ**をファイル名から読んだ値で埋める(登録した値はそのまま)。
    /// 埋める欄: ジャンル・イベント・原作・情報と、2 人目以降の著者(先頭の著者が同じときだけ)。埋めたら今の版にする。
    /// - Returns: 版を上げた行の数。
    @discardableResult
    func fillMissingFields(of bookIDs: some Sequence<String>, reading: (String) -> BookMetadataValues) -> Int {
        var count = 0
        for bookID in bookIDs {
            guard let row = metadata(forBookID: bookID), row.fieldsVersion < BookMetadata.currentFieldsVersion else { continue }
            let read = reading(bookID)
            var values = row.values
            if values.genre.isEmpty { values.genre = read.genre }
            if values.event.isEmpty { values.event = read.event }
            if values.source.isEmpty { values.source = read.source }
            if values.info.isEmpty { values.info = read.info }
            if values.authors.count <= 1, read.authors.count > 1, read.authors.first == values.authors.first ?? read.authors.first {
                values.authors = read.authors
            }
            row.values = values
            row.fieldsVersion = BookMetadata.currentFieldsVersion
            row.updatedAt = Date()
            count += 1
        }
        guard count > 0 else { return 0 }
        do {
            try modelContext.save()
            lastSaveErrorMessage = nil
        } catch {
            logSaveFailure("fillMissingFields() failed for \(count) book(s): \(error)")
        }
        revision &+= 1
        NotificationCenter.default.post(name: .bookMetadataDidChange, object: self, userInfo: nil)
        return count
    }

    /// 登録を解除する(未登録なら何もしない)。
    func delete(forBookID bookID: String) {
        guard let existing = metadata(forBookID: bookID) else { return }
        modelContext.delete(existing)
        cachedByBookID?[bookID] = nil
        saveAndNotify(bookID: bookID)
    }

    /// 全件削除(環境設定「リセット」タブ、およびJSONインポートの「置き換え」用)。
    func deleteAllMetadata() {
        do {
            try modelContext.delete(model: BookMetadata.self)
            try modelContext.save()
            lastSaveErrorMessage = nil
        } catch {
            logSaveFailure("deleteAllMetadata() failed: \(error)")
        }
        // 一括削除はどの行が消えたかを個別に追えないため、キャッシュは「空」として作り直す
        // (LayoutStore.deleteAllLayoutDataと同じ理由)。
        cachedByBookID = [:]
        registeredBookIDs = []
        revision &+= 1
        NotificationCenter.default.post(name: .bookMetadataDidChange, object: self, userInfo: nil)
    }

    // MARK: - bookIDの追従・URL解決

    /// ユーザー要望(他のモデルと同様): メタデータが付いている本が、同一ボリューム内で移動・
    /// リネームされた場合でも登録内容を引き継げるようにする(ボリュームを跨いだ移動は諦める)。
    /// LayoutStore.reconcileBookIDIfMoved(book:)と同じ考え方。AppState.open(url:)から、本を
    /// 開くたびに呼ばれる想定。
    func reconcileBookIDIfMoved(book: MangaBook) {
        guard metadata(forBookID: book.id) == nil else { return }
        guard let identifier = FileNodeIdentifier.current(for: book.sourceURL) else { return }
        // 同じiノードを指す行が過去のパスぶん複数残っている場合に備えて、最後に更新された
        // 行を選ぶ(LayoutStoreと同じ基準)。
        guard let matched = allMetadata()
            .filter({ $0.bookID != book.id && $0.fileNodeIdentifier == identifier })
            .max(by: { $0.updatedAt < $1.updatedAt })
        else { return }

        let oldBookID = matched.bookID
        matched.bookID = book.id
        matched.updatedAt = Date()
        // bookIDはキャッシュ辞書のキーそのものなので、旧キーから新キーへ移す。
        cachedByBookID?[oldBookID] = nil
        cachedByBookID?[book.id] = matched
        registeredBookIDs.remove(oldBookID)
        saveAndNotify(bookID: book.id)
    }

    /// 行のある本の `bookID`(アプリ自身が移した本の付け替えの材料。BookRelocationPlan)。
    var knownBookIDs: Set<String> { Set(metadataByBookID().keys) }

    /// アプリ自身が移した・名前を変えた本のメタデータを新しいパスへ付け替える(BookRelocationPlan の型コメント)。
    /// - Returns: 付け替えた本の数。
    @discardableResult
    func applyBookRelocation(_ plan: BookRelocationPlan) -> Int {
        let byBookID = metadataByBookID()
        var relocated = 0
        for (old, new) in plan.bookIDs {
            guard let row = byBookID[old], byBookID[new] == nil else { continue }
            row.bookID = new
            if let locator = plan.locators[new] {
                row.inodeNumber = locator.identifier?.inodeNumber
                row.volumeDeviceNumber = locator.identifier?.volumeDeviceNumber
                row.volumeUUID = locator.identifier?.volumeUUID
                if let data = locator.bookmarkData { row.bookmarkData = data }
            }
            relocated += 1
        }
        guard relocated > 0 else { return 0 }
        do {
            try modelContext.save()
            lastSaveErrorMessage = nil
        } catch {
            logSaveFailure("applyBookRelocation() failed: \(error)")
        }
        // 鍵(bookID)を書き換えたので、辞書のキャッシュは捨てて読み直す。
        cachedByBookID = nil
        registeredBookIDs = Set(metadataByBookID().keys)
        revision &+= 1
        NotificationCenter.default.post(name: .bookMetadataDidChange, object: self, userInfo: nil)
        return relocated
    }

    /// bookIDからこの本の実URLを解決する(LayoutStore.resolvedURLと同じ考え方)。
    /// セキュリティスコープ付きブックマークが無い/解決できない場合は素のパスへフォールバックし、
    /// どちらでもファイルが見つからなければnilを返す。
    func resolvedURL(forBookID bookID: String) -> URL? {
        if let data = metadata(forBookID: bookID)?.bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale
            ), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let fallbackURL = URL(fileURLWithPath: bookID)
        guard FileManager.default.fileExists(atPath: fallbackURL.path) else { return nil }
        return fallbackURL
    }

    /// ファイルノード識別子・セキュリティスコープ付きブックマークを持たない行について、
    /// 本を開けた(=アクセス権を持っている)タイミングで補完する。
    /// LayoutStore.backfillFileNodeIdentifierと同じ考え方。
    func backfillIdentifiers(forBookID bookID: String, sourceURL: URL) {
        guard let metadata = metadata(forBookID: bookID) else { return }
        var didChange = false
        if FileNodeIdentifier.needsBackfill(metadata.fileNodeIdentifier),
           let identifier = FileNodeIdentifier.current(for: sourceURL) {
            metadata.inodeNumber = identifier.inodeNumber
            metadata.volumeDeviceNumber = identifier.volumeDeviceNumber
            metadata.volumeUUID = identifier.volumeUUID
            didChange = true
        }
        if metadata.bookmarkData == nil, let data = Self.makeBookmarkData(for: sourceURL) {
            metadata.bookmarkData = data
            didChange = true
        }
        guard didChange else { return }
        // 行の増減もbookIDの変化も無いため、キャッシュには手を入れなくてよい
        // (キャッシュが保持しているのはこのmetadata自身と同じ参照)。
        do {
            try modelContext.save()
            lastSaveErrorMessage = nil
        } catch {
            logSaveFailure("backfillIdentifiers() failed for bookID=\(bookID): \(error)")
        }
    }

    // MARK: - 内部処理

    /// 直近のsave()が失敗した場合のエラーメッセージ(デバッグ用)。
    /// LayoutStore.lastSaveErrorMessageと同じ目的(try?で握りつぶさず、Console.appから
    /// 追えるようにしておく)。
    private(set) var lastSaveErrorMessage: String?

    private static func makeBookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func saveAndNotify(bookID: String) {
        do {
            try modelContext.save()
            lastSaveErrorMessage = nil
        } catch {
            logSaveFailure("save() failed for bookID=\(bookID): \(error)")
        }
        if metadataByBookID()[bookID] != nil {
            registeredBookIDs.insert(bookID)
        } else {
            registeredBookIDs.remove(bookID)
        }
        revision &+= 1
        NotificationCenter.default.post(
            name: .bookMetadataDidChange, object: self, userInfo: ["bookID": bookID]
        )
    }

    private func logSaveFailure(_ detail: String) {
        let message = "qooViewer: BookMetadataStore.\(detail)"
        lastSaveErrorMessage = message
        #if DEBUG
        print(message)
        #endif
        NSLog("%@", message)
    }
}

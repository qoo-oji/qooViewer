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
    /// 共有の 1 つ(CLAUDE.md「SwiftData persistence」)。AppState が本を開いたときの読書位置の付け替えにも使う。
    let modelContext: ModelContext

    /// この起動の間に利用者が消した行(「メタデータを削除」・保存データの削除)。スマートライブラリはこれを作り直さない
    /// (docs/07 の約束。2026-09-22 の監査: 以前は自分がこの起動中に書いた本しか覚えておらず、削除の知らせで走った集め直しが
    /// 消した行をすぐ作り直した)。窓を開き直す・本を開くなど、ファイル名の読みだけではない書き手が書けば外れる(`applyUpsert`)。
    /// 起動し直せば空に戻る(消したことは覚えておかない ―― 利用者の指示 2026-09-22)。
    private(set) var deletedThisSession: Set<String> = []

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
                deletedThisSession.insert(entry.bookID)
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
        // ファイル名の読みだけの書き手(スマートライブラリ・規則の読み直し)以外が作ったら、消した印を外す。
        if !onlyIfUnlocked { deletedThisSession.remove(bookID) }
        return .updated(created)
    }

    // MARK: - ファイル名の解析・ファイルの書誌情報の登録(2026-09-22)

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
    /// - Parameter folderBooks: 対象フォルダの中に今ある本(スマートライブラリが最後に探した一覧)。渡したときは、対象フォルダの中でも
    ///   ここに無い本の行は消す(2026-09-22 の監査。以前は対象フォルダの中の行を無条件に残し、Finder で消した・名前を変えた本の
    ///   古いパスの行がメタデータの編集ウインドウに灰色で残り続けた)。nil(一覧が無い・探しきれていない)なら今までどおり残す。
    func pruneParsedOnlyRows(keeping known: Set<String>, keepingFolders folders: [String],
                             folderBooks: Set<String>? = nil) -> Int {
        let targets = metadataByBookID().values.filter { row in
            guard row.isParsedOnly, !known.contains(row.bookID) else { return false }
            guard folders.contains(where: { MountTable.path(row.bookID, isAtOrUnder: $0) }) else { return true }
            return folderBooks.map { !$0.contains(row.bookID) } ?? false
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
        deletedThisSession.insert(bookID)
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
    /// - Returns: 付け替えた元の `bookID`(複数あれば 1 つ)。付け替えなかったら nil。AppState が読書位置を同じ先へ付け替えるのに使う。
    @discardableResult
    ///
    /// 新しいパスに**ファイル名の読みだけの行**(`isParsedOnly`)があれば、古い行(ロック・直した欄のあるもの)で置き換える
    /// (2026-09-22、利用者の報告。解析した本はすべて登録するので、スマートライブラリやメタデータの編集ウインドウが先に新しい
    /// 名前の行を作っていると、以前は「新しいパスに行がある」で付け替えをやめ、直した値とロックが古い名前に取り残された)。
    func reconcileBookIDIfMoved(book: MangaBook) -> String? {
        let current = metadata(forBookID: book.id)
        if let current, !current.isParsedOnly { return nil }
        guard let identifier = FileNodeIdentifier.current(for: book.sourceURL) else { return nil }
        // 同じiノードを指す行が過去のパスぶん複数残っている場合に備えて、最後に更新された
        // 行を選ぶ(LayoutStoreと同じ基準)。新しいパスに読みだけの行があるときは、読みだけではない行だけを候補にする。
        guard let matched = allMetadata()
            .filter({ $0.bookID != book.id && $0.fileNodeIdentifier == identifier && (current == nil || !$0.isParsedOnly) })
            .max(by: { $0.updatedAt < $1.updatedAt })
        else { return nil }

        if let current {
            modelContext.delete(current)
            cachedByBookID?[book.id] = nil
        }
        let oldBookID = matched.bookID
        if !matched.isLocked {
            NotificationCenter.default.post(name: .bookMetadataUnlockedRowsRelocated, object: self)
        }
        matched.bookID = book.id
        matched.updatedAt = Date()
        // bookIDはキャッシュ辞書のキーそのものなので、旧キーから新キーへ移す。
        cachedByBookID?[oldBookID] = nil
        cachedByBookID?[book.id] = matched
        registeredBookIDs.remove(oldBookID)
        saveAndNotify(bookID: book.id)
        return oldBookID
    }

    /// 行のある本の `bookID`(アプリ自身が移した本の付け替えの材料。BookRelocationPlan)。
    var knownBookIDs: Set<String> { Set(metadataByBookID().keys) }

    /// アプリ自身が移した・名前を変えた本のメタデータを新しいパスへ付け替える(BookRelocationPlan の型コメント)。
    /// - Returns: 付け替えた本の数。
    @discardableResult
    func applyBookRelocation(_ plan: BookRelocationPlan) -> Int {
        let byBookID = metadataByBookID()
        var relocated = 0
        var relocatedUnlocked = false
        // 新しいパスに読みだけの行があり、その行がこの付け替えで出ていかないなら、古い行(ロック・直した欄のあるもの)で置き換える
        // (reconcileBookIDIfMoved と同じ決まり)。先に消してから、動かす組を決める。
        var present = Set(byBookID.keys)
        for (old, new) in plan.bookIDs {
            guard let row = byBookID[old], let existing = byBookID[new], plan.bookIDs[new] == nil,
                  existing.isParsedOnly, !row.isParsedOnly, present.contains(new) else { continue }
            modelContext.delete(existing)
            present.remove(new)
        }
        // 実際に動かす組は、付け替えの後の姿で決める(BookRelocationPlan.moves。連なる改名・入れ替えで取り残さない)。
        for (old, new) in plan.moves(present: present) {
            guard let row = byBookID[old] else { continue }
            row.bookID = new
            if !row.isLocked { relocatedUnlocked = true }
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
        if relocatedUnlocked { NotificationCenter.default.post(name: .bookMetadataUnlockedRowsRelocated, object: self) }
        return relocated
    }

    /// bookIDからこの本の実URLを解決する(LayoutStore.resolvedURLと同じ考え方)。
    /// セキュリティスコープ付きブックマークが無い/解決できない場合は素のパスへフォールバックし、
    /// どちらでもファイルが見つからなければnilを返す。
    func resolvedURL(forBookID bookID: String, purpose: BookmarkResolution.Purpose = .background) -> URL? {
        if let data = metadata(forBookID: bookID)?.bookmarkData {
            if let url = BookmarkResolution.resolve(data, purpose: purpose), FileManager.default.fileExists(atPath: url.path) {
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

    private nonisolated static func makeBookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// 本の場所の手がかり(ブックマークと識別子)。**ファイルに触る**ので、多くの本をまとめて作るときはメインの外で
    /// (`fillLocators`。2026-09-23 の 3 回目の監査の低: メタデータの編集ウインドウの一括の操作で、数千冊ぶんをメインで作っていた)。
    nonisolated static func makeLocator(for url: URL) -> (bookmark: Data?, identifier: FileNodeIdentifier?) {
        (makeBookmarkData(for: url), FileNodeIdentifier.current(for: url))
    }

    /// 手がかりの無い行に、メインの外で作った手がかりを入れる(`upsertAll` の `sourceURL` と同じく、まだ無いときだけ)。
    /// 行の値・形は変えないので、変更の知らせは出さない。
    func fillLocators(_ locators: [String: (bookmark: Data?, identifier: FileNodeIdentifier?)]) {
        let byBookID = metadataByBookID()
        var changed = false
        for (bookID, locator) in locators {
            guard let row = byBookID[bookID] else { continue }
            if row.bookmarkData == nil, let bookmark = locator.bookmark {
                row.bookmarkData = bookmark
                changed = true
            }
            if FileNodeIdentifier.needsBackfill(row.fileNodeIdentifier), let identifier = locator.identifier {
                row.inodeNumber = identifier.inodeNumber
                row.volumeDeviceNumber = identifier.volumeDeviceNumber
                row.volumeUUID = identifier.volumeUUID
                changed = true
            }
        }
        guard changed else { return }
        do {
            try modelContext.save()
            lastSaveErrorMessage = nil
        } catch {
            logSaveFailure("fillLocators save() failed: \(error)")
        }
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

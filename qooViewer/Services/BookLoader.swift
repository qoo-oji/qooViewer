import Foundation
import CoreGraphics

/// 指定された1つのフォルダ、またはアーカイブファイルから、1冊の本(MangaBook)を読み込む。
///
/// フォルダの再帰スキャンやアーカイブの展開はファイルの数によっては時間がかかることがある。
/// 以前はAppState(MainActor)から同期的に直接呼んでいたため、その間メインスレッドが
/// 完全にブロックされ、操作不能な状態(レインボーカーソル)になってしまっていた。
/// そのため実際の読み込み処理はTask.detachedでメインスレッド外に逃がし、`load`自体は
/// async化して呼び出し側(AppState)がawaitで待てるようにしている。
/// nonisolated: Xcode 26既定のMainActor自動分離の対象外にして、どのコンテキストからでも
/// 呼べるようにしている(詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated enum BookLoader {
    /// - Parameter cachesPageList: falseならページ一覧のディスクキャッシュ(BookPageListCache)へ
    ///   書き戻さない。シークレットウインドウ(AppState.isPrivateWindow)で開く本に使う。
    /// - Parameter nestedArchiveMemoryLimitBytes: 入れ子の書庫を列挙するあいだ、メモリ上に
    ///   載せてよい合計バイト数(環境設定「キャッシュ」の値。NestedArchiveResolver.Limits参照)。
    /// - Parameter onProgress: 読み込みの進み具合。**メインアクター外から呼ばれる**ため、
    ///   UIへ反映するなら呼び出し側でホップすること。読み込みは外付け/ネットワークボリューム上の
    ///   本では長く待つため、ここで自分を強参照で捕まえないよう注意する(AppState.open参照)。
    static func load(
        from url: URL,
        cachesPageList: Bool = true,
        nestedArchiveMemoryLimitBytes: Int = AppPreferences.defaultNestedArchiveMemoryLimitBytes,
        onProgress: (@Sendable (BookLoadProgress) -> Void)? = nil
    ) async throws -> MangaBook {
        // 「並び順をFinderに揃える」は、1回の読み込みのあいだ**1度だけ**読む。並べ替え・
        // 構造キャッシュの照合・書き戻しのすべてに同じ値を使うことが重要で、途中で読み直すと、
        // 読み込みの最中に設定を切り替えられた場合に「古い並びのページ一覧を、新しい設定の
        // ラベルを付けて保存する」ことが起こりうる(次に開いたとき、照合を素通りして古い並びの
        // まま復元されてしまう)。
        let usesFinderSortOrder = PageOrder.usesFinderOrder
        // 入れ子の書庫を含む本は、ページを数え上げるだけでも中の書庫を1つずつ取り出す必要が
        // ある。2回目以降はその走査ごと飛ばす(BookPageListCache.Entryの構造キャッシュの
        // コメント参照)。シークレットウインドウでは書かないだけでなく**読みもしない** ――
        // 通常ウインドウで作られたキャッシュを読むと痕跡こそ残らないが、同じ本でも開き方に
        // よって挙動が変わることになるため、安全側に倒して常にフルの読み込みにする。
        if cachesPageList,
           let restored = await restoredFromStructureCache(url: url, usesFinderSortOrder: usesFinderSortOrder) {
            return restored
        }

        let limits = NestedArchiveResolver.Limits.standard(inMemoryBytes: nestedArchiveMemoryLimitBytes)
        let task = Task.detached(priority: .userInitiated) { () throws -> MangaBook in
            try loadSync(
                from: url, limits: limits, usesFinderSortOrder: usesFinderSortOrder, onProgress: onProgress
            )
        }
        // Task.detachedはキャンセルを**継承しない**(Swiftの仕様。PageLoader.
        // cancellableInFlightKeysのコメントに同じ落とし穴の記録がある)。呼び出し側の
        // Task(AppState.openTask)が中止されたことを、ここで手動で中へ伝える。
        // これが無いと、ユーザーが「中止」を押しても巨大な入れ子本の走査が最後まで走り切る。
        let book = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard cachesPageList else { return book }
        // 読み込みに成功したページ一覧は、ここで一括してキャッシュへ書き戻す。
        //
        // この読み込み自体は書庫の全走査を伴い、本体が未接続の外付け/ネットワークボリューム上に
        // あると相応に時間がかかる。一方で、ページの並び順とファイル名しか要らない画面
        // (「ブックマーク・レイアウトの編集」ウインドウの右ペイン、EPUB出力ウインドウの
        // カバー名列)がいくつかあり、そうした画面はこのキャッシュだけで描画できる。
        // 経路ごとに書き戻すのではなくこの1か所に置くことで、どの経路で1度読み込んでも
        // 他の画面がその恩恵を受けられるようにしている(詳細はBookPageListCacheの型コメント参照)。
        //
        // **書き込みは待たない。** ここはあらゆる経路の「本を開く」処理が必ず通る場所で、
        // 待つとJSONへの変換・ディスクへの書き込み・(起動後1回目は)キャッシュ全体の容量点検が
        // そのまま本の表示までの待ち時間に乗る。このキャッシュは次に同じ本を開くときまでに
        // 書けていればよく、失敗しても次回また読み込むだけ
        // (PageLoader.thumbnail(at:)がサムネイルの保存を待たないのと同じ考え方)。
        let entry = structureCacheEntry(for: book, usesFinderSortOrder: usesFinderSortOrder)
        let bookID = book.id
        Task.detached(priority: .background) {
            await BookPageListCache.shared.store(entry, forBookID: bookID)
        }
        return book
    }

    /// 1回の読み込みのあいだだけ共有する道具一式。
    ///
    /// **この読み込みが終われば丸ごと捨てる。** Resolverが抱えている一時ファイルとファイル
    /// ハンドルも、そのタイミングで確実に手放したいので、loadSyncがdeferでpurgeAll()する。
    /// ページを実際に読むときの展開はPageLoaderが持つ別のResolverが行うため、ここで
    /// 温めたものを引き継ぐ必要は無い(引き継ごうとすると、隔離ドメインをまたいで
    /// スレッド安全でないReaderを受け渡すことになる)。
    private struct LoadContext {
        let resolver: NestedArchiveResolver
        let progress: LoadProgressReporter
        /// この読み込みでページを並べるときの「Finderと同じ名前順にするか」
        /// (load(from:)が1度だけ読んだ値。comparePageOrder参照)。
        let usesFinderSortOrder: Bool
    }

    /// 読み込んだ本を、次回の高速経路のために保存できる形へ畳む
    /// (BookPageListCache.Entryの構造キャッシュのコメント参照)。
    ///
    /// ページの並び順とファイル名しか要らない画面(レイアウト編集ウインドウの右ペイン等)は
    /// 従来どおりsortKey/displayNameだけを見るので、この追加項目には影響されない。
    private static func structureCacheEntry(
        for book: MangaBook, usesFinderSortOrder: Bool
    ) -> BookPageListCache.Entry {
        let rootPath = book.sourceURL.path
        var hasNestedArchives = false
        let pages = book.pages.map { page -> BookPageListCache.Entry.Page in
            var idSuffix: String?
            var nestedPath: [String]?
            var entryPath: String?
            // 本そのものの書庫を起点とするページだけを復元可能な形で残す。フォルダの本
            // (locator.rootURLが章の書庫ファイルで、本のパスとは別)はここで弾かれ、
            // 結果としてhasNestedArchivesもfalseのまま=高速経路の対象外になる。
            // フォルダの更新日時は孫ファイルの変更を拾わず、指紋として信用できないため。
            if case .archive(let locator, let path) = page.source,
               locator.rootURL.path == rootPath,
               page.id.hasPrefix(rootPath) {
                idSuffix = String(page.id.dropFirst(rootPath.count))
                nestedPath = locator.nestedPath
                entryPath = path
                if locator.isNested { hasNestedArchives = true }
            }
            return BookPageListCache.Entry.Page(
                sortKey: page.sortKey,
                displayName: page.displayName,
                folderPath: page.location(inBookAt: book.sourceURL).folderPath,
                idSuffix: idSuffix,
                nestedPath: nestedPath,
                entryPath: entryPath,
                spreadPosition: page.epubSpreadPosition
            )
        }
        return BookPageListCache.Entry(
            pages: pages,
            schemaVersion: BookPageListCache.Entry.currentSchemaVersion,
            rootPath: rootPath,
            fingerprint: BookPageListCache.Entry.Fingerprint.current(for: book.sourceURL),
            hasNestedArchives: hasNestedArchives,
            usesFinderSortOrder: usesFinderSortOrder
        )
    }

    /// 構造キャッシュから本を組み立て直す。使えない条件が1つでもあればnilを返し、
    /// 呼び出し側は従来どおりの完全な読み込みへ落ちる。
    ///
    /// 適用するのは**入れ子の書庫を含む単一の書庫ファイルの本**だけ。平なcbz・PDF・EPUBは
    /// 元々列挙が速く、フォルダの本は指紋(更新日時)が孫ファイルの変更を拾わないため、
    /// いずれも「古い一覧のまま開いてしまう」危険に見合う利得が無い。
    private static func restoredFromStructureCache(
        url: URL, usesFinderSortOrder: Bool
    ) async -> MangaBook? {
        guard isArchiveFile(url.lastPathComponent),
              !isPDFFile(url.lastPathComponent), !isEpubFile(url.lastPathComponent)
        else { return nil }
        guard let entry = await BookPageListCache.shared.pageList(forBookID: url.path),
              entry.schemaVersion == BookPageListCache.Entry.currentSchemaVersion,
              entry.hasNestedArchives == true,
              // 「並び順をFinderに揃える」を切り替えた後は、保存済みの並びが今の設定と
              // 食い違う。並べ直さずそのまま使う経路なので、ここで捨てて読み直す。
              entry.usesFinderSortOrder == usesFinderSortOrder,
              entry.rootPath == url.path,
              !entry.pages.isEmpty
        else { return nil }
        // 保存時に指紋が取れていなかった場合(nil)は照合しようがないので使わない。
        guard let saved = entry.fingerprint,
              let current = BookPageListCache.Entry.Fingerprint.current(for: url),
              saved == current
        else { return nil }

        var pages: [PageRef] = []
        pages.reserveCapacity(entry.pages.count)
        for page in entry.pages {
            // 1ページでも欠けていたら、中途半端な本を作らずに丸ごとやり直す。
            guard let idSuffix = page.idSuffix, let entryPath = page.entryPath else { return nil }
            pages.append(PageRef(
                id: url.path + idSuffix,
                sortKey: page.sortKey,
                source: .archive(
                    locator: ArchiveLocator(rootURL: url, nestedPath: page.nestedPath ?? []),
                    entryPath: entryPath
                ),
                epubSpreadPosition: page.spreadPosition
            ))
        }
        // 並べ替えはしない。保存されているのは読み込み時に並べ替え済みの順そのもの。
        return MangaBook(
            id: url.path,
            title: url.deletingPathExtension().lastPathComponent,
            sourceURL: url,
            pages: pages
        )
    }

    private static func loadSync(
        from url: URL,
        limits: NestedArchiveResolver.Limits,
        usesFinderSortOrder: Bool,
        onProgress: (@Sendable (BookLoadProgress) -> Void)?
    ) throws -> MangaBook {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw BookLoaderError.notFound
        }
        let context = LoadContext(
            resolver: NestedArchiveResolver(limits: limits),
            progress: LoadProgressReporter(callback: onProgress),
            usesFinderSortOrder: usesFinderSortOrder
        )
        // 失敗しても中止されても、この読み込みが作った一時ファイルはここで消える。
        defer { context.resolver.purgeAll() }

        if isDirectory.boolValue {
            return try loadFolder(url, context: context)
        }
        if isPDFFile(url.lastPathComponent) {
            return try loadPDF(url)
        }
        if isEpubFile(url.lastPathComponent) {
            return try loadEpub(url)
        }
        // 画像ファイル1枚。書庫として開こうとすると必ず失敗するため、loadArchiveより先に分岐する。
        if isImageFile(url.lastPathComponent) {
            return loadSingleImage(url)
        }
        return try loadArchive(url, context: context)
    }

    /// 進み具合を数えて、間引きながら呼び出し側へ知らせる。
    ///
    /// 読み込みは1本のタスクの中で同期的に進むため、排他制御は要らない。
    /// 間引くのは、章ごとに書庫化された本では数百〜数千回この経路を通るため ―― 毎回
    /// メインアクターへホップさせると、進捗の表示そのものが読み込みを遅くする。
    private final class LoadProgressReporter {
        private let callback: (@Sendable (BookLoadProgress) -> Void)?
        private var state = BookLoadProgress()
        private var lastReportedAt: TimeInterval = 0
        /// 通知の最短間隔。人間が読める更新頻度の下限(10Hz)であればよく、
        /// これ以上細かく出しても意味が無い。
        private static let minimumInterval: TimeInterval = 0.1

        init(callback: (@Sendable (BookLoadProgress) -> Void)?) {
            self.callback = callback
        }

        /// 中に書庫が入っているのを見つけた(まだ開いていない)。
        func didDiscoverArchive() {
            state.discoveredArchiveCount += 1
            report()
        }

        /// 1つの書庫の中身を数え上げ終えた。
        func didFinishArchive(named name: String) {
            state.completedArchiveCount += 1
            state.currentArchiveName = name
            report()
        }

        private func report() {
            guard let callback else { return }
            let now = Date.timeIntervalSinceReferenceDate
            guard now - lastReportedAt >= Self.minimumInterval else { return }
            lastReportedAt = now
            callback(state)
        }
    }

    /// フォルダの場合は、直下だけでなくサブフォルダ(章分けなど)の画像も
    /// 再帰的にすべて集めて1冊のページ一覧にする。
    ///
    /// ユーザー要望: フォルダの中(サブフォルダを含むどの階層でも)に、画像ファイルだけでなく
    /// zip/cbz・rar/cbr・7z/cb7形式の書庫ファイルが直接置かれているケース(章ごとに書庫化されて
    /// いる、書庫の中に書庫が入っているなど)も、1冊の本として画像と同じページ一覧に統合して
    /// 開けるようにする。実際の統合処理はcollectPages(fromArchiveURL:...)に委譲する
    /// (書庫の中の書庫、そのまた中の書庫…という再帰にも対応する。maxNestedArchiveDepth参照)。
    private static func loadFolder(_ url: URL, context: LoadContext) throws -> MangaBook {
        let pages = try collectPages(inFolder: url, context: context)
        guard !pages.isEmpty else { throw BookLoaderError.noPages }

        let sortedPages = pages.sorted {
            comparePageOrder($0.sortKey, $1.sortKey, usesFinderOrder: context.usesFinderSortOrder)
                == .orderedAscending
        }
        return MangaBook(
            id: url.path,
            title: url.lastPathComponent,
            sourceURL: url,
            pages: sortedPages
        )
    }

    /// loadFolderの実処理。フォルダを再帰的に辿り、画像ファイルはそのままページ化し、
    /// 書庫ファイルが見つかった場合はcollectPages(at:...)でその中身も統合する。
    /// ここで見つかる書庫はディスク上に実在するファイルなので、そのままArchiveLocatorの
    /// ルートになる(取り出しは一切要らない)。
    private static func collectPages(inFolder url: URL, context: LoadContext) throws -> [PageRef] {
        var pages: [PageRef] = []
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return pages }

        for case let fileURL as URL in enumerator {
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDir else { continue }
            let name = fileURL.lastPathComponent
            if isImageFile(name) {
                pages.append(PageRef(id: fileURL.path, sortKey: fileURL.path, source: .file(fileURL)))
            } else if isArchiveFile(name) {
                try Task.checkCancellation()
                context.progress.didDiscoverArchive()
                let nestedPages = (try? collectPages(
                    at: ArchiveLocator(rootURL: fileURL),
                    archive: context.resolver.openRoot(fileURL),
                    idPrefix: fileURL.path,
                    sortKeyPrefix: fileURL.path,
                    context: context
                )) ?? []
                pages.append(contentsOf: nestedPages)
            }
        }
        return pages
    }

    /// ユーザー要望: アーカイブの直下(またはその中でさらに見つかった、入れ子になった
    /// アーカイブの中)に画像が無く、書庫ファイルしか無いケースでも開けるようにする。
    /// 書庫の直下に見つかった書庫ファイルは、その中身(画像・さらに入れ子の書庫)も
    /// 再帰的に統合して1冊の本のページ一覧に含める。
    private static func loadArchive(_ url: URL, context: LoadContext) throws -> MangaBook {
        context.progress.didDiscoverArchive()
        let pages = try collectPages(
            at: ArchiveLocator(rootURL: url), archive: context.resolver.openRoot(url),
            idPrefix: url.path, sortKeyPrefix: nil, context: context
        )
        guard !pages.isEmpty else { throw BookLoaderError.noPages }

        let sortedPages = pages.sorted {
            comparePageOrder($0.sortKey, $1.sortKey, usesFinderOrder: context.usesFinderSortOrder)
                == .orderedAscending
        }
        return MangaBook(
            id: url.path,
            title: url.deletingPathExtension().lastPathComponent,
            sourceURL: url,
            pages: sortedPages
        )
    }

    /// 書庫の中に書庫が何重に入れ子になっていても壊れたアーカイブなどで無限に再帰しないための
    /// 安全装置(通常のマンガでこの深さに達することは無い)。
    private static let maxNestedArchiveDepth = 8

    /// locatorが指す書庫の中身を列挙し、画像はそのままページ化、さらに入れ子になった書庫が
    /// 見つかった場合は再帰的に統合する。
    ///
    /// ■ ここでは展開結果を持ち帰らない
    /// 以前は、入れ子の書庫をreader.data(at:)で取り出して一時ファイルへ書き出し、そのURLを
    /// PageRef.sourceへ埋め込んでいた。つまり本を開いた時点で入れ子の書庫が**全部**ディスクに
    /// 展開され、本を閉じるまで残り続けていた。今はページの出所をArchiveLocator(実ファイル+
    /// 潜る道順)で表すため、ここで必要なのは「中に何が入っているかを数え上げること」だけで、
    /// 展開したものを保持しておく必要が無い。実際に読むときの展開はPageLoaderが持つ
    /// 自分のNestedArchiveResolverが行う。
    ///
    /// ■ それでも列挙のためには一度開く必要がある
    /// zipの中央ディレクトリはファイル末尾にあり、rar/7zも索引を読むには本体が要るため、
    /// 「中身を数え上げる」だけでも入れ子の書庫は一度取り出さなければならない。ただし
    /// 取り出したものはその場で捨てる(openTransient)ので、同時にディスクへ載るのは
    /// いま潜っている枝の祖先ぶんだけ ―― 通常の本(章ごとに書庫化されたもの)なら1本。
    ///
    /// idPrefix/sortKeyPrefixは、この階層のPageRef.id/sortKeyを組み立てるための接頭辞。
    /// sortKeyPrefixがnilの場合は最上位(本そのものの書庫)を表し、既存の挙動(sortKey =
    /// エントリのパスそのもの)をそのまま維持する。非nilの場合は入れ子の書庫を表し、
    /// "\(prefix)/\(path)"の形にすることで、その書庫ファイル自身が兄弟ファイルと並んでいた
    /// 位置に、中身がそのまま展開されたかのように自然順ソートされる。
    ///
    /// **この2つの組み立て式は変更してはならない。** sortKeyはページ単位のレイアウト設定
    /// (PageLayoutOverride)・ブックマーク・並べ替え(BookLayoutSettings.pageOrderOverride)の
    /// DB上のキーであり、idは画像キャッシュとページ一覧キャッシュのキーでもある。
    /// サイドパネルの本の中身ブラウザ(BookInternalBrowsing.matchKey)も同じ式で組み立てている。
    private static func collectPages(
        at locator: ArchiveLocator,
        archive: OpenArchive,
        idPrefix: String,
        sortKeyPrefix: String?,
        context: LoadContext
    ) throws -> [PageRef] {
        guard locator.depth <= maxNestedArchiveDepth else { return [] }
        try Task.checkCancellation()

        let allPaths = try archive.reader.listFilePaths()
        context.progress.didFinishArchive(named: locator.archiveFileName)

        var pages: [PageRef] = []
        for path in allPaths {
            if isImageFile(path) {
                pages.append(PageRef(
                    id: "\(idPrefix)#\(path)",
                    sortKey: sortKeyPrefix.map { "\($0)/\(path)" } ?? path,
                    source: .archive(locator: locator, entryPath: path)
                ))
            } else if isArchiveFile(path), locator.depth < maxNestedArchiveDepth {
                context.progress.didDiscoverArchive()
                // 壊れた入れ子・上限超え(NestedArchiveResolver.ResolveError.archiveTooLarge)は
                // その1本を飛ばすだけで、本全体の読み込みは続ける(従来と同じ扱い)。
                // ただしキャンセルだけは伝播させる ―― ここで握り潰すと、中止したはずの
                // 読み込みが最後まで走り切ってしまう。
                do {
                    let nested = locator.appending(path)
                    // 取り出した子書庫は、この`do`ブロックを抜けた時点で解放される
                    // (=rar/7zで作った一時ファイルもそこで消える)。列挙は深さ優先で一度ずつ
                    // 舐めるだけで同じ書庫へ二度と戻らないため、抱え続ける理由が無い
                    // (NestedArchiveResolver.openTransient参照)。ディスクに載るのは
                    // 「いま潜っている枝の祖先ぶん」だけになる。
                    let child = try context.resolver.openTransient(nested, parentReader: archive.reader)
                    pages.append(contentsOf: try collectPages(
                        at: nested,
                        archive: child,
                        idPrefix: "\(idPrefix)#\(path)",
                        sortKeyPrefix: sortKeyPrefix.map { "\($0)/\(path)" } ?? path,
                        context: context
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
            }
        }
        return pages
    }

    /// PDFファイルを1冊の本として読み込む。zip/7z/rarのような「中身を展開するアーカイブ」とは
    /// 違い、PDFは1ファイルの中に複数ページを直接持つ形式のため、専用の読み込み経路になる。
    /// ページ数の取得だけを行い(軽量)、実際に各ページを画像として描画する処理は
    /// PageLoader.renderPDFPageで、表示に必要になったタイミングで都度行う。
    ///
    /// 併せて、Document Catalogから読み方向/見開き強制のヒント(EPUBのpage-progression-direction/
    /// rendition:spreadに相当)を読み取り、sourceLayoutHintとして持たせる(詳細は
    /// PDFStructureResolver.resolveLayoutHintのコメント参照)。目次(アウトライン)の読み取りは
    /// ここでは行わない。EPUBの目次と同じく、ブックマークが1件も無い場合にのみ意味を持つ処理の
    /// ため、本を開くたびに毎回コストをかける必要が無く、ViewerViewModelが必要になったタイミングで
    /// 都度読み込む(autoImportPDFOutlineAsBookmarksIfNeeded参照)。
    private static func loadPDF(_ url: URL) throws -> MangaBook {
        guard let document = CGPDFDocument(url as CFURL) else { throw BookLoaderError.notFound }
        let pageCount = document.numberOfPages
        guard pageCount > 0 else { throw BookLoaderError.noPages }

        let pages = (0..<pageCount).map { index in
            PageRef(
                id: "\(url.path)#pdf#\(index)",
                sortKey: String(format: "%06d", index),
                source: .pdf(pdfURL: url, pageIndex: index)
            )
        }
        return MangaBook(
            id: url.path,
            title: url.deletingPathExtension().lastPathComponent,
            sourceURL: url,
            pages: pages,
            sourceLayoutHint: PDFStructureResolver.resolveLayoutHint(document: document)
        )
    }

    /// EPUBファイルを1冊の本として読み込む。EPUB自体はzipコンテナのため、内部の読み出しは
    /// ZipArchiveReaderをそのまま使う。ただしcbz(loadArchive)のように「zip内の画像を名前順に
    /// 並べる」のではなく、container.xml/package documentが定義する正しい読み順(spine)を
    /// 解決してからページを組み立てる必要があるため、専用の読み込み経路にしている
    /// (詳細はEpubStructureResolver.swift参照)。
    ///
    /// 対象は「固定レイアウトの画像ベースのコミックEPUB」のみで、文章主体のリフロー型EPUBの
    /// 本文レンダリングやDRM付きEPUBには対応していない。spineのどの項目からも画像を
    /// 1枚も特定できなかった場合は、通常のnoPagesとは区別してepubNotPictureBookを返し、
    /// ユーザーに理由が伝わるようにする。
    private static func loadEpub(_ url: URL) throws -> MangaBook {
        let reader = try ZipArchiveReader(url: url)
        let structure: EpubStructure
        do {
            structure = try EpubStructureResolver.resolve(reader: reader)
        } catch {
            throw BookLoaderError.epubNotPictureBook
        }
        guard !structure.pages.isEmpty else { throw BookLoaderError.epubNotPictureBook }

        let pages = structure.pages.enumerated().map { index, page in
            PageRef(
                id: "\(url.path)#\(page.entryPath)",
                sortKey: String(format: "%06d", index),
                source: .archive(locator: ArchiveLocator(rootURL: url), entryPath: page.entryPath),
                epubSpreadPosition: page.spreadPosition
            )
        }
        return MangaBook(
            id: url.path,
            title: url.deletingPathExtension().lastPathComponent,
            sourceURL: url,
            pages: pages,
            sourceLayoutHint: SourceLayoutHint(
                pageProgressionDirection: structure.pageProgressionDirection,
                forcedDisplayMode: structure.forcedDisplayMode
            )
        )
    }

    /// ユーザーが直接渡した画像ファイルを、1冊の「その場限りの本」として読み込む
    /// (ユーザー要望: 画像をウェルカム画面やDockアイコンへドロップして開けるようにする)。
    ///
    /// **同じフォルダにある他の画像へは意図的に展開しない。** 渡されたものがそのまま本になる、
    /// という一貫したルールにしてある。理由:
    /// - サンドボックス上、画像1枚のドロップで得られるアクセス権は**その1枚だけ**であり、
    ///   フォルダへ展開しようとすると一番手軽な操作のたびにフォルダのアクセス許可パネル
    ///   (FolderAccessStore)を挟むことになる
    /// - フォルダ全体を開きたい場合は、フォルダ自体をドロップする導線が既にある
    ///   (Info.plistのpublic.folder宣言。そちらの方が操作としても簡単)
    ///
    /// 出来上がる本は`origin: .imageFiles`、つまりDB・ディスクキャッシュ・履歴のいずれにも
    /// 何も残さない本になる(枚数によって記録される/されないが変わらないよう、1枚のときも同じ。
    /// 詳細はMangaBook.BookOriginのコメント参照)。
    ///
    /// そのためページ一覧のディスクキャッシュ(BookPageListCache)へも書き戻さず、
    /// load(from:cachesPageList:)と違ってcachesPageListに相当する引数を持たない。
    /// 複数枚の本のbookIDは開くたびに変わるランダム値なので、仮に書いても二度とヒットせず
    /// ゴミが増えるだけでもある(キャッシュのキーはSHA256(bookID)のみ)。
    static func load(imageFiles urls: [URL]) async throws -> MangaBook {
        let task = Task.detached(priority: .userInitiated) { () throws -> MangaBook in
            try loadImageFilesSync(urls)
        }
        return try await task.value
    }

    private static func loadImageFilesSync(_ urls: [URL]) throws -> MangaBook {
        // 重複除去はBookOpenRequestが済ませているが、このメソッドは公開APIなので単体でも
        // 破綻しないよう自前でも行う(重複したままだとPageRef.idが衝突する)。
        // 実在確認はここで行う。メインスレッド外で走るこのメソッドが担うべき仕事で、
        // 未接続のボリューム上のファイルが混ざっていてもUIを止めずに済む。
        var seenPaths = Set<String>()
        let existingImageURLs = urls.filter { url in
            guard isImageFile(url.lastPathComponent), seenPaths.insert(url.path).inserted else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        guard let firstURL = existingImageURLs.first else { throw BookLoaderError.notFound }
        // 1枚だけ(重複や存在しないファイルを除いた結果を含む)ならloadSingleImageへ。
        // どちらもその場限りの本だが、1枚なら実在パスをidに使えるほうが、ウインドウタイトルの
        // 拡張子表示や「Finderで表示」が自然に動く。
        guard existingImageURLs.count > 1 else { return loadSingleImage(firstURL) }

        let sortedURLs = naturalOrderSortedByPath(existingImageURLs)
        let pages = sortedURLs.map { PageRef(id: $0.path, sortKey: $0.path, source: .file($0)) }
        return MangaBook(
            // 複数枚をまとめた1冊に対応する実在パスは存在しないため、毎回新しいUUIDにする。
            // 安定した内容ハッシュ等にしてはいけない理由(ページ一覧・サムネイルのキャッシュ衝突)、
            // および空文字列やドットを含めてはいけない理由は、MangaBook.BookOriginのコメント参照。
            id: "qooviewer-image-files:\(UUID().uuidString)",
            // 先頭ページのファイル名。枚数を添えた表示名の組み立ては、アプリ内の表示言語設定を
            // 参照できる表示層が行う(MangaBook.displayName(locale:)参照)。
            title: sortedURLs[0].deletingPathExtension().lastPathComponent,
            // 「Finderで表示」やサイドパネルのフォルダアンカーが自然に動くよう、先頭ページの
            // URLを入れておく。これが実在ファイルを指すため、本を開くときのiノードによる移動追従
            // (AppState.open内のreconcileBookIDIfMoved)を通すと**既存のDB行のbookIDが破壊される**。
            // 同メソッドのskipsPersistenceガードが唯一の防御になっている点に注意。
            sourceURL: sortedURLs[0],
            pages: pages,
            origin: .imageFiles
        )
    }

    /// 画像ファイル1枚を、1ページのその場限りの本として読み込む(load(imageFiles:)のコメント参照)。
    /// idには実在パスをそのまま使えるが、**それでもDBには一切書かない**(origin: .imageFiles)。
    /// 存在確認はloadSyncが済ませているためthrowしない。
    private static func loadSingleImage(_ url: URL) -> MangaBook {
        MangaBook(
            id: url.path,
            // 拡張子を落とすのはloadPDF/loadEpubと同じ流儀。
            title: url.deletingPathExtension().lastPathComponent,
            sourceURL: url,
            // sortKeyにフルパスを使うのはloadFolderと同じ(collectPages(inFolder:)参照)。
            pages: [PageRef(id: url.path, sortKey: url.path, source: .file(url))],
            origin: .imageFiles
        )
    }
}

enum BookLoaderError: LocalizedError {
    case notFound
    case noPages
    /// EPUBとしては開けたが、画像ベースの固定レイアウトコミックとしてページを1枚も
    /// 特定できなかった場合(リフロー型の小説EPUB、DRM付きEPUBなど)。
    case epubNotPictureBook

    // Note: ここでは preferences.effectiveLocale(アプリ内の表示言語設定)ではなく
    // デフォルトのLocale解決(システムのロケールに従う)を使っている。BookLoaderは
    // AppPreferencesを持たないstatic enumのため、呼び出し元(AppState)まで
    // Localeを引き回す必要があり、エラーメッセージという頻度の低い経路のために
    // そこまでの変更は見送った。システム言語とアプリ内の表示言語設定を別々にしている
    // 場合、エラーメッセージだけシステム言語で表示されることがある。
    var errorDescription: String? {
        switch self {
        case .notFound:
            return String(localized: "The file or folder could not be found.")
        case .noPages:
            return String(
                localized: "No supported images were found. (Supports image folders, zip/cbz, rar/cbr, 7z/cb7, PDF, and EPUB.)"
            )
        case .epubNotPictureBook:
            return String(
                localized: "This EPUB doesn't appear to be an image-based comic (fixed-layout) book, so it couldn't be opened. Text-based reflowable EPUBs and DRM-protected EPUBs are not supported."
            )
        }
    }
}

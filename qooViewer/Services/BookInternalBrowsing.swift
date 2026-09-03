import Foundation

/// サイドパネル下段(本の中身ブラウザ)が、今どの階層を見ているかを表す。
/// nonisolated: ArchiveReading.swift冒頭のコメントと同じ理由(Swift 6.2既定のMainActor
/// 自動分離の対象外にする必要がある)。
nonisolated enum BookEntryLevel {
    /// 実在するフォルダ(本がフォルダの場合の各階層)。
    case folder(URL)
    /// 開いた状態のアーカイブの中の、ある仮想パス階層。archiveは.archiveへ踏み込む
    /// たびに新しく開き直す。prefixは""=ルート、"chapter1/nested/"のように末尾"/"付き。
    ///
    /// ArchiveReadingではなくOpenArchiveを持つのは、入れ子の書庫が一時ファイル経路の場合、
    /// その裏付けである一時ファイルの寿命がこのオブジェクトに紐づいているため
    /// (NestedArchiveResolver.OpenArchive参照)。readerだけを持つと、解決役のLRUから
    /// 追い出された瞬間にファイルが消え、戻る/進むで戻ってきた階層が読めなくなる。
    /// allPathsはreader.listFilePaths()の結果をキャッシュしたもの(階層を移動するたびに
    /// 再取得しなくて済むように、この階層に踏み込んだ時点で1度だけ取得しておく)。
    ///
    /// matchKeyPrefixは、このreaderが「本のルートから見てどこにあたるか」を表す接頭辞
    /// (BookLoader.collectPages(fromArchiveURL:...)のsortKeyPrefixと全く同じ考え方・
    /// 同じ組み立て方で、BookContentsBrowserStateが管理する)。本自身のルート書庫を
    /// 直接開いている間はnil。ネストした書庫へ踏み込むたびに、そのエントリパスを
    /// 積み上げていく("B.zip" → "B.zip/nested.zip" のように)。この接頭辞が
    /// BookLoaderのsortKeyの組み立てと食い違うと、Entry.matchKeyがPageRef.sortKeyと
    /// 一致しなくなり、ダブルクリックしても「本に含まれるページ」として認識されず
    /// 誤って「新しい本として開く」フォールバックに落ちてしまうため、両者は必ず
    /// 同じロジックを保つ必要がある。
    case archive(archive: OpenArchive, allPaths: [String], prefix: String, matchKeyPrefix: String?)
    /// ユーザーが直接渡した画像ファイル(MangaBook.BookOrigin.imageFiles)そのものの一覧。
    /// この本には辿るべき「中身の階層」が存在しないため、常にこの1階層だけで完結し、
    /// 踏み込む(navigate)ことも1階層上がることもない。
    /// 並びは**本のページ順のまま**保持する(BookInternalBrowsing.entries参照)。
    case imageFileList([URL])
}

/// 本の内部(フォルダ本ならその配下、アーカイブ本ならその中身、そこから踏み込んだネスト
/// アーカイブの中身)の一覧を作るヘルパー。ツリー展開はせず、「今いる階層の直下1段分」だけを
/// 返す(BookContentsBrowserStateがナビゲーションのスタックを管理する)。
nonisolated enum BookInternalBrowsing {
    /// 行1件分。フォルダ・ネストしたアーカイブファイルはisContainer=trueで踏み込める。
    /// 画像ファイルはisImage=trueでダブルクリック時にmatchKeyをbook.pagesのsortKeyと
    /// 突き合わせてジャンプを試みる。
    struct Entry: Identifiable, Hashable {
        let id: String
        let displayName: String
        let isContainer: Bool
        let isImage: Bool
        /// PageRef.sortKeyとの突き合わせ用(フォルダ本の画像なら絶対パス、アーカイブ本の
        /// 画像ならアーカイブ内相対パス。BookLoader.swiftのsortKeyの作り方と揃えてある)。
        let matchKey: String
        /// isContainer=trueのときだけ非nil。踏み込む(navigate)ときにどう開けばよいかを表す。
        let navigateTarget: NavigateTarget?

        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    enum NavigateTarget {
        /// 実在するフォルダの中へ。
        case realFolder(URL)
        /// 同じreaderのまま、仮想パスをさらに深くする(I/O無し)。
        case archiveVirtualFolder(prefix: String)
        /// フォルダ本の中で見つかった、ディスク上に実在するネストしたアーカイブファイル
        /// (makeArchiveReader(for:)にそのまま渡せる。一時ファイル書き出し不要)。
        case archiveFileOnDisk(URL)
        /// 現在開いているreaderの中で見つかった、ネストしたアーカイブエントリ
        /// (reader.data(at:)で取り出してから新しいreaderとして開き直す必要がある)。
        case nestedArchiveEntry(entryPath: String)
    }

    /// levelの直下1段分の一覧を返す。フォルダ/ネストアーカイブは常に含み、ファイルは
    /// 画像またはアーカイブ形式のみに絞る(下段の目的上、それ以外は一覧のノイズになるため。
    /// PDF/EPUBがフォルダ/アーカイブ本の中にさらに入れ子で存在するケースは対象外とする —
    /// このブラウザの目的は「漫画のページ・入れ子になった漫画アーカイブを辿ること」で
    /// あり、PDF/EPUB用の別の閲覧モードを新設するほどの需要が無いための意図的な割り切り)。
    /// - Parameter pageOrder: 今開いている本の実際のページ順(sortKey → 読書順の位置)。
    ///   一覧の並びはこれに従う ―― BookContentsBrowserState.pageOrder参照。
    static func entries(
        at level: BookEntryLevel, pageOrder: [String: Int]
    ) throws -> [Entry] {
        switch level {
        case .folder(let url):
            return try folderEntries(in: url, pageOrder: pageOrder)
        case .archive(_, let allPaths, let prefix, let matchKeyPrefix):
            return archiveEntries(
                allPaths: allPaths, prefix: prefix, matchKeyPrefix: matchKeyPrefix, pageOrder: pageOrder
            )
        case .imageFileList(let urls):
            return imageFileEntries(urls)
        }
    }

    /// 直接渡された画像ファイルの一覧。
    ///
    /// **渡された順(=本のページ順)のまま返す。** この階層に並ぶのは
    /// 「今開いている本のページそのもの」であり、ビューアに表示されている順と一覧の順が
    /// 食い違うほうが分かりにくいため。フォルダをまたいで選択された場合、ファイル名だけで
    /// 並べ直すとページ順と一致しなくなる(本のページ順はフルパスの自然順。
    /// BookOpenRequest.init(openingCandidates:)参照)。
    ///
    /// matchKeyはフルパス。BookLoaderが画像の本のPageRefへ入れるsortKeyと同じもので、
    /// これが一致することでクリック時にそのページへジャンプできる
    /// (BookContentsBrowserState.resolveImageClick参照)。
    private static func imageFileEntries(_ urls: [URL]) -> [Entry] {
        urls.map { url in
            Entry(
                id: url.path, displayName: url.lastPathComponent, isContainer: false, isImage: true,
                matchKey: url.path, navigateTarget: nil
            )
        }
    }

    /// 一覧を並べ替える。
    ///
    /// **並びの基準は名前ではなく、今開いている本のページ順そのもの**(pageOrder)。
    /// この一覧は「今開いている本の中身」であり、ビューアに表示されている順と食い違うと
    /// 分かりにくいため。名前で並べ直していた頃は、環境設定「並び順をFinderに揃える」や
    /// ユーザーの並べ替え(pageOrderOverride)を反映できず、ビューアと食い違いえた。
    /// 本のページに含まれない項目(除外ページ、本の対象外の画像、ページを1枚も含まない
    /// フォルダ)は順位を持たないので、末尾へ名前順でまとめる。
    ///
    /// 環境設定「一般」タブの「フォルダをまとめて上に」(SidePanelSortOrder)は**ここには
    /// 効かせない**(上段のフォルダブラウザ専用)。以前は下段でもコンテナを上へまとめていたが、
    /// この一覧の役目はビューアの表示ページを追従して「本の中のどこにいるか」を示すことで、
    /// 行の並びがページ順と食い違うと追従の意味が薄れる ―― ルートに表紙画像、章はフォルダ、
    /// という本で、1ページ目の表紙が章フォルダの列の下へ沈んでいた(監査で指摘)。
    /// コンテナは「中に含まれる最初のページ」の位置に、画像と混ざって並ぶ。
    private static func sortedEntries(_ entries: [Entry], pageOrder: [String: Int]) -> [Entry] {
        let ranks = ranksByEntryID(entries, pageOrder: pageOrder)
        func isBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
            switch (ranks[lhs.id], ranks[rhs.id]) {
            case let (l?, r?): return l != r ? l < r : compareName(lhs, rhs)
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return compareName(lhs, rhs)
            }
        }
        func compareName(_ lhs: Entry, _ rhs: Entry) -> Bool {
            compareCanonicalPageOrder(lhs.displayName, rhs.displayName) == .orderedAscending
        }
        return entries.sorted(by: isBefore)
    }

    /// 各項目の「本の中での位置」。画像はそのページの位置、コンテナ(フォルダ・入れ子の書庫)は
    /// **中に含まれるページのうち最も早いものの位置**。
    ///
    /// コンテナのmatchKeyは、その中のページのsortKeyの接頭辞になっている
    /// (どちらもBookLoaderと同じ組み立て方。archiveEntriesのmatchKey(for:)のコメント参照)。
    /// ページを読書順に1回だけ走査し、まだ順位が決まっていないコンテナに最初に当たったところで
    /// 確定させる(最小値になる)。
    private static func ranksByEntryID(_ entries: [Entry], pageOrder: [String: Int]) -> [String: Int] {
        var ranks: [String: Int] = [:]
        var containers: [(id: String, prefix: String)] = []
        for entry in entries {
            if entry.isContainer {
                containers.append((entry.id, entry.matchKey.hasSuffix("/") ? entry.matchKey : entry.matchKey + "/"))
            } else if let index = pageOrder[entry.matchKey] {
                ranks[entry.id] = index
            }
        }
        guard !containers.isEmpty else { return ranks }
        for (key, _) in pageOrder.sorted(by: { $0.value < $1.value }) {
            guard !containers.isEmpty else { break }
            if let hit = containers.firstIndex(where: { key.hasPrefix($0.prefix) }) {
                ranks[containers[hit].id] = pageOrder[key]
                containers.remove(at: hit)
            }
        }
        return ranks
    }

    private static func folderEntries(
        in url: URL, pageOrder: [String: Int]
    ) throws -> [Entry] {
        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let entries: [Entry] = children.compactMap { child in
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let name = child.lastPathComponent
            if isDir {
                return Entry(
                    id: child.path, displayName: name, isContainer: true, isImage: false,
                    matchKey: child.path, navigateTarget: .realFolder(child)
                )
            }
            if isImageFile(name) {
                return Entry(
                    id: child.path, displayName: name, isContainer: false, isImage: true,
                    matchKey: child.path, navigateTarget: nil
                )
            }
            if isArchiveFile(name) {
                return Entry(
                    id: child.path, displayName: name, isContainer: true, isImage: false,
                    matchKey: child.path, navigateTarget: .archiveFileOnDisk(child)
                )
            }
            return nil
        }
        return sortedEntries(entries, pageOrder: pageOrder)
    }

    /// フラットなパス一覧(ZIPFoundation/Unrar/SevenZipのlistFilePaths()はディレクトリ
    /// エントリを持たず、ファイルの完全パスだけを返す)から、prefix直下の1階層分だけを
    /// 切り出す。prefix以降の残りを最初の"/"で分割し、"/"が見つかればそこまでがフォルダ名、
    /// 見つからなければそれ自体がこの階層のファイル。
    private static func archiveEntries(
        allPaths: [String], prefix: String, matchKeyPrefix: String?, pageOrder: [String: Int]
    ) -> [Entry] {
        var folderNames = Set<String>()
        var fileEntries: [Entry] = []

        // BookLoader.collectPages(fromArchiveURL:...)と全く同じ組み立て方
        // (matchKeyPrefix.map { "\($0)/\(path)" } ?? path)。仮想フォルダのprefixは
        // UI上の階層分けにしか使わず、matchKeyは常にreader内の完全なパス(path)から
        // 組み立てる(BookLoader側も「今どの仮想フォルダにいるか」という概念を持たず、
        // reader全体を1回でフラットに処理しているため)。
        func matchKey(for path: String) -> String {
            matchKeyPrefix.map { "\($0)/\(path)" } ?? path
        }

        for path in allPaths {
            guard path.hasPrefix(prefix) else { continue }
            let remainder = String(path.dropFirst(prefix.count))
            guard !remainder.isEmpty else { continue }

            if let slashIndex = remainder.firstIndex(of: "/") {
                let folderName = String(remainder[remainder.startIndex..<slashIndex])
                guard !folderName.isEmpty else { continue }
                folderNames.insert(folderName)
            } else {
                let name = remainder
                if isImageFile(name) {
                    fileEntries.append(Entry(
                        id: path, displayName: name, isContainer: false, isImage: true,
                        matchKey: matchKey(for: path), navigateTarget: nil
                    ))
                } else if isArchiveFile(name) {
                    fileEntries.append(Entry(
                        id: path, displayName: name, isContainer: true, isImage: false,
                        matchKey: matchKey(for: path), navigateTarget: .nestedArchiveEntry(entryPath: path)
                    ))
                }
            }
        }

        let folderEntries = folderNames.map { name -> Entry in
            let childPrefix = prefix + name + "/"
            return Entry(
                id: childPrefix, displayName: name, isContainer: true, isImage: false,
                matchKey: matchKey(for: childPrefix), navigateTarget: .archiveVirtualFolder(prefix: childPrefix)
            )
        }
        return sortedEntries(folderEntries + fileEntries, pageOrder: pageOrder)
    }
}

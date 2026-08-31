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
    /// ArchiveReadingではなくOpenArchiveを持つのは、入れ子の書庫がrar/7zの場合、その
    /// 裏付けである一時ファイルの寿命がこのオブジェクトに紐づいているため
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
    static func entries(at level: BookEntryLevel, sortOrder: SidePanelSortOrder) throws -> [Entry] {
        switch level {
        case .folder(let url):
            return try folderEntries(in: url, sortOrder: sortOrder)
        case .archive(_, let allPaths, let prefix, let matchKeyPrefix):
            return archiveEntries(allPaths: allPaths, prefix: prefix, matchKeyPrefix: matchKeyPrefix, sortOrder: sortOrder)
        case .imageFileList(let urls):
            return imageFileEntries(urls)
        }
    }

    /// 直接渡された画像ファイルの一覧。
    ///
    /// **sortOrderを適用せず、渡された順(=本のページ順)のまま返す。** この階層に並ぶのは
    /// 「今開いている本のページそのもの」であり、ビューアに表示されている順と一覧の順が
    /// 食い違うほうが分かりにくいため。フォルダをまたいで選択された場合、ファイル名だけで
    /// 並べ直すとページ順と一致しなくなる(本のページ順はフルパスの自然順。
    /// BookOpenRequest.init(openingCandidates:)参照)。フォルダが1件も混ざらないので
    /// foldersFirstとmixedByNameの区別も元々意味を持たない。
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

    /// 一覧を環境設定「一般」タブの並び順設定に従って並べ替える。「フォルダ」扱いは
    /// isContainer(実フォルダ・ネストした書庫ファイルのどちらも踏み込めるため上位に
    /// まとめる)、DirectoryBrowser.sortedEntries(_:order:)と同じ考え方。
    private static func sortedEntries(_ entries: [Entry], order: SidePanelSortOrder) -> [Entry] {
        switch order {
        case .mixedByName:
            return entries.sorted {
                compareCanonicalPageOrder($0.displayName, $1.displayName) == .orderedAscending
            }
        case .foldersFirst:
            return entries.sorted { lhs, rhs in
                if lhs.isContainer != rhs.isContainer { return lhs.isContainer }
                return compareCanonicalPageOrder(lhs.displayName, rhs.displayName) == .orderedAscending
            }
        }
    }

    private static func folderEntries(in url: URL, sortOrder: SidePanelSortOrder) throws -> [Entry] {
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
        return sortedEntries(entries, order: sortOrder)
    }

    /// フラットなパス一覧(ZIPFoundation/Unrar/SevenZipのlistFilePaths()はディレクトリ
    /// エントリを持たず、ファイルの完全パスだけを返す)から、prefix直下の1階層分だけを
    /// 切り出す。prefix以降の残りを最初の"/"で分割し、"/"が見つかればそこまでがフォルダ名、
    /// 見つからなければそれ自体がこの階層のファイル。
    private static func archiveEntries(
        allPaths: [String], prefix: String, matchKeyPrefix: String?, sortOrder: SidePanelSortOrder
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
        return sortedEntries(folderEntries + fileEntries, order: sortOrder)
    }
}

import Foundation

/// サイドパネル上段(フォルダブラウザ)が、ファイルシステム上の任意のフォルダ/ボリューム
/// 一覧を取得するためのヘルパー。SiblingFinder.swiftと同じ形の`nonisolated enum`
/// (Swift 6.2既定のMainActor自動分離の対象外にする必要があるため。ArchiveReading.swift
/// 冒頭のコメント参照)。
///
/// SiblingFinderと違い、ここでの一覧は「本として開けるかどうか」ではなく「ナビゲーション先と
/// して意味があるかどうか」で絞り込む: サブフォルダはそれ自体が本として開けるかに関わらず
/// 常に含める(でないと本を含まない中間フォルダを経由して奥のフォルダへたどり着けなくなる)。
/// ファイルは開ける形式(アーカイブ/PDF/EPUB)のみに絞る。
nonisolated enum DirectoryBrowser {
    /// 一覧の1行。表示に使う値(displayName)も並べ替えに使う値(fileSize/typeDescription/
    /// creationDate/modificationDate)も、一覧を読み込む時点(メインスレッド外)ですべて
    /// 確定させておき、以後は一切ディスクを触らない。
    ///
    /// 以前はdisplayNameだけが`url.resourceValues(...)`をその都度呼ぶ計算プロパティだった。
    /// 行の描画と絞り込み(SidePanelView.filteredFolderEntries)は**メインスレッド**で全件ぶん
    /// これを呼ぶため、数百件のフォルダでは絞り込みの1文字ごとに全件のディスクI/Oが走って
    /// いた。並べ替え対応で他の属性もまとめて必要になったのを機に、格納プロパティへ移した。
    struct Entry: Identifiable, Hashable {
        let url: URL
        let isDirectory: Bool
        /// 一覧に表示する名前(DirectoryBrowser.displayName(for:)と同じ考え方)。
        let displayName: String
        /// ファイルサイズ(バイト)。フォルダは常にnil ― Finderと同じく中身の再帰計算は
        /// 行わない(数千ファイル規模のフォルダを開くたびに走らせるには重すぎ、ネットワーク
        /// ボリュームやアクセス権の無い場所では失敗もする)。読み取れなかったファイルもnil。
        let fileSize: Int64?
        /// Finderの「種類」に相当するローカライズ済みの説明。並べ替えの比較キーとしてのみ使い、
        /// 画面には出さない ― そのため、この文字列がアプリ内の表示言語設定ではなくOSの言語で
        /// 解決されることは問題にならない(BookLoader.swiftのerrorDescriptionと同じ整理)。
        let typeDescription: String?
        let creationDate: Date?
        let modificationDate: Date?
        /// **フォルダの行だけ**: 直下に画像ファイルが1つでもあるか(= このフォルダ自体が
        /// 1冊の本か)。ファイルの行では常にfalse。
        ///
        /// 「開く」系のコンテキストメニューを出すかどうか(中間フォルダには開くべき本が
        /// 無いので出さない)と、ダブルクリックが「本として開く」「移動する」のどちらに
        /// なるかの判定に使う。
        ///
        /// **他の属性と同じく、一覧を読み込む時点で確定させておく**(この型の冒頭のコメント
        /// 参照)。SwiftUIの`.contextMenu`の中身は右クリックの瞬間ではなく行の本体評価の
        /// 一部として組み立てられるため、ここを計算プロパティにすると、絞り込みの1文字ごとに
        /// 表示中の全フォルダぶんのディスクI/Oが走ることになる ―― displayNameを格納
        /// プロパティへ移したのとまったく同じ問題。
        let containsImageFile: Bool

        var id: String { url.path }
    }

    /// 一覧を1件読むたびに取り出すリソース値。contentsOfDirectory(includingPropertiesForKeys:)へ
    /// 渡してまとめて先読みさせることで、この後のresourceValues(forKeys:)がディスクを
    /// 触り直さずに済む。
    ///
    /// サイズは.totalFileSize(表示用の合計サイズ)を優先し、取れない場合に.fileSize
    /// (データフォークのみ)へ落とす。Finderの「サイズ」表示に近いのは前者。
    /// 種類(.localizedTypeDescription)だけはここに含めない ― 1件ごとにLaunchServicesへ
    /// 問い合わせる比較的重い値である一方、この一覧では拡張子ごとに同じ答えになるため、
    /// typeDescription(for:isDirectory:cache:)側で拡張子単位にキャッシュして取得する。
    private static let entryResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .localizedNameKey,
        .totalFileSizeKey,
        .fileSizeKey,
        .creationDateKey,
        .contentModificationDateKey,
    ]

    /// FolderAccessStore.Entry.displayNameと同じ考え方(ボリュームのルートフォルダは
    /// lastPathComponentが"/"や空文字になってしまうため、可能ならFinderと同じ
    /// .localizedNameKeyを優先する)。Entry.displayNameだけでなく、現在地表示
    /// (SidePanelView、Entryを経由しない生のURL)からも使うためstatic funcとして公開する。
    static func displayName(for url: URL) -> String {
        if let localizedName = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName,
           !localizedName.isEmpty {
            return localizedName
        }
        return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    /// directory直下の項目一覧を返す。フォルダは常に含み、ファイルは開ける形式のみに絞る。
    /// 並び順はsort(パネル上部の並べ替えメニュー+環境設定「一般」タブのグループ分け)に
    /// 従う(sortedEntries(_:sort:)参照)。
    ///
    /// アクセス権が無い場合は、FileManagerが投げるエラーをそのままthrowする(SiblingFinderの
    /// ようにtry?でもみ消さない)。空フォルダと権限エラーを区別し、呼び出し側で「その場で
    /// アクセスを許可」の案内を出し分けられるようにするため。
    static func entries(in directory: URL, sort: FolderBrowserSort) throws -> [Entry] {
        try listing(in: directory, sort: sort).entries
    }

    /// `entries(in:sort:)`に「直下に画像ファイルがあったか」を添えたもの。
    struct Listing {
        let entries: [Entry]
        /// **一覧には出していないが**、このフォルダの直下に画像ファイルがあるかどうか。
        ///
        /// この一覧は画像を行として出さない(makeEntry。一覧の目的は「本を探すこと」で、画像を
        /// 並べるとノイズになる)。そのぶん、画像だけが入っているフォルダは空に見え、画像と
        /// サブフォルダが同居しているフォルダは画像が無いように見える。どちらもそのフォルダ
        /// 自体が1冊の本なので、呼び出し側はこの値を見て「このフォルダの画像を開く」導線を
        /// 出せる(SidePanelBrowserState.currentDirectoryHasImages参照)。
        ///
        /// 一覧を組み立てる際の列挙をそのまま使って調べるので、**I/Oは増えない**。
        let containsImageFile: Bool
    }

    static func listing(in directory: URL, sort: FolderBrowserSort) throws -> Listing {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(entryResourceKeys),
            options: [.skipsHiddenFiles]
        )
        var kindCache: [String: String] = [:]
        let entries = children.compactMap { makeEntry(for: $0, kindCache: &kindCache) }
        let containsImageFile = children.contains { isImageFile($0.lastPathComponent) }
        return Listing(entries: sortedEntries(entries, sort: sort), containsImageFile: containsImageFile)
    }

    static func listingAsync(in directory: URL, sort: FolderBrowserSort) async throws -> Listing {
        try await Task.detached(priority: .utility) {
            try listing(in: directory, sort: sort)
        }.value
    }

    /// 1件ぶんのEntryを組み立てる。開けない形式のファイルはここでnilを返して一覧から落とす
    /// (フォルダは中身に関わらず常に残す。この型の冒頭のコメント参照)。
    private static func makeEntry(for url: URL, kindCache: inout [String: String]) -> Entry? {
        let values = try? url.resourceValues(forKeys: entryResourceKeys)
        let isDirectory = values?.isDirectory ?? false
        if !isDirectory {
            let name = url.lastPathComponent
            guard isArchiveFile(name) || isPDFFile(name) || isEpubFile(name) else { return nil }
        }
        let displayName: String = {
            if let localizedName = values?.localizedName, !localizedName.isEmpty { return localizedName }
            return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }()
        let fileSize: Int64? = isDirectory ? nil : (values?.totalFileSize ?? values?.fileSize).map(Int64.init)
        return Entry(
            url: url,
            isDirectory: isDirectory,
            displayName: displayName,
            fileSize: fileSize,
            typeDescription: typeDescription(for: url, isDirectory: isDirectory, cache: &kindCache),
            creationDate: values?.creationDate,
            modificationDate: values?.contentModificationDate,
            // ファイルは中身を持たないので調べない。フォルダは1件につき1回の列挙が増えるが、
            // 画像が見つかった時点で打ち切るため、画像フォルダなら最初の数件で終わる
            // (directlyContainsImageFileのコメント参照)。この関数はもともと
            // listingAsync/entriesAsync/mountedVolumeEntriesAsync経由でメインスレッド外から
            // 呼ばれる。
            containsImageFile: isDirectory && directlyContainsImageFile(url)
        )
    }

    /// Finderの「種類」に相当する説明を、拡張子ごとに1回だけ問い合わせて使い回す。
    /// 1つの一覧に出てくる拡張子は数種類しかない(フォルダ/zip/cbz/rar/cbr/7z/cb7/pdf/epub)
    /// のに対し、.localizedTypeDescriptionはファイル1件ごとにLaunchServicesへの問い合わせに
    /// なるため、数千件のフォルダではキャッシュの有無が体感差になる。
    ///
    /// フォルダも拡張子を見てキャッシュを分けている。`.app`のようなパッケージは
    /// contentsOfDirectoryからはフォルダとして返ってくるが、種類は「アプリケーション」など
    /// 素のフォルダとは別物になるため、まとめてしまうと誤った種類で並べることになる。
    private static func typeDescription(
        for url: URL, isDirectory: Bool, cache: inout [String: String]
    ) -> String? {
        let cacheKey = (isDirectory ? "d:" : "f:") + url.pathExtension.lowercased()
        if let cached = cache[cacheKey] { return cached }
        guard let description = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey])
            .localizedTypeDescription else { return nil }
        cache[cacheKey] = description
        return description
    }

    /// フォルダ・ファイルの一覧を、並べ替え設定に従って並べ替える。nonisolated enum
    /// (MainActor隔離のAppPreferencesを直接読めない)のため、呼び出し側が現在の設定値を
    /// 引数として渡す(AppPreferences.folderBrowserSortのコメント参照)。
    ///
    /// 並べ替えメニューで基準・向きを変えただけのときは、ディスクを読み直さずこの関数だけを
    /// 呼び直す(SidePanelBrowserState.applySortSettings参照)。Entryが並べ替えに必要な値を
    /// すべて確定値として持っているため、ここではファイルアクセスが一切発生しない。
    static func sortedEntries(_ entries: [Entry], sort: FolderBrowserSort) -> [Entry] {
        entries.sorted { lhs, rhs in
            // グループ分け(フォルダを先に)は基準・向きより先に効かせる。降順にしても
            // フォルダは上のまま ― Finderの「フォルダを常に上部に表示」と同じ挙動。
            if sort.grouping == .foldersFirst, lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            switch compare(lhs, rhs, key: sort.key) {
            case .orderedAscending: return sort.direction == .ascending
            case .orderedDescending: return sort.direction == .descending
            // compareは必ず名前・パスまで見て決着させるため、ここへは来ない(同じ一覧に
            // 同じパスの項目は現れない)。来た場合も並びが揺れないようfalseで固定する。
            case .orderedSame: return false
            }
        }
    }

    /// 2件の前後関係を、選ばれている基準で決める。値を持たない項目(フォルダのサイズなど)や
    /// 同じ値だった項目は名前で、それも同じなら最後はパスで決着させる。
    ///
    /// 常に全順序(どの2件を比べても必ず前後が決まる)になるようにしてあるため、降順は昇順の
    /// 完全な逆順になり、同じフォルダを開き直しても並びが揺れない。
    private static func compare(_ lhs: Entry, _ rhs: Entry, key: FolderBrowserSortKey) -> ComparisonResult {
        let primary: ComparisonResult
        switch key {
        case .name:
            // 名前そのものが下のタイブレークなので、ここでは何もしない。
            primary = .orderedSame
        case .size:
            primary = compareOptional(lhs.fileSize, rhs.fileSize)
        case .kind:
            primary = compareOptional(lhs.typeDescription, rhs.typeDescription) { $0.localizedStandardCompare($1) }
        case .creationDate:
            primary = compareOptional(lhs.creationDate, rhs.creationDate)
        case .modificationDate:
            primary = compareOptional(lhs.modificationDate, rhs.modificationDate)
        }
        if primary != .orderedSame { return primary }
        // Finderと同じ並び(localizedStandardCompare: 数字は数値として比べ、大文字小文字・
        // 全角半角は区別せず、ロケールの照合順序に従う)。お気に入り・ブックマーク・
        // メタデータ編集など、このアプリの他の「人に見せる一覧」もこの比較で揃えてある
        // (FavoritesStore.sortedBooks等)。
        //
        // この機能を入れる前は`compare(_:options: .numeric)`だった(ロケールを見ず、
        // 大文字始まりの名前がすべて小文字始まりより先に来る)。下段(本の中身ブラウザ、
        // BookInternalBrowsing)が今も.numericなのは意図的で、あちらの並びは本のページ順
        // (BookLoaderのsortKey、同じく.numeric)と一致していなければならないため。
        let byName = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if byName != .orderedSame { return byName }
        // 表示名が同じことは起こり得る(拡張子を隠す設定、別ボリュームで同じ名前など)。
        // 最後にパスで決着させ、全順序を保証する。
        return lhs.url.path.compare(rhs.url.path)
    }

    /// 値を持たない(nil)側を「小さい」扱いにして比べる。サイズを持たないフォルダや、
    /// 属性を読み取れなかった項目が、昇順では先頭側にまとまる(そのうえで名前順に並ぶ)。
    private static func compareOptional<Value>(
        _ lhs: Value?, _ rhs: Value?, by compare: (Value, Value) -> ComparisonResult
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return compare(lhs, rhs)
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        }
    }

    private static func compareOptional<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> ComparisonResult {
        compareOptional(lhs, rhs) { lhs, rhs in
            if lhs < rhs { return .orderedAscending }
            if rhs < lhs { return .orderedDescending }
            return .orderedSame
        }
    }

    /// directory直下(サブフォルダは見ない)に画像ファイルが1つでもあるかどうか。
    /// サイドパネルの「開く・移動をダブルクリックにする」設定時、フォルダへのダブル
    /// クリックが「画像フォルダとして本を開く」「フォルダへ移動する」のどちらになるかを
    /// 判定するために使う(ユーザー要望: 直下に画像があれば本として開き、無ければ移動)。
    /// 読み取れない場合はfalse(その場合はSidePanelView側で「移動」扱いになる)。
    ///
    /// 一覧の読み込みではフォルダ1件につき1回これを呼ぶ(Entry.containsImageFile)ため、
    /// **本当に途中で打ち切れる**列挙を使う。以前は`contentsOfDirectory(at:)`で全件ぶんの
    /// URLを組み立ててから`contains`で探しており、「見つかり次第打ち切る」と書いてはあった
    /// ものの、実際に節約できていたのは`isImageFile`の判定だけで、ディスクの読み取りと
    /// URLの生成は毎回全件ぶん走っていた。`enumerator`は必要になるまで次を読まないので、
    /// 画像フォルダなら最初の数件で終わる。
    static func directlyContainsImageFile(_ directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return false }
        while let url = enumerator.nextObject() as? URL {
            if isImageFile(url.lastPathComponent) { return true }
        }
        return false
    }

    /// 上記をメインスレッド外(Task.detached)で実行する版。SiblingFinder.siblingBookURLsAsyncと
    /// 同じ形。エラーはそのまま呼び出し側へ伝播する。
    static func entriesAsync(in directory: URL, sort: FolderBrowserSort) async throws -> [Entry] {
        try await Task.detached(priority: .utility) {
            try entries(in: directory, sort: sort)
        }.value
    }

    /// ウェルカム画面でパネルを開いたときの最上位階層として使う、マウント中のボリューム一覧。
    /// 列挙自体はアクセス権を必要としない(実際にその中へ移動して一覧しようとした時点で
    /// 初めてentries(in:)側の権限判定が効く)。
    ///
    /// ボリュームも通常のフォルダとまったく同じ手順でEntryにし、同じ並べ替え設定を通す。
    /// ボリュームはすべてフォルダなので、サイズは持たず、種類も揃うことが多く、結果として
    /// たいていは名前順(向きだけが効く)になる。
    static func mountedVolumeEntries(sort: FolderBrowserSort) -> [Entry] {
        var kindCache: [String: String] = [:]
        let entries = mountedVolumeURLs().compactMap { makeEntry(for: $0, kindCache: &kindCache) }
        return sortedEntries(entries, sort: sort)
    }

    static func mountedVolumeEntriesAsync(sort: FolderBrowserSort) async -> [Entry] {
        await Task.detached(priority: .utility) {
            mountedVolumeEntries(sort: sort)
        }.value
    }

    /// マウント中のボリュームのURL一覧。isVolumeRootからも使うため、Entryの組み立て
    /// (属性の読み取り)を伴わない形で切り出してある。
    private static func mountedVolumeURLs() -> [URL] {
        FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
    }

    /// goUp()で「ボリューム一覧へ戻る」べきタイミングの判定に使う。対象がボリュームのルート
    /// 自身(またはファイルシステムのルート"/")であるかどうか。
    static func isVolumeRoot(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        if standardized.path == "/" { return true }
        return mountedVolumeURLs().contains { $0.standardizedFileURL == standardized }
    }
}

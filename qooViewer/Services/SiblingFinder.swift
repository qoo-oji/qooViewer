import Foundation

/// 「同じフォルダ内の次の本/前の本」と「同じフォルダのファイルを開く」のために、現在開いて
/// いる本の親フォルダの直下だけを見て本の一覧を作るヘルパー(サブフォルダには再帰しない)。
///
/// ■ 列挙も並べ替えもDirectoryBrowserに任せている(自前で列挙しない)
/// サイドパネル上段のフォルダブラウザと**同じ並びにできること**がこの機能の要件
/// (SiblingBookOrder参照)。並べ替えの規則を2箇所に持てば必ず食い違うため、列挙・属性の
/// 取得・並べ替えはDirectoryBrowserへ一本化し、ここは「本として開ける項目だけに絞り込む」
/// という差分だけを受け持つ。並べ替えの基準を将来増やす場合も、DirectoryBrowserへ足すだけで
/// ここは追随する。
///
/// フォルダ内のファイル列挙はメインスレッドを塞がないよう、async版はTask.detachedで
/// バックグラウンドで行う(BookLoader.swiftと同じ理由。詳細はそちらのコメント参照)。
/// nonisolated: Xcode 26既定のMainActor自動分離の対象外にしている。
nonisolated enum SiblingFinder {
    /// url と同じ階層(直下)にある本(画像を直接含むフォルダ、またはzip/rar/7z/pdf/epub
    /// ファイル)を、orderの並びで返す。
    ///
    /// フォルダブラウザの一覧との違いは1点だけ ―― あちらは奥のフォルダへたどり着くための
    /// 通り道として、本を含まない中間フォルダも並べる。ここではそれを落とし、**本として
    /// 開けるもの**だけを残す。並べ替えたあとに絞り込んでも、絞り込んでから並べ替えても結果は
    /// 同じ(DirectoryBrowser.compareが常に全順序になっているため)なので、DirectoryBrowserが
    /// 並べたものをそのまま絞り込んでよい。
    ///
    /// アクセス権が無い場合などのエラーはここで握りつぶし、空の一覧にする(DirectoryBrowserは
    /// throwする)。呼び出し側(AppState)は「一覧が空 = このフォルダを見られない」として
    /// 「このフォルダへのアクセスを許可」の導線を出す作りになっているため。
    private static func siblingBooks(of url: URL, order: SiblingBookOrder) -> [DirectoryBrowser.Entry] {
        readableSiblingBooks(of: url, order: order) ?? []
    }

    /// 上と同じだが、親フォルダを読めなかったら nil(「次の本へ」が、端と読めないとを言い分けるため。`step(after:order:)`)。
    private static func readableSiblingBooks(of url: URL, order: SiblingBookOrder) -> [DirectoryBrowser.Entry]? {
        let parent = url.deletingLastPathComponent()
        guard let entries = try? DirectoryBrowser.entries(in: parent, sort: order.sort) else { return nil }
        // フォルダはそれ自体が 1 冊の本(直下に画像がある、または章ごとに画像フォルダを分けた本)のものだけを残す。棚に並ぶ本と
        // 同じ判定(ShelfFolderResolver.isBookEntry。2026-09-22 の監査 ―― 以前は章ごとの本を飛ばした)。ファイルは
        // DirectoryBrowserの時点で開ける形式に絞られているため、そのまま通す。
        return entries.filter(ShelfFolderResolver.isBookEntry)
    }

    /// 上記のURLだけを取り出した版。
    static func siblingBookURLs(of url: URL, order: SiblingBookOrder) -> [URL] {
        siblingBooks(of: url, order: order).map(\.url)
    }

    /// siblingBookURLs(of:order:)をメインスレッド外で実行する版。
    /// 「同じフォルダのファイルを開く」メニューの一覧取得に使う。
    ///
    /// ブロッキングする一覧なので FileIO の上で(CLAUDE.md「Blocking file I/O goes through FileIO」。2026-10-06 の応答性の点検 R7 ――
    /// 以前は `Task.detached` で、応答しない共有の上の本を開くたびに協調スレッドプールのスレッドを 1 本塞いだ)。一覧の途中では
    /// 取り消しを見ないので、取り消しても読み終えるまで走る(以前と同じ。結果を捨てるのは呼び出し側)。
    static func siblingBookURLsAsync(of url: URL, order: SiblingBookOrder) async -> [URL] {
        await FileIO.perform(qos: .utility) {
            siblingBookURLs(of: url, order: order)
        }
    }

    /// 一覧の中で、currentの1つ後ろにある本。無ければnil(= 最後の本にいる、あるいはcurrentが
    /// この一覧に含まれていない)。
    static func url(after current: URL, order: SiblingBookOrder) async -> URL? {
        await url(steppingBy: 1, from: current, order: order)
    }

    /// 一覧の中で、currentの1つ手前にある本。
    static func url(before current: URL, order: SiblingBookOrder) async -> URL? {
        await url(steppingBy: -1, from: current, order: order)
    }

    private static func url(steppingBy offset: Int, from current: URL, order: SiblingBookOrder) async -> URL? {
        if case .found(let url) = await step(steppingBy: offset, from: current, order: order) { return url }
        return nil
    }

    /// 「次の本へ」「前の本へ」の行き先(見つからなかった理由つき)。
    enum Step: Sendable, Equatable {
        case found(URL)
        /// 一覧の端(最後の本の次・最初の本の前)。
        case atEnd
        /// 一覧に今の本が無い(開いた後に動いた・消えた)。
        case notListed
        /// 親フォルダを読めなかった(許可が無い・読めない)。
        case unreadable
    }

    /// 一覧の中で、currentの1つ後ろ/手前にある本。見つからなければその理由(2026-10-06 の応答性の点検 R2-1 ―― 以前は端も読めない
    /// フォルダも nil で、「次の本へ」が黙って何もしなかった)。
    static func step(after current: URL, order: SiblingBookOrder) async -> Step {
        await step(steppingBy: 1, from: current, order: order)
    }

    static func step(before current: URL, order: SiblingBookOrder) async -> Step {
        await step(steppingBy: -1, from: current, order: order)
    }

    private static func step(steppingBy offset: Int, from current: URL, order: SiblingBookOrder) async -> Step {
        // FileIO で(DirectoryBrowser.listingAsync のコメント。隣のフォルダの一覧はブロッキングする I/O)。
        guard let all = await FileIO.perform(qos: .utility, {
            readableSiblingBooks(of: current, order: order)
        }) else { return .unreadable }

        let currentPath = identityPath(of: current)
        guard let currentEntry = all.first(where: { identityPath(of: $0.url) == currentPath }) else { return .notListed }

        // 「種類の異なる本を挟まない」設定のときだけ、currentと同じ側へ絞り込む
        // (SiblingBookOrder.restrictsToSameType参照)。isDirectoryは一覧を読み込んだ時点の
        // 確定値なので、ここでresourceValuesを取り直す必要はない。
        let candidates = order.restrictsToSameType
            ? all.filter { $0.isDirectory == currentEntry.isDirectory }
            : all
        guard let index = candidates.firstIndex(where: { identityPath(of: $0.url) == currentPath }) else { return .notListed }

        let destination = index + offset
        guard candidates.indices.contains(destination) else { return .atEnd }
        return .found(candidates[destination].url)
    }

    /// 一覧の中からcurrentの位置を探すための突き合わせ用の値。
    ///
    /// 一覧のURLは親フォルダの列挙から作られるのに対し、currentは本を開いた時点のURL
    /// (Finderからの起動、セキュリティスコープ付きブックマークの解決、ドラッグ&ドロップなど
    /// 出どころがまちまち)で、同じ場所を指していても表記が揃うとは限らない ―― フォルダの本は
    /// 末尾のスラッシュの有無で`URL`同士の`==`が成立しないことがある。パスへ正規化してから
    /// 比べることで、「次の本へ」が黙って何もしない状態を避ける。
    ///
    /// シンボリックリンクまでは解決しない。この一覧は`current.deletingLastPathComponent()`を
    /// 列挙して作るので、両者は必ず同じ親のパスを土台に組み立てられており、解決しても
    /// 変わらないため(そのうえ解決はディスクアクセスを伴う)。
    private static func identityPath(of url: URL) -> String {
        url.standardizedFileURL.path
    }
}

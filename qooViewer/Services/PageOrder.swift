import Foundation

/// 本のページ順と、それに揃えたい一覧(サイドパネル下段の本の中身ブラウザなど)で使う名前順の比較。
///
/// 環境設定「一般」→「ページ順」→「並び順をFinderに揃える」(既定はON)で2通りに切り替わる。
///
/// **ON(usesFinderOrder: true)** … `localizedStandardCompare`。Finderが名前順に使っているのと
/// 同じ照合で、数字を数値として比べ、大文字小文字・全角半角を区別せず、記号もロケールの照合順序に
/// 従う。フォルダ・お気に入り・ブックマークなど、このアプリの他の「人に見せる一覧」も元から
/// この比較で揃えてある(DirectoryBrowser.compare等)。
///
/// **OFF(usesFinderOrder: false)** … `compare(_:options: .numeric)`。この設定を入れる前からの
/// 並びで、ロケールを見ないUnicodeスカラー順の比較。Finderとは食い違い、大文字始まりの名前が
/// すべて小文字始まりより先に来るうえ、アンダースコア(U+005F)が大文字より後・小文字より前に
/// 入る。ユーザー報告の`_Com-title-cover.JPG` / `Com_title_name_size_0001.JPG` /
/// `Com-title-cover-clean.JPG`のような名前では、"Com"と"com"で並びが丸ごと変わってしまう。
/// 従来の並びに慣れている本のために残してある選択肢で、既定にはしない。
///
/// キーにフルパス(またはアーカイブ内のエントリパス)を渡す使い方は、どちらの設定でも同じように
/// できる。`localizedStandardCompare`でも"/"は英数字より前・空白/ハイフン/ピリオドより後に
/// 並ぶため、`.numeric`と同じく「フォルダごとにまとまった上で、各フォルダ内が名前順」になる。
///
/// `nonisolated`なのは、BookLoaderの`Task.detached`(メインアクタ外)から呼ばれるため。
nonisolated func comparePageOrder(
    _ lhs: String, _ rhs: String, usesFinderOrder: Bool
) -> ComparisonResult {
    guard usesFinderOrder else { return lhs.compare(rhs, options: .numeric) }
    let byName = lhs.localizedStandardCompare(rhs)
    if byName != .orderedSame { return byName }
    // localizedStandardCompareは大文字小文字などを区別しないため、異なる文字列でも
    // orderedSameを返しうる(例: "A.jpg"と"a.jpg")。そのままだと並べ替えの結果が
    // 実行のたびに揺れる可能性があるので、最後は素の比較で必ず決着させる
    // (DirectoryBrowser.compareが最後にパスで決着させているのと同じ考え方)。
    return lhs.compare(rhs)
}

/// 上の比較の設定値を、メインアクタ外からも読めるようにする入れ物。
nonisolated enum PageOrder {
    /// 「並び順をFinderに揃える」のUserDefaultsキー。**書く側はAppPreferencesだけ**
    /// (AppPreferences.Keys.usesFinderSortOrderがこの定数を参照している)。
    static let defaultsKey = "qooViewer.pref.usesFinderSortOrder"

    /// 「並び順をFinderに揃える」の現在値(既定はON)。
    ///
    /// このアプリの他の設定は、nonisolatedなコードへは引数で渡す流儀にしてある
    /// (DirectoryBrowserへ渡すfolderBrowserSortなど。AppPreferencesが@MainActorの
    /// ObservableObjectで、そのままでは読めないため)。ここだけUserDefaultsを直接読むのは、
    /// この値を要る場所が`BookLoader.load`・`BookOpenRequest.init(openingCandidates:)`・
    /// `BookInternalBrowsing.entries`・`CbzExporter`と広く散らばっており、そのすべてに
    /// 引数を足して回ると、経路ごとに渡し忘れて**同じ本の中でページ順と一覧の順が食い違う**
    /// 事故を作りやすいため。UserDefaultsは複数スレッドから読んで安全なので、
    /// メインアクタ外から読むこと自体に問題は無い。
    ///
    /// 並べ替え1回につき**1度だけ**読んで、比較関数へは値として渡すこと(比較のたびに
    /// 読みに行くと、ページ数の多い本で無駄が積み上がる)。
    static var usesFinderOrder: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }
}

import Foundation

/// ページの名前順の比較と、「並び順をFinderに揃える」設定まわりの道具一式。
///
/// # 並び順の全体設計
///
/// このアプリでは、ページの並び順を次の2層に分けて扱う。
///
/// 1. **正準順(canonical)** … `compareCanonicalPageOrder`。Finderが名前順に使っているのと同じ
///    照合(`localizedStandardCompare`)で、数字を数値として比べ、大文字小文字・全角半角を
///    区別せず、記号もロケールの照合順序に従う。**保存物(本の読み込み結果・構造キャッシュ)は
///    必ずこの順で持つ。** 設定に左右されないため、設定を切り替えても保存物を捨てる必要が無い。
/// 2. **表示順(effective)** … 正準順に対して、環境設定「並び順をFinderに揃える」・ユーザーの
///    並べ替え(`pageOrderOverride`)・除外ページを順に適用したもの。適用するのは
///    `EffectivePageOrder`**1か所だけ**で、ここが唯一の適用点になっている。
///
/// この2層に分けたことで、「設定を読む場所」が実質1か所に減り、経路ごとに読むタイミングが
/// ずれて食い違う(ビューアと一覧で並びが違う、キャッシュだけ古い並びのまま等)ことが
/// 構造的に起きなくなっている。
///
/// # 設定がOFFのときの並び(従来順)
///
/// `compare(_:options: .numeric)`。ロケールを見ないUnicodeスカラー順の比較で、1.36以前は
/// これが唯一の並びだった。Finderとは食い違い、大文字始まりの名前がすべて小文字始まりより
/// 先に来るうえ、アンダースコア(U+005F)が大文字より後・小文字より前に入る。ユーザー報告の
/// `_Com-title-cover.JPG` / `Com_title_name_size_0001.JPG` / `Com-title-cover-clean.JPG` の
/// ような名前では、"Com"と"com"で並びが丸ごと変わってしまう。
///
/// **既定はOFF(従来順)。** 並びが変わるきっかけは、ユーザー自身の意思によるものに限る。
///
/// # フルパスをキーに渡してよい
///
/// どちらの比較でも"/"は英数字より前・空白/ハイフン/ピリオドより後に並ぶため、フルパスや
/// アーカイブ内のエントリパスをそのまま渡しても「フォルダごとにまとまった上で、各フォルダ内が
/// 名前順」になる。
///
/// `nonisolated`なのは、BookLoaderの`Task.detached`(メインアクタ外)から呼ばれるため。

/// 正準順の比較。保存物(本の読み込み結果・構造キャッシュ)は必ずこの順で持つ。
nonisolated func compareCanonicalPageOrder(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let byName = lhs.localizedStandardCompare(rhs)
    if byName != .orderedSame { return byName }
    // localizedStandardCompareは大文字小文字などを区別しないため、異なる文字列でも
    // orderedSameを返しうる(例: "A.jpg"と"a.jpg")。そのままだと並べ替えの結果が
    // 実行のたびに揺れる可能性があるので、最後は素の比較で必ず決着させる
    // (DirectoryBrowser.compareが最後にパスで決着させているのと同じ考え方)。
    return lhs.compare(rhs)
}

/// 表示順の比較。`usesFinderOrder`が真なら正準順と同じ、偽なら従来順(`.numeric`)。
nonisolated func comparePageOrder(
    _ lhs: String, _ rhs: String, usesFinderOrder: Bool
) -> ComparisonResult {
    usesFinderOrder ? compareCanonicalPageOrder(lhs, rhs) : lhs.compare(rhs, options: .numeric)
}

nonisolated enum PageOrder {
    /// 「並び順をFinderに揃える」のUserDefaultsキー。**書く側はAppPreferencesだけ**
    /// (AppPreferences.Keys.usesFinderSortOrderがこの定数を参照している)。
    static let defaultsKey = "qooViewer.pref.usesFinderSortOrder"

    /// 「並び順をFinderに揃える」の現在値(**既定はOFF**)。
    ///
    /// AppPreferencesは@MainActorのObservableObjectで、nonisolatedなコード(BookLoaderの
    /// 検出処理・EffectivePageOrderなど)からは読めない。UserDefaultsは複数スレッドから読んで
    /// 安全なので、ここを唯一の入口にしてある。**既定値をAppPreferences側と必ず揃えること** ――
    /// 食い違うと、画面のトグルと実際の並びが逆になる。
    ///
    /// 並べ替え1回につき**1度だけ**読んで、比較関数へは値として渡すこと(比較のたびに
    /// 読みに行くと、ページ数の多い本で無駄が積み上がる)。
    static var usesFinderOrder: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? false
    }

    /// この本が「並び順の設定によって実際にページの前後が入れ替わる本」かどうか。
    ///
    /// 理屈の上では設定を変えれば並びは変わりうるが、実際にそうなるのは
    /// 「先頭のアンダースコア」「`-`と`_`の混在」「大文字小文字の混在」といった特定の命名を
    /// 含む本だけで、実測ではほとんど存在しない(開発者の蔵書では、レイアウトを持つ66冊・
    /// 最近開いた80冊/11,064ページのいずれも該当0件だった)。
    ///
    /// そのため、並びを固定する(pageOrderOverrideへの焼き付け)のも、設定を切り替えるときの
    /// 確認を出すのも、**この判定が真になった本だけ**を対象にする。無関係な本にまで印を付けたり、
    /// 影響が無いのに確認を出してユーザーを不安にさせたりしないための、唯一の判定関数。
    ///
    /// - Parameter keys: 判定したいページのキー(`PageRef.sortKey`)。本の全ページを渡すのが
    ///   正確だが、一部しか手元に無い場合(DBのレイアウト行だけなど)でも、**真を返したら
    ///   確実に影響がある**(偽は「その範囲では変わらない」までしか言えない)。
    static func differsByOrderSetting(keys: [String]) -> Bool {
        guard keys.count > 1 else { return false }
        return keys.sorted { compareCanonicalPageOrder($0, $1) == .orderedAscending }
            != keys.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }
}

extension Notification.Name {
    /// 環境設定「並び順をFinderに揃える」が変わったことを知らせる通知
    /// (AppPreferences.usesFinderSortOrderのdidSetから送られる)。
    ///
    /// 受け取る側は、**本を読み込み直さずに手元のページ配列を並べ直せばよい**。並び順の
    /// 切り替えはページ集合を変えず順序だけを変えるので、並べ直した結果は読み込み直した
    /// 結果と必ず一致する(EffectivePageOrderを通せば、ユーザーの並べ替え・除外も同時に
    /// 反映される)。
    static let pageOrderSettingDidChange = Notification.Name("qooViewer.pageOrderSettingDidChange")
}

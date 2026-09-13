import Foundation

/// ページの名前順の比較の道具一式。
///
/// # 並び順の全体設計
///
/// このアプリでは、ページの並び順を次の2層に分けて扱う。
///
/// 1. **正準順(canonical)** … `compareCanonicalPageOrder`。Finderが名前順に使っているのと同じ
///    照合(`localizedStandardCompare`)で、数字を数値として比べ、大文字小文字・全角半角を
///    区別せず、記号もロケールの照合順序に従う。**保存物(本の読み込み結果・構造キャッシュ)は
///    必ずこの順で持つ。**
/// 2. **表示順(effective)** … 正準順に対して、ユーザーの並べ替え(`pageOrderOverride`)と
///    除外ページを順に適用したもの。適用するのは`EffectivePageOrder`**1か所だけ**。
///
/// # 表示順の切り替えは無くなった(2026-09-13、改善要望7)
///
/// 以前は環境設定「並び順をFinderに揃える」があり、OFFのときは表示順だけを従来順
/// (`compareLegacyPageOrder`)で並べていた(2026-09-06から既定ON)。設定の整理で撤去し、
/// 表示順は常に正準順になった。UserDefaultsの値(`retiredSettingKey`)は消していない ――
/// 古い版を起動した人の設定を壊さないためと、OFFで使っていた人のコレクション表紙を一度だけ
/// 作り直す判定に使うため(CollectionCoverExtractor.refreshCoversForRetiredOrderSettingIfNeeded)。
///
/// 従来順が残っているのは次の2つの用途だけ。
/// - 鍵を持たない古いBookmark.pageIndex等を鍵へ変換する(EffectivePageOrder.legacyOrderedPageKeys)
/// - `differsByOrderSetting` ―― レイアウトを保存した本の並びを固定するかの判定
///   (LayoutStore.pinPageOrderIfNeeded)。OFFの時代に焼いた`pageOrderOverride`はそのまま効き続ける。
///
/// # 従来順
///
/// `compare(_:options: .numeric)`。ロケールを見ないUnicodeスカラー順の比較で、1.36以前は
/// これが唯一の並びだった。Finderとは食い違い、大文字始まりの名前がすべて小文字始まりより
/// 先に来るうえ、アンダースコア(U+005F)が大文字より後・小文字より前に入る。ユーザー報告の
/// `_Com-title-cover.JPG` / `Com_title_name_size_0001.JPG` / `Com-title-cover-clean.JPG` の
/// ような名前では、"Com"と"com"で並びが丸ごと変わってしまう。
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

/// 従来順(1.36以前の並び)の比較。用途はPageOrder.swift冒頭の「従来順が残っているのは」の2つだけ。
nonisolated func compareLegacyPageOrder(_ lhs: String, _ rhs: String) -> ComparisonResult {
    lhs.compare(rhs, options: .numeric)
}

nonisolated enum PageOrder {
    /// 撤去した環境設定「並び順をFinderに揃える」のUserDefaultsキー。**もう誰も書かない。**
    /// 値は消さずに残してあり、読むのはCollectionCoverExtractorの一度きりの作り直しだけ
    /// (冒頭の「表示順の切り替えは無くなった」参照)。
    static let retiredSettingKey = "qooViewer.pref.usesFinderSortOrder"

    /// この本が「正準順と従来順で実際にページの前後が入れ替わる本」かどうか(名前は設定があった
    /// 頃のまま)。
    ///
    /// 実際にそうなるのは
    /// 「先頭のアンダースコア」「`-`と`_`の混在」「大文字小文字の混在」といった特定の命名を
    /// 含む本だけで、実測ではほとんど存在しない(開発者の蔵書では、レイアウトを持つ66冊・
    /// 最近開いた80冊/11,064ページのいずれも該当0件だった)。
    ///
    /// そのため、並びを固定する(pageOrderOverrideへの焼き付け)のは**この判定が真になった
    /// 本だけ**を対象にする。無関係な本にまで印を付けないための、唯一の判定関数。
    ///
    /// - Parameter keys: 判定したいページのキー(`PageRef.sortKey`)。本の全ページを渡すのが
    ///   正確だが、一部しか手元に無い場合でも、**真を返したら確実に影響がある**
    ///   (偽は「その範囲では変わらない」までしか言えない)。
    static func differsByOrderSetting(keys: [String]) -> Bool {
        guard keys.count > 1 else { return false }
        return keys.sorted { compareCanonicalPageOrder($0, $1) == .orderedAscending }
            != keys.sorted { compareLegacyPageOrder($0, $1) == .orderedAscending }
    }
}

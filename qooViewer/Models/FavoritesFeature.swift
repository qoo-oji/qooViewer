/// お気に入り機能の入り口をまとめて塞ぐスイッチ(改善要望5)。機能は廃止したが、将来復活させられるよう
/// モデル・ストア・ウインドウ・JSON はすべて残し、UI からの入り口だけをこのフラグで隠している。
/// 復活させるときはここを true に戻す。データ(FavoriteBook/FavoriteFolder)は消えていないので、
/// 戻した時点で以前の登録がそのまま見える。
///
/// 「消すのではなく隠す」理由:
/// - 保存済みの登録を失わせない(ユーザーの資産。復活させたら元通り見える)
/// - 書き出し JSON の `favorites` セクションを読める状態のまま残す(過去の書き出しファイルからの
///   取り込み経路を壊さない。LibraryImportExportService 参照)
/// - 「保存データの削除」からは残骸を掃除できるようにしておく(LibraryCleanupViewModel は
///   お気に入りの削除を続ける。列だけを隠す)
///
/// 入り口を塞ぐ箇所の一覧は docs/plans/library-collections-plan.md の段階1にある。
enum FavoritesFeature {
    /// false = お気に入りの UI をどこにも出さない。
    static let isEnabled = false
}

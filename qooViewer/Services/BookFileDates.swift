import Foundation

/// 本(ファイル/フォルダ)の作成日と変更日。Finderの「作成日」「変更日」と同じ値
/// (`creationDateKey` / `contentModificationDateKey`)。コレクションの中の並び順「作成日」
/// 「変更日」に使う(ユーザー要望 2026-09-13)。
///
/// **DBには保存しない。** ファイル側の値はアプリの外で変わる(上書き保存・フォルダへの追加で
/// 変更日が進む)ので、覚えておくと古くなる。実体確認と同じ契機(起動・アクティブ化・
/// ボリュームの着脱)で、実体確認のついでに読み直す(CollectionStore.scheduleExistenceRefresh)。
/// 登録した直後は、URLを持っているその場で読む(CollectionStore.makePendingItem)。
///
/// nonisolated: 実体確認の`Task.detached`とドロップの振り分けから呼ぶため。
nonisolated struct BookFileDates: Equatable, Sendable {
    var created: Date?
    var modified: Date?

    /// 読めなければnil。セキュリティスコープの開始は呼び出し側の責任(読むのは属性だけ)。
    static func read(at url: URL) -> BookFileDates? {
        guard let values = try? url.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        ) else { return nil }
        let dates = BookFileDates(created: values.creationDate, modified: values.contentModificationDate)
        return dates.created == nil && dates.modified == nil ? nil : dates
    }
}

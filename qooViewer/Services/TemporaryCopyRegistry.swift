import Foundation

/// 「新しい本として開く」で一時フォルダへ書き出した入れ子の書庫(`MangaBook.isTemporaryCopy`)の**持ち主の数**(2026-10-05 の監査 A7-2)。
///
/// 一時コピーの寿命はその本を表示している窓(`AppState.ownedTemporaryCopies`)が持つ(2026-10-04 の監査 SP-4)。以前はパスが一時フォルダの
/// 下かどうかだけで「自分のもの」と決めていたので、
/// - 同じ一時コピーを 2 つの窓で開くと(Finder の「表示」から落とす・シークレットウインドウへ落とす)、どちらも持ち主になり、先に別の本へ
///   移った窓が消して、もう一方の窓のページが読めなくなった。
/// - 一時フォルダそのもの(や、入れ子の書庫の解決役が使っている一時ファイル)を落とすと、窓が持ち主になって丸ごと消した。
///
/// ここでは、本の中身ブラウザが**渡したもの**(`handOff`)だけを持ち主の付く一時コピーとして扱い、持ち主の数を数える。最後の持ち主が
/// 手放したときだけ消してよい(`release` が true)。渡されていない一時フォルダの中のもの(一時フォルダそのものを含む)は、どの窓も
/// 持たず消さない ―― アプリの終了時(と次の起動)に `TemporaryFileStore` が片付ける。
@MainActor
final class TemporaryCopyRegistry {
    static let shared = TemporaryCopyRegistry()

    /// 渡されたが、まだどの窓も引き受けていないもの。
    private var handedOff: Set<String> = []
    /// 引き受けた窓の数。
    private var ownerCounts: [String: Int] = [:]

    init() {}

    /// 鍵(`MountTable.normalized` したパス)。`AppState.ownedTemporaryCopies` と同じ形。
    nonisolated static func key(_ url: URL) -> String {
        MountTable.normalized(url.path)
    }

    /// 本の中身ブラウザが書き出した一時コピーを、開く側へ渡す(`BookContentsBrowserState.handOffTemporaryFile`)。
    func handOff(_ url: URL) {
        handedOff.insert(Self.key(url))
    }

    /// 窓が `key` の一時コピーを引き受ける。渡されたもの・ほかの窓が持っているものなら持ち主を 1 つ増やして true、どちらでもなければ
    /// false(その窓は持たない ―― 消さない)。
    func adopt(_ key: String) -> Bool {
        guard handedOff.remove(key) != nil || ownerCounts[key] != nil else { return false }
        ownerCounts[key, default: 0] += 1
        return true
    }

    /// 窓が `key` を手放す。最後の持ち主だったら true(呼ぶ側がファイルを消す)。持ち主でなければ false。
    func release(_ key: String) -> Bool {
        guard let count = ownerCounts[key] else { return false }
        if count <= 1 {
            ownerCounts.removeValue(forKey: key)
            return true
        }
        ownerCounts[key] = count - 1
        return false
    }

    /// 持ち主の数(テストのための口)。
    func ownerCountForTesting(_ key: String) -> Int { ownerCounts[key] ?? 0 }
}

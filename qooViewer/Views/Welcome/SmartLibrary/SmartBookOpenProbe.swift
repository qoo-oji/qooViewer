import Foundation

/// スマートライブラリの本を開く・Finder に表示するなどの**直前の**確かめ(2026-10-04 の監査 O-5)。
///
/// ■ なぜ理由を分けるか
/// 以前は `FileIO.perform { fileExists }` だけで、見つからなければ理由を問わず「本が見つかりません」+パスを出していた。
/// 外付け・NAS を外しているだけ(繋げば開ける)のも、対象フォルダの許可が取り消されたのも、同じ文言で「消えた」と読めた。
/// コレクションの本は理由ごとに書き分けている(`CollectionItemOpenProbe` → `BookLocation`)ので、同じ区別をここでもする。
/// スマートライブラリの本はブックマークを持たず、パスそのもの(対象フォルダの許可の中)なので、区別はパスだけで付ける:
/// ボリュームが繋がっていない(`MountTable`。綴りだけで分かるので触らない)、その名前のものが無い(`ENOENT` / `ENOTDIR`)、
/// それ以外の失敗(許可が無い・読めない)。
///
/// ■ 期限
/// 以前は期限が無く、返ってこない場所(NFS の hard マウントなど)では待つ表示も無いまま何も起きなかった。コレクションの本と
/// 同じ期限(`CollectionItemOpenProbe.limit`)を過ぎたら鳴らして待つのをやめる(I/O 自体は止まらない。`FileIO.withDeadline`)。
nonisolated enum SmartBookOpenProbe {
    enum Presence: Sendable, Equatable {
        case present
        /// 載っていたボリュームが繋がっていない。
        case volumeNotConnected
        /// その名前のものが無い(移動と削除は区別できない)。
        case missing
        /// 在るかどうか分からない(許可が無い・読めない)。
        case unreadable
    }

    /// 1 冊ぶんの判定。**ブロッキングする**(`FileIO` の上で呼ぶ)。
    static func presence(atPath path: String, mounts: MountTable = .current()) -> Presence {
        if mounts.isOnAnUnmountedVolume(URL(fileURLWithPath: path)) { return .volumeNotConnected }
        var info = stat()
        if stat(path, &info) == 0 { return .present }
        switch errno {
        case ENOENT, ENOTDIR: return .missing
        default: return .unreadable
        }
    }

    /// 何冊かを `FileIO` の上で確かめる。期限までに返ってこなければ nil。
    ///
    /// - Parameter firstAwaiting: 確かめる前に待つもの(フォルダの許可の裏の解決 ―― 起動直後はネットワークボリュームの許可が
    ///   まだ解決中で、読めずに「許可が無い」と出てしまう)。これも応答しない共有では戻らないので、同じ期限の中で待つ。
    static func check(
        paths: [String], firstAwaiting prerequisite: (@Sendable () async -> Void)? = nil
    ) async -> [Presence]? {
        do {
            return try await FileIO.withDeadline(CollectionItemOpenProbe.limit) {
                await prerequisite?()
                return await FileIO.perform {
                    let mounts = MountTable.current()
                    return paths.map { presence(atPath: $0, mounts: mounts) }
                }
            }
        } catch {
            return nil
        }
    }
}

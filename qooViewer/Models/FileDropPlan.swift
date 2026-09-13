import Foundation

/// ファイルブラウザへのドラッグ&ドロップで、落とされた項目のそれぞれを**移動するかコピーするか**
/// (改善要望7 段階4b、2026-09-13)。純粋な判定で、ファイルシステムには触らない(同じボリュームかは
/// 呼び出し側がマウント表で答える)。
///
/// ■ Finder と同じ規則
/// - 修飾キーなし: 同じボリュームの中なら移動、別のボリュームへはコピー
/// - ⌥: 常にコピー / ⌘: 常に移動(⌥⌘ は Finder ではエイリアスの作成。作らないので修飾なしと同じ)
/// - ドラッグ元が移動を許していない(`allowsMove == false`)なら、移動のはずの項目もコピー
///
/// 計画(file-browser-plan.md 段階4)は「⌥ で反転」と書いていたが、Finder の実際の割り当ては
/// 「⌥ = コピー、⌘ = 移動」で、別ボリュームで ⌥ を押しても移動にはならない。Finder の代わりに
/// 使う人の手が覚えている方に揃えた。
///
/// ■ 断る場合(nil)
/// - 行き先が運ぶ項目そのもの、またはその中(フォルダを自分の中へ入れる)。1件でもあれば全体を断る
///   (Finder も落とさせない。エンジンの事前検査でも止まるが、落とす前にカーソルで伝える)
/// - 全部が「自分のフォルダへの移動」(何も起きない。Finder も同じフォルダの中のドラッグでは何もしない)
///
/// 同じフォルダへの**コピー**(⌥ を押して同じフォルダへ落とす)は断らない ―― `FileBrowserOperations`が
/// 「両方残す」で複製にする。
nonisolated struct FileDropPlan: Equatable, Sendable {
    /// 移動する項目(落とされた順)。
    let moves: [URL]
    /// コピーする項目(落とされた順)。
    let copies: [URL]

    /// カーソルに出す操作。1件でもコピーがあればコピー(Finder も混在は「+」を出す)。
    var isMove: Bool { copies.isEmpty }

    /// ドロップの瞬間の修飾キー(AppKit の型に依存しないように自前で持つ)。
    struct Modifiers: OptionSet, Sendable {
        let rawValue: Int
        static let option = Modifiers(rawValue: 1 << 0)
        static let command = Modifiers(rawValue: 1 << 1)
    }

    /// - Parameters:
    ///   - items: 落とされた項目。
    ///   - destination: 落とす先のフォルダ。
    ///   - allowsMove: ドラッグ元が移動を許しているか(`NSDragOperation` の `.move` / `.generic`)。
    ///   - isOnSameVolume: 2つの場所が同じボリュームの上か(`MountTable.areOnSameVolume`)。
    static func make(
        items: [URL], destination: URL, modifiers: Modifiers, allowsMove: Bool,
        isOnSameVolume: (URL, URL) -> Bool
    ) -> FileDropPlan? {
        guard !items.isEmpty else { return nil }
        let destinationPath = path(of: destination)
        var moves: [URL] = []
        var copies: [URL] = []
        for item in items {
            let itemPath = path(of: item)
            // 自分自身・自分の中へは落とさせない(型コメント)。
            if MountTable.path(destinationPath, isAtOrUnder: itemPath) { return nil }
            let forcesCopy = modifiers.contains(.option) && !modifiers.contains(.command)
            let forcesMove = modifiers.contains(.command) && !modifiers.contains(.option)
            let wantsMove = forcesMove || (!forcesCopy && isOnSameVolume(item, destination))
            if wantsMove && allowsMove {
                // 自分のフォルダへの移動は何もしない(エンジンの決まりと同じ)ので外す。
                if path(of: item.deletingLastPathComponent()) != destinationPath { moves.append(item) }
            } else {
                copies.append(item)
            }
        }
        guard !moves.isEmpty || !copies.isEmpty else { return nil }
        return FileDropPlan(moves: moves, copies: copies)
    }

    /// 比べるためのパス(`FileBrowserOperations.paths(of:)`と同じ規則)。
    private static func path(of url: URL) -> String {
        MountTable.normalized(url.standardizedFileURL.path)
    }
}

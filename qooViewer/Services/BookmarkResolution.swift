import Foundation

/// セキュリティスコープ付きブックマークを解決する唯一の入口(2026-09-24、利用者の報告)。
///
/// ■ 何が起きていたか
/// `URL(resolvingBookmarkData:options: .withSecurityScope, …)` は、指す先のボリュームが繋がっていないと**繋ぎに行く**。
/// NAS の電源が落ちていると、約 30 秒後に macOS の「サーバ“…”への接続で問題が起きました」が出る(どのアプリのせいかは
/// 書かれない)。2026-09-24 の統合ログで、qooViewer がブックマークを十数件続けて解決した直後に ScopedBookmarkAgent が
/// `smb://…` のマウントを求め、30 秒後に NetAuthAgent が起動したのを確かめた。きっかけは外付けの取り外しの知らせによる
/// 確かめ直しで、メタデータの編集ウインドウ(移動の検出)など、裏で本の在りかを確かめる所はどこでも起こしうる。
/// ディスクイメージも同じで、取り出したイメージの上の本を解決すると**勝手に付け直す**(実測 2026-09-24。
/// BookLocationResolver.isVolumeAvailable のコメントにある 2026-09-10 の実測と同じ現象)。
///
/// ■ どうしたか
/// 裏で自動に行う解決(在りかの確かめ・移動の検出・カバーの抽出・書き出し・取り込み・起動時の復元…)は
/// `.withoutMounting` + `.withoutUI` を付ける(`Purpose.background`、既定)。繋がっていないボリュームの上の本は
/// すぐに(約 10ms)`NSFileNoSuchFileError`(4)で失敗する ―― **実体が無いときと同じコード**なので、「無い」と言い切る所は
/// ボリュームが付いているかを別に確かめること(BookLocationResolver.resolve、BookExistenceProbe)。
/// 利用者が本・フォルダを**開く操作**だけは従来どおり繋ぎに行く(`Purpose.userOpen`)―― 眠っていた共有を開くときに
/// 自動で繋がるのは便利で、失敗してダイアログが出ても、利用者が自分で開こうとした本のことだと分かる。
///
/// 解決の結果は同じ(繋がっていない共有の本は、繋ぎに行っても失敗していた)。変わるのは、NAS の電源は入っているが共有が
/// 繋がっていないとき、裏の確かめがその本を「繋がっていない」として扱う(繋ぎに行かない)ことだけ。
nonisolated enum BookmarkResolution {
    enum Purpose: Sendable {
        /// 裏で自動に行う解決。ボリュームを繋がない・画面を出さない。
        case background
        /// 利用者が本・フォルダを開く操作。繋がっていなければ繋ぎに行く(失敗すれば macOS がダイアログを出す)。
        case userOpen
    }

    static func options(for purpose: Purpose) -> URL.BookmarkResolutionOptions {
        switch purpose {
        case .background: [.withSecurityScope, .withoutUI, .withoutMounting]
        case .userOpen: [.withSecurityScope]
        }
    }

    /// 解決した URL(スコープはまだ開いていない)。失敗すれば nil。
    static func resolve(_ data: Data, purpose: Purpose = .background) -> URL? {
        try? resolveOrThrow(data, purpose: purpose)
    }

    /// 失敗の理由が要る所(BookLocationResolver)向け。
    static func resolveOrThrow(_ data: Data, purpose: Purpose = .background) throws -> URL {
        var isStale = false
        return try URL(resolvingBookmarkData: data, options: options(for: purpose), relativeTo: nil,
                       bookmarkDataIsStale: &isStale)
    }
}

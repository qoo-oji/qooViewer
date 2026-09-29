import Foundation

/// 「直前の本へ戻る」の戻り先が、開いたときの場所に今も在るか(2026-09-29。`AppState.refreshLastBookAvailability`)。
///
/// ■ 「無い」と「分からない」を分ける
/// 無いと答えるのは、**その名前のものが無い**と OS が答えたとき(`ENOENT` / `ENOTDIR`)と、載っていたボリュームが繋がって
/// いないときだけ。許可が無い・読めない・応答しない、は「分からない」で、ボタンの状態を変えない ―― 読めなかったことを
/// 「無い」に読み替えると、押せば開ける本のボタンが淡色になる。
///
/// ■ 確かめるのは開いたときのパス
/// ブックマークはたどらない。ボタンが開くのは控えてある URL そのもの(`BookOpenRequest.urls`)なので、本がよそへ移って
/// いれば、ボタンからは開けない ―― 移った先を見つけて「在る」と答えてはいけない。
///
/// nonisolated: `FileIO` の上(メインの外)で走らせる。ボリュームへ問い合わせるので、メインから呼ばない。
nonisolated enum LastBookPresence: Sendable, Equatable {
    case present
    case absent
    case unknown

    /// `urls` は `BookOpenRequest.urls`。2 件以上なら画像をまとめた 1 冊で、1 枚でも残っていれば開ける
    /// (`BookLoader.load(imageFiles:)` は無い画像を除いて開く)ので、**どれかが在れば在る**。どれも無ければ無い。
    static func probe(_ urls: [URL], mounts: MountTable = .current()) -> LastBookPresence {
        var sawUnknown = false
        for url in urls {
            switch probe(url, mounts: mounts) {
            case .present: return .present
            case .unknown: sawUnknown = true
            case .absent: break
            }
        }
        if urls.isEmpty || sawUnknown { return .unknown }
        return .absent
    }

    private static func probe(_ url: URL, mounts: MountTable) -> LastBookPresence {
        // 繋がっていないボリュームは、綴りだけで分かるので触らない(外れたあとも空のフォルダが残ることがある。
        // MountTable.isOnAnUnmountedVolume のコメント)。
        if mounts.isOnAnUnmountedVolume(url) { return .absent }
        // 開くとき(AppState.open)と同じく、ブックマークから解決した URL はスコープを開いてから見る。開かずに見ると、
        // 在る本がサンドボックスに隠されて見えない。
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var info = stat()
        // stat(リンクはたどる): 記号リンクの本は、先が無ければ開けない。
        if stat(url.path, &info) == 0 { return .present }
        switch errno {
        case ENOENT, ENOTDIR: return .absent
        default: return .unknown
        }
    }
}

extension AppState.LastBookAvailability {
    /// 確かめの答えを受けたあとの状態(`AppState.LastBookAvailability` の各 case のコメント)。
    nonisolated func updated(by presence: LastBookPresence) -> AppState.LastBookAvailability {
        switch (self, presence) {
        case (_, .unknown): self
        case (_, .absent): .missing
        // 在るのに開けなかった本は、在ることを確かめ直しても押せる状態へ戻さない。
        case (.failedToOpen, .present): .failedToOpen
        case (_, .present): .available
        }
    }
}

import Foundation

/// ファイルブラウザが表示している場所(2026-09-28)。
///
/// それまでは `FileBrowserState.currentFolder: URL?` だけで、nil が「コンピュータ」(ボリュームの一覧)だった。Finder の
/// 「最近の項目」にあたる、**実フォルダではない 2 つ目の場所**(`recents`: このアプリで最近開いた本の一覧)を足すにあたり、
/// 場所を 1 つの値で持てるようにした。`currentFolder` は今も残り、`.computer` と `.recents` のどちらでも nil ―― 「実フォルダが
/// 無い」ことに頼っていた判断(書き込めない・新規フォルダを作れない・ドロップを断る・FSEvents を張らない・上へ行けない)は、
/// そのまま最近の項目にも当てはまる。
///
/// ■ 最近の項目の中身
/// `RecentFilesStore.entries`(ファイルメニューの「最近使った項目を開く」と同じ)を**新しい順のまま**並べる。一覧の並べ替えの
/// 設定は効かせない ―― 履歴には「最後に開いた日時」が無く、名前順などに並べ替えると「最近」の意味が消えるため
/// (`FileBrowserState.resort` が最近の項目では並べ直さない)。項目の操作(開く・Finder で表示・コピー・ゴミ箱など)は
/// ふつうの一覧と同じで、場所そのものへの操作(ペースト・新規フォルダ・ドロップ)は無い。
nonisolated enum FileBrowserLocation: Equatable, Sendable {
    /// ボリュームの一覧。
    case computer
    /// 最近開いた本の一覧(環境設定「ファイルブラウザ」の「ツリーの先頭に「最近の項目」を表示」が ON の間だけ)。
    case recents
    case folder(URL)

    /// 実フォルダ(コンピュータ・最近の項目は nil)。
    var folder: URL? {
        if case .folder(let url) = self { return url }
        return nil
    }

    var isRecents: Bool { self == .recents }

    /// 場所を見分ける鍵。フォルダはパス(`FileBrowserState.id(for:)`)、最近の項目は固定の文字、コンピュータは nil。
    /// ツリーの行の選択と、読み込みの重なりの判定に使う。
    var selectionKey: String? {
        switch self {
        case .computer: nil
        case .recents: Self.recentsSelectionKey
        case .folder(let url): url.path
        }
    }

    /// パスとぶつからない鍵(パスは必ず `/` で始まる)。「最後に表示したフォルダ」の記録にも同じ文字を使う。
    static let recentsSelectionKey = "<recents>"
}

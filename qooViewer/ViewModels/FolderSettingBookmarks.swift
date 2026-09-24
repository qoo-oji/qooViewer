import Foundation

/// パスだけで覚えているフォルダの設定(メタデータの除外フォルダ・スマートライブラリの対象フォルダ・コレクションの自動登録フォルダ)を、
/// アプリの外(Finder など)での名前の変更・移動に付いていかせるための控え(2026-09-22、利用者の指示)。アプリで 1 つ(AppStores)。
///
/// 設定そのものの保存形式(qooMeta の settings.json・UserDefaults・SwiftData)は変えず、**パス → ブックマーク**の控えを別に持つ。
/// ブックマークは移動・改名を追うので、解決した先が記録したパスと違えば、その組(古い → 新しい)を返す。受け手(AppStores)は、
/// アプリの中での移動と同じ付け替え(各ストアの `relocate(using:)`)に通す。
///
/// - 控えを作るのは、設定を足した直後とアプリから離れるとき(`sync`)。ファイル選択のパネルで選んだ場所は、その起動の間は読めるので、
///   その間にブックマークを作れる。読めない場所(以前の版で足した、権限の無いフォルダ)は作れず、今までどおりパスだけになる。
/// - 解決は画面の外で、繋がっていないボリュームとネットワークのボリュームのものはしない(秒単位で止まる。MountTable だけで判定)。
///   ゴミ箱の中へ移ったものは「動いた」にしない(BookLocationResolver.isInTrash)。
@MainActor
final class FolderSettingBookmarks {
    static let defaultsKey = "qooViewer.folderSettingBookmarks"

    private let defaults: UserDefaults
    private(set) var bookmarks: [String: Data]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        bookmarks = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: Data]) ?? [:]
    }

    /// 控えを今の設定に合わせる: 無くなったパスの控えを捨て、控えの無いパスのブックマークを作る(作れなければそのまま)。
    func sync(paths: Set<String>) async {
        let missing = paths.subtracting(bookmarks.keys)
        let keysBefore = Set(bookmarks.keys)
        let created = await Task.detached(priority: .utility) { () -> [String: Data] in
            let mounts = MountTable.current()
            var created: [String: Data] = [:]
            for path in missing where Self.isReachable(path, mounts: mounts) {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    created[path] = data
                }
            }
            return created
        }.value
        // 待っている間に付け替わった鍵(`relocate`。アプリへ戻った直後の追従など)は、渡されたパスに無くても捨てない
        // (2026-09-23 の 3 回目の監査の低: 以前は捨てていて、そのフォルダがアプリの外で動いても追えなくなった)。
        var updated = bookmarks.filter { paths.contains($0.key) || !keysBefore.contains($0.key) }
        updated.merge(created) { _, new in new }
        guard updated != bookmarks else { return }
        bookmarks = updated
        defaults.set(updated, forKey: Self.defaultsKey)
    }

    /// 控えのうち、アプリの外で動いたもの(古いパス → 新しいパス)。
    func movedFolders() async -> [FileSystemChange.Relocation] {
        let snapshot = bookmarks
        return await Task.detached(priority: .utility) {
            let mounts = MountTable.current()
            return snapshot.keys.sorted().compactMap { path -> FileSystemChange.Relocation? in
                guard Self.isReachable(path, mounts: mounts), let data = snapshot[path] else { return nil }
                guard let url = BookmarkResolution.resolve(data),
                      !BookLocationResolver.isInTrash(url),
                      BookExistenceProbe.comparablePath(url.path) != BookExistenceProbe.comparablePath(path)
                else { return nil }
                return .init(from: URL(fileURLWithPath: path, isDirectory: true),
                             to: URL(fileURLWithPath: MountTable.normalized(url.path), isDirectory: true))
            }
        }.value
    }

    /// 付け替えたパスへ控えの鍵を移す(アプリの中での移動・アプリの外での移動の両方)。ブックマークは同じもの(移動を追う)。
    func relocate(using change: FileSystemChange) {
        guard !change.relocations.isEmpty else { return }
        var updated: [String: Data] = [:]
        for (path, data) in bookmarks {
            updated[change.relocatedPath(for: path).map(MountTable.normalized) ?? path] = data
        }
        guard updated != bookmarks else { return }
        bookmarks = updated
        defaults.set(updated, forKey: Self.defaultsKey)
    }

    nonisolated private static func isReachable(_ path: String, mounts: MountTable) -> Bool {
        let url = URL(fileURLWithPath: path)
        return !mounts.isOnAnUnmountedVolume(url) && !mounts.isRemote(url)
    }
}

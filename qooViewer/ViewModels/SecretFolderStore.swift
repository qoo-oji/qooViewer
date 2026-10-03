import Combine
import Foundation
import Synchronization

/// シークレットフォルダ(2026-10-03、利用者の要望。docs/plans/secret-folder-plan.md)。
///
/// **この中(サブフォルダを含む)の本は、どの窓で開いても保存データに何も残さない**。表示している間、その窓はシークレット
/// ウインドウの見た目(外観一式・タイトルの「(シークレット)」)になり、外の本へ移れば元に戻る。書かないものは
/// シークレットウインドウと同じ一式(`AppState.isPrivateWindow` のコメントが正典)で、実際に断るのは `MangaBook.leavesNoRecord`
/// (= `isInSecretFolder` を含む)を見ている各所。本を開かずに書く所(ホームの表紙のディスクキャッシュ・コレクションへの追加・
/// スマートライブラリ・メタデータの生成など)は、この型の `contains` / `isSecretAppWide` で場所を見て断る。
///
/// 以前の「メタデータの登録の対象外のフォルダ」(`MetadataRulesStore` の `excludedFolders`、2026-09-21〜)を作り直したもの。
/// あちらの一覧は起動時に 1 度だけここへ移す(`migrateLegacyExcludedFolders`)。
///
/// 持つのは**パスだけ**(末尾の `/` を持たない。`MountTable.normalized`)。読む権限は要らない(パスで比べるだけ)。
/// 保存先は UserDefaults の `qooViewer.secretFolders`。**`qooViewer.pref.*` には置かない** ―― 「初期設定に戻す」で黙って消え、
/// 記録が再開してしまうため。保存データの書き出しには入る(`QooLibraryExportFile.secretFolders`)。
///
/// `AppStores.allObjectWillChangePublishers` には足さない(メニューバーは読まない)。
@MainActor
final class SecretFolderStore: ObservableObject {
    static let defaultsKey = "qooViewer.secretFolders"
    /// 以前のメタデータ用の対象外のフォルダを移したか。
    static let didMigrateLegacyKey = "qooViewer.secretFolders.didMigrateLegacy"
    /// 移したことを知らせる必要があるか(移した一覧が空でなかった。知らせたら消す)。
    static let migrationNoticePendingKey = "qooViewer.secretFolders.migrationNoticePending"

    /// 一覧が変わった知らせ(`MetadataGenerator` が母体を集め直す、スマートライブラリが集め直す)。
    static let didChange = Notification.Name("qooViewer.secretFoldersDidChange")

    @Published private(set) var folders: [String] = []

    /// nil なら保存しない(テストの中のアプリ・テスト)。
    private let defaults: UserDefaults?
    /// アプリに 1 つのストアか。真なら一覧を `appWideFolders` にも写す。知らせを受ける側は、テストの作ったストアの知らせを
    /// これで見分けて無視する。
    nonisolated let isAppWideStore: Bool

    /// - Parameters:
    ///   - defaults: 保存先。nil ならメモリの上だけ。**既定は nil** ―― 省いて作ったストアが実物の `UserDefaults.standard` を
    ///     書き換えないように(テストは共有の状態に触らない。CLAUDE.md)。アプリ(`AppStores`)は `.standard` を渡す。
    ///   - isAppWide: アプリに 1 つのもの(`AppStores`)。真なら一覧を `appWideFolders` にも写す。テストの中で作ったストアは写さない
    ///     (共有の状態に触らない)。
    init(defaults: UserDefaults? = nil, isAppWide: Bool = false) {
        self.defaults = defaults
        isAppWideStore = isAppWide
        folders = (defaults?.stringArray(forKey: Self.defaultsKey) ?? []).map(MountTable.normalized)
        if isAppWideStore { Self.appWideFolders.withLock { [folders] in $0 = folders } }
    }

    // MARK: - 判定

    /// アプリの一覧の写し。ストアを受け取れない所(本を読み込むタスク・ファイルブラウザの絵・裏の仕事)が読む。
    nonisolated static let appWideFolders = Mutex<[String]>([])
    /// アプリの一覧の写しの、いまの値。
    nonisolated static var currentAppWideFolders: [String] { appWideFolders.withLock { $0 } }

    /// `path` がシークレットフォルダそのものか、その中(サブフォルダを含む)にあるか。
    nonisolated static func contains(path: String, in folders: [String]) -> Bool {
        guard !folders.isEmpty else { return false }
        let normalized = MountTable.normalized(path)
        return folders.contains { MountTable.path(normalized, isAtOrUnder: $0) }
    }

    /// アプリの一覧の写しで確かめる。
    nonisolated static func isSecretAppWide(path: String) -> Bool {
        contains(path: path, in: currentAppWideFolders)
    }

    nonisolated static func isSecretAppWide(_ url: URL) -> Bool { isSecretAppWide(path: url.path) }

    func contains(path: String) -> Bool { Self.contains(path: path, in: folders) }

    /// そのフォルダが一覧にそのまま載っているか(右クリックの「追加」と「外す」の切り替え)。
    func isListed(_ url: URL) -> Bool {
        folders.contains(MountTable.normalized(url.standardizedFileURL.path))
    }

    // MARK: - 変更

    func add(_ url: URL) {
        add(paths: [url.standardizedFileURL.path])
    }

    func add(paths: [String]) {
        var updated = folders
        for path in paths.map(MountTable.normalized) where !updated.contains(path) {
            updated.append(path)
        }
        if updated != folders { setFolders(updated) }
    }

    func remove(_ path: String) {
        let normalized = MountTable.normalized(path)
        guard folders.contains(normalized) else { return }
        setFolders(folders.filter { $0 != normalized })
    }

    /// アプリ自身・アプリの外で名前を変えた・移したフォルダの登録を付け替える(FavoriteLocationStore.relocate と同じ規則)。
    func relocate(using change: FileSystemChange) {
        guard !change.relocations.isEmpty else { return }
        var seen = Set<String>()
        let relocated = folders.compactMap { path -> String? in
            let new = change.relocatedPath(for: path).map(MountTable.normalized) ?? path
            return seen.insert(new).inserted ? new : nil
        }
        if relocated != folders { setFolders(relocated) }
    }

    /// 保存データの JSON から読み込む。**無いフォルダも落とさない** ―― 繋がっていないボリュームの上かもしれず、残しておいても
    /// 記録が減るだけで害が無い(落とすと、そのボリュームを付けた瞬間から記録が始まる)。
    /// - Returns: 新しく加えた数。
    @discardableResult
    func importBackup(paths: [String], replacingExisting: Bool) -> Int {
        var updated = replacingExisting ? [] : folders
        var added = 0
        for path in paths.map(MountTable.normalized) where !path.isEmpty && !updated.contains(path) {
            updated.append(path)
            if !folders.contains(path) { added += 1 }
        }
        if updated != folders { setFolders(updated) }
        return added
    }

    private func setFolders(_ updated: [String]) {
        folders = updated
        if isAppWideStore { Self.appWideFolders.withLock { $0 = updated } }
        defaults?.set(updated, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - 以前のメタデータ用の対象外のフォルダからの移行

    /// 以前の一覧を 1 度だけ移す(利用者の決定 2026-10-03: 移して、対象が履歴まで広がる旨を 1 度だけ知らせる)。
    /// - Returns: 移したフォルダの数(既に移してあれば 0)。
    @discardableResult
    func migrateLegacyExcludedFolders(from rulesStore: MetadataRulesStore) -> Int {
        guard let defaults, !defaults.bool(forKey: Self.didMigrateLegacyKey) else { return 0 }
        let legacy = rulesStore.legacyExcludedFolders
        let before = folders.count
        add(paths: legacy)
        let moved = folders.count - before
        defaults.set(true, forKey: Self.didMigrateLegacyKey)
        if moved > 0 { defaults.set(true, forKey: Self.migrationNoticePendingKey) }
        // 移し終えてから以前の一覧を消す(順序を逆にすると、間で落ちたときに両方から消える)。
        rulesStore.clearLegacyExcludedFolders()
        return moved
    }

    /// 移したことをまだ知らせていないか。
    var hasPendingMigrationNotice: Bool { defaults?.bool(forKey: Self.migrationNoticePendingKey) ?? false }

    func markMigrationNoticeShown() {
        defaults?.removeObject(forKey: Self.migrationNoticePendingKey)
    }
}

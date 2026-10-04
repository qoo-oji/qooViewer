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
    /// アプリに 1 つのストアか。真なら一覧を `appWideMatcher` にも写す。知らせを受ける側は、テストの作ったストアの知らせを
    /// これで見分けて無視する。
    nonisolated let isAppWideStore: Bool

    /// - Parameters:
    ///   - defaults: 保存先。nil ならメモリの上だけ。**既定は nil** ―― 省いて作ったストアが実物の `UserDefaults.standard` を
    ///     書き換えないように(テストは共有の状態に触らない。CLAUDE.md)。アプリ(`AppStores`)は `.standard` を渡す。
    ///   - isAppWide: アプリに 1 つのもの(`AppStores`)。真なら一覧を `appWideMatcher` にも写す。テストの中で作ったストアは写さない
    ///     (共有の状態に触らない)。
    init(defaults: UserDefaults? = nil, isAppWide: Bool = false) {
        self.defaults = defaults
        isAppWideStore = isAppWide
        folders = (defaults?.stringArray(forKey: Self.defaultsKey) ?? []).map(MountTable.normalized)
        matcher = Matcher(folders)
        if isAppWideStore { Self.appWideMatcher.withLock { [matcher] in $0 = matcher } }
    }

    // MARK: - 判定

    /// アプリの一覧の写し(比べる形にしたもの)。ストアを受け取れない所(本を読み込むタスク・ファイルブラウザの絵・裏の仕事)が読む。
    nonisolated static let appWideMatcher = Mutex<Matcher>(Matcher([]))
    /// アプリの一覧の写しの、いまの値。何冊も続けて確かめる所は、これを 1 度取って使い回す。
    nonisolated static var currentAppWideMatcher: Matcher { appWideMatcher.withLock { $0 } }

    /// この一覧を比べる形(`comparable`)にしたもの。**何冊も続けて確かめる所は 1 度作って使い回す**(2026-10-04 の監査:
    /// 以前は 1 冊ごとにフォルダの側も正規化し直し、`String` の `hasPrefix`(正準等価で比べるので遅い)で比べていたので、
    /// スマートライブラリの集め直し・メタデータ生成のたびに、メインで 5 万冊・5 フォルダあたり約 0.4 秒かかっていた。
    /// 両側とも NFC にそろえてあるので、比べるのは UTF-8 のバイト列でよい ―― 同じ条件で約 0.07 秒)。
    nonisolated struct Matcher: Sendable, Equatable {
        /// 比べる形のフォルダの UTF-8。
        private let folders: [[UInt8]]

        init(_ folders: [String]) {
            self.folders = folders.map { Array(SecretFolderStore.comparable($0).utf8) }
        }

        var isEmpty: Bool { folders.isEmpty }

        /// `path` がどれかのフォルダそのものか、その中にあるか(`MountTable.path(_:isAtOrUnder:)` と同じ規則を、バイト列で)。
        func contains(path: String) -> Bool {
            guard !folders.isEmpty else { return false }
            let target = Array(SecretFolderStore.comparable(path).utf8)
            return folders.contains { Self.bytes(target, areAtOrUnder: $0) }
        }

        private static let slash = UInt8(ascii: "/")

        private static func bytes(_ path: [UInt8], areAtOrUnder ancestor: [UInt8]) -> Bool {
            if ancestor == [slash] { return path.first == slash }
            guard path.count >= ancestor.count, path.starts(with: ancestor) else { return false }
            return path.count == ancestor.count || path[ancestor.count] == slash
        }
    }

    /// 比べる形にしたこの一覧(`folders` を変えるたびに作り直す)。
    private(set) var matcher = Matcher([])

    /// 比べるための形。**`/private/var`・`/private/tmp` と `/var`・`/tmp` を同じものとして扱う**(2026-10-03、CI で判明):
    /// `standardizedFileURL` は実在するときだけ `/private` を外す(実在依存)ので、フォルダを足した経路と本の bookID
    /// (`sourceURL.path`、外さない)とで同じ場所が別の綴りになり、手元では通るテストが CI の一時フォルダで落ちた。
    /// 正規化の揺れ(NFD/NFC)と末尾の `/` も揃える(`BookExistenceProbe.comparablePath` と同じ規則)。
    nonisolated static func comparable(_ path: String) -> String {
        BookExistenceProbe.comparablePath(MountTable.normalized(path))
    }

    /// `path` がシークレットフォルダそのものか、その中(サブフォルダを含む)にあるか(1 回きりの判定。続けて確かめるなら `Matcher`)。
    nonisolated static func contains(path: String, in folders: [String]) -> Bool {
        Matcher(folders).contains(path: path)
    }

    /// アプリの一覧の写しで確かめる。
    nonisolated static func isSecretAppWide(path: String) -> Bool {
        appWideMatcher.withLock { $0.contains(path: path) }
    }

    nonisolated static func isSecretAppWide(_ url: URL) -> Bool { isSecretAppWide(path: url.path) }

    func contains(path: String) -> Bool { matcher.contains(path: path) }

    /// そのフォルダが一覧にそのまま載っているか(右クリックの「追加」と「外す」の切り替え)。
    func isListed(_ url: URL) -> Bool {
        let target = Self.comparable(url.path)
        return folders.contains { Self.comparable($0) == target }
    }

    // MARK: - 変更

    func add(_ url: URL) {
        add(paths: [url.standardizedFileURL.path])
    }

    func add(paths: [String]) {
        var updated = folders
        for path in paths.map(MountTable.normalized)
        where !updated.contains(where: { Self.comparable($0) == Self.comparable(path) }) {
            updated.append(path)
        }
        if updated != folders { setFolders(updated) }
    }

    func remove(_ path: String) {
        let target = Self.comparable(path)
        guard folders.contains(where: { Self.comparable($0) == target }) else { return }
        setFolders(folders.filter { Self.comparable($0) != target })
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
        for path in paths.map(MountTable.normalized)
        where !path.isEmpty && !updated.contains(where: { Self.comparable($0) == Self.comparable(path) }) {
            updated.append(path)
            if !folders.contains(where: { Self.comparable($0) == Self.comparable(path) }) { added += 1 }
        }
        if updated != folders { setFolders(updated) }
        return added
    }

    private func setFolders(_ updated: [String]) {
        // 比べる形を先に作り直す(`$folders` の知らせは値が替わる前に届く ―― 受け手が `contains` を呼んでも新しい一覧で答える)。
        let updatedMatcher = Matcher(updated)
        matcher = updatedMatcher
        if isAppWideStore { Self.appWideMatcher.withLock { $0 = updatedMatcher } }
        folders = updated
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

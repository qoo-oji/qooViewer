import AppKit
import Foundation
import Combine

/// サンドボックス環境で、ユーザーが明示的に許可したフォルダ(ルートフォルダ・ホームフォルダ・
/// 外部ボリュームなど任意の場所)への継続的なアクセス権を管理する。
///
/// サンドボックスは既定では「パネルやドラッグ&ドロップで直接選んだファイル/フォルダ」にしか
/// アクセスできない。ファイル単体(zip/cbz等)を開いただけでは、同じフォルダ内の他のファイルを
/// 一覧できず、「同じフォルダのファイルを開く」機能などが空になってしまう。
/// このストアで一度フォルダを許可しておけば、その配下(何階層下のサブフォルダでも)は
/// 起動のたびに自動的にアクセス可能になる(セキュリティスコープ付きブックマークとして
/// UserDefaultsに永続化し、そのフォルダへの`startAccessingSecurityScopedResource()`を
/// アプリが起動している間ずっと維持し続けるため。これはmacOSサンドボックスの仕組み上、
/// 選んだフォルダの配下すべてに及ぶ)。
///
/// 環境設定の「アクセス権」タブから、許可済みフォルダの一覧表示・追加・削除ができる。
@MainActor
final class FolderAccessStore: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let url: URL
        var id: String { url.path }

        /// 一覧に表示する名前。単純にパスの最後の部分を使うと、ボリュームのルートフォルダ
        /// (例:「Macintosh HD」を許可した場合の内部パスは"/")では"/"とだけ表示されてしまい、
        /// どこを指しているか分かりづらい。Finderが表示するのと同じ名前
        /// (`.localizedNameKey`)を優先的に使うことで、ルートフォルダなら「Macintosh HD」、
        /// 通常のフォルダならそのフォルダ名が表示されるようにする。
        var displayName: String {
            if let localizedName = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName,
               !localizedName.isEmpty {
                return localizedName
            }
            return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }
    }

    @Published private(set) var entries: [Entry] = []

    /// アクセス権(セキュリティスコープ付きブックマーク)の保存先。環境設定「リセット」の
    /// 「すべてのデータを削除」は、UserDefaultsのドメインを丸ごと消したうえで**このキーだけ**を
    /// 書き戻す(QooViewerApp.performPendingStoreResetIfNeeded参照。ユーザーの指示: アクセス権は対象外)。
    static let defaultsKey = "qooViewer.grantedFolderBookmarks"

    /// 今アクセスを開いている(startAccessingSecurityScopedResourceを呼んだ)URL。
    /// パス → 実際に開いたURLオブジェクト。stopは**開いたのと同じURLオブジェクト**へ
    /// 呼ぶ必要があるため、Entryとは別にここで持つ。
    ///
    /// バグ修正: 以前はinit()の中で一度だけentriesを開いており、以後のreload()が
    /// entriesを差し替えても開き直していなかった。reload()はブックマークを解決し直して
    /// **別のURLオブジェクト**を作るため、
    ///   ・追加した直後のフォルダは一度も開かれない(呼び出し側が自前で
    ///     `_ = url.startAccessingSecurityScopedResource()`していたのはこの穴埋め。
    ///     そちらは対になるstopが無く、呼ぶたびにカーネルリソースを漏らしていた)
    ///   ・それまで開いていたURLオブジェクトはstopされないまま捨てられる
    /// という2つの漏れが同時に起きていた。開閉の管理をこのストアに閉じ、reload()のたびに
    /// 差分だけを開閉する。
    private var accessedURLsByPath: [String: URL] = [:]

    /// アクセス権の保存先。通常はアプリの `UserDefaults.standard` で、テストだけが専用の
    /// suite を渡す(`AppPreferences.defaults` と同じ理由)。
    private let defaults: UserDefaults

    /// - Parameter defaults: アクセス権の保存先。既定は実際のアプリの保存先(`.standard`)。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
        // ボリュームを付けた・外したら解決し直す(2026-09-22 の監査。以前は起動時・追加・削除のときしか解決せず、外付けを挿さずに
        // 起動すると、挿した後も次の起動まで「許可が無い」扱いで、自動登録・自動リネーム・スマートライブラリ・隣の本が黙って止まった)。
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload(reusingOpenedFolders: true) }
            })
        }
    }

    private var volumeObservers: [NSObjectProtocol] = []

    /// アプリの中で、許可したフォルダ(またはその親)の名前を変えた・移した(AppStores.handleFileSystemChange から)。
    /// 一覧のパスが古いままだと `isPathCovered` が新しいパスを「許可なし」と答えるので、解決し直す(ブックマークは移動を追う)。
    func handleFileSystemChange(_ change: FileSystemChange) {
        guard entries.contains(where: { change.relocatedPath(for: $0.url.path) != nil }) else { return }
        reload()
    }

    deinit {
        for url in accessedURLsByPath.values {
            url.stopAccessingSecurityScopedResource()
        }
        for observer in volumeObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// フォルダへのアクセスを新たに許可する(既に同じパスがあれば入れ替える)。
    /// 指定したフォルダが、既に許可済みの別フォルダの配下(子孫)にあたる場合は、
    /// 新しいブックマークを重複して追加せず、既存の許可がそのまま使われる(すでに
    /// アクセス可能なため)。逆に、新しく許可するフォルダの配下にあたる既存の許可は、
    /// 冗長になるため取り除く(一覧を整理された状態に保つため)。
    @discardableResult
    func add(url: URL) -> Bool {
        if isPathCovered(url) {
            // 既に祖先フォルダが許可済み。macOSのサンドボックスでは、フォルダへの
            // アクセス許可はその配下すべてに及ぶため、追加の処理は不要。
            return true
        }

        guard let newData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return false }

        var bookmarks = rawBookmarks()
        bookmarks.removeAll { data in
            guard let existingURL = resolvedURL(from: data) else { return false }
            // 同じパス、または新しく許可するフォルダの配下(子孫)にあたる既存の許可を取り除く。
            return existingURL.path == url.path || isAncestor(url, of: existingURL)
        }
        bookmarks.append(newData)
        defaults.set(bookmarks, forKey: Self.defaultsKey)
        reload()
        return true
    }

    /// 許可を取り消す。実際のstopAccessingSecurityScopedResource()は、この後のreload()が
    /// 差分として行う(accessedURLsByPathのコメント参照)。
    func remove(_ entry: Entry) {
        var bookmarks = rawBookmarks()
        bookmarks.removeAll { resolvedURL(from: $0)?.path == entry.url.path }
        defaults.set(bookmarks, forKey: Self.defaultsKey)
        reload()
    }

    /// 指定したURLが、既に許可済みのいずれかのフォルダ自身か、その配下(子孫)に
    /// 含まれているかどうか。含まれていれば、改めてアクセスを許可し直す必要はない。
    func isPathCovered(_ url: URL) -> Bool {
        entries.contains { isAncestor($0.url, of: url) }
    }

    /// ancestorが、target自身かtargetの祖先フォルダであるかどうかを、パスの構成要素同士を
    /// 比較して判定する(単純な文字列の前方一致では、「/Users/foo」が「/Users/foobar」にも
    /// 一致してしまう誤判定が起きるため、パス区切りの単位で比較する)。
    private func isAncestor(_ ancestor: URL, of target: URL) -> Bool {
        let ancestorComponents = normalizedComponents(ancestor)
        let targetComponents = normalizedComponents(target)
        guard ancestorComponents.count <= targetComponents.count else { return false }
        return Array(targetComponents.prefix(ancestorComponents.count)) == ancestorComponents
    }

    /// 比較用にそろえたパスの構成要素。
    ///
    /// **`standardizedFileURL`だけでは足りない。** あれは先頭の`/private`を「そのパスが実在する
    /// ときにだけ」外す(`NSString.standardizingPath`の仕様)。そのため、実在する許可済み
    /// フォルダは`/var/…`に、実在しないファイル(削除された本の在処など。この判定は
    /// LibraryCleanupViewModelが**見つからない本**に対しても行う)は`/private/var/…`のまま、
    /// という食い違いが起きて、配下にあるのに「覆われていない」と判定される。
    /// macOSでは`/private`直下の`etc`/`tmp`/`var`がルート直下から同名で張られている
    /// (`/var` → `/private/var`)ので、先頭の`private`は必ず外して揃えてよい。
    ///
    /// 2026-09-06、CI(サンドボックス無し=作業フォルダが`/private/var/folders/…`)で実際に
    /// 食い違って落ちた(手元はサンドボックスのコンテナ配下で`/private`を含まないため素通り
    /// していた)。
    private func normalizedComponents(_ url: URL) -> [String] {
        var components = url.standardizedFileURL.pathComponents
        if components.count > 1, components[1] == "private" {
            components.remove(at: 1)
        }
        return components
    }

    private func rawBookmarks() -> [Data] {
        defaults.array(forKey: Self.defaultsKey) as? [Data] ?? []
    }

    private func resolvedURL(from data: Data) -> URL? {
        // 起動時・ボリュームの知らせで裏で解決するので、繋ぎに行かない(BookmarkResolution)。
        BookmarkResolution.resolve(data)
    }

    /// - Parameter reusingOpenedFolders: いま開いているフォルダ(ブックマークに書かれたパスが `accessedURLsByPath` にあるもの)は
    ///   解決し直さずにそのまま使う。ボリュームの取り付け・取り外しの知らせ(2026-09-23 の 3 回目の監査の中 10)。解決はメインで
    ///   同期に走り、繋がったまま応答しない共有(眠った NAS など)の許可があると、関係の無い USB を挿しただけで UI が止まった。
    ///   知らせで要るのは、新しく繋がった(まだ開いていない)フォルダを開くこと、外れたボリュームのフォルダを閉じることだけ。
    private func reload(reusingOpenedFolders: Bool = false) {
        // 繋がっていないボリュームを指すブックマークは解決しない(解決はディスクイメージを勝手にマウントし直す・秒単位で止まる
        // ことがある。BookLocationResolver のコメント)。パスはブックマークに書かれた値を読むだけで、ファイルには触らない。
        // 保存したブックマーク自体は残す(繋げば、上のボリュームの知らせでまた解決する)。
        let mounts = MountTable.current()
        let newEntries = rawBookmarks()
            .compactMap { data -> Entry? in
                let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path
                if let path, mounts.isOnAnUnmountedVolume(URL(fileURLWithPath: path, isDirectory: true)) { return nil }
                if reusingOpenedFolders, let path, let opened = accessedURLsByPath[path] { return Entry(url: opened) }
                return resolvedURL(from: data).map(Entry.init)
            }
            .sorted { $0.url.path < $1.url.path }

        // 一覧から消えたフォルダのアクセスを閉じる。
        let newPaths = Set(newEntries.map(\.id))
        for (path, url) in accessedURLsByPath where !newPaths.contains(path) {
            url.stopAccessingSecurityScopedResource()
            accessedURLsByPath.removeValue(forKey: path)
        }
        // 新しく現れたフォルダのアクセスを開く(起動時の復元も、追加直後も同じ経路になる)。
        for entry in newEntries where accessedURLsByPath[entry.id] == nil {
            if entry.url.startAccessingSecurityScopedResource() {
                accessedURLsByPath[entry.id] = entry.url
            }
        }

        entries = newEntries
    }
}

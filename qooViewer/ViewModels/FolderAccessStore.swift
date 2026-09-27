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
        // 起動時の解決は裏で(2026-09-27、表示の切り替えの監査の 11)。以前はここで同期に `reload()` を呼び、許可したフォルダ
        // すべてのブックマークをメインで解決していた ―― 繋がったまま応答しない共有(眠った NAS)や回っていない外付けの許可が
        // 1 つあると、最初のウインドウが出る前に秒単位(SMB で約 30 秒)止まった。解決の済んだフォルダから順に開いて一覧へ足す
        // (`reloadInBackground` のコメント)。
        reloadInBackground()
        // ボリュームを付けた・外したら解決し直す(2026-09-22 の監査。以前は起動時・追加・削除のときしか解決せず、外付けを挿さずに
        // 起動すると、挿した後も次の起動まで「許可が無い」扱いで、自動登録・自動リネーム・スマートライブラリ・隣の本が黙って止まった)。
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadInBackground() }
            })
        }
    }

    /// 裏の解決(`reloadInBackground`)で、フォルダを新しく開いて一覧へ足した(`entries` を差し替えた**後**に送る)。
    ///
    /// `entries` の `@Published` は差し替えの**前**(willSet)に知らせるので、受け手がそこで `isPathCovered` を訊くと古い答えに
    /// なる。起動直後、解決が済む前に「許可なし」として見送った仕事(自動登録フォルダの走査など)をやり直す契機に使う
    /// (AppStores が購読する。2026-09-27、表示の切り替えの監査の 11)。
    let accessGained = PassthroughSubject<Void, Never>()

    /// 裏で解決している最中のブックマーク(ブックマークに書かれたパス → その解決の仕事)。
    /// 待ちたい所(`waitForPendingResolutions`)が、関係するものだけを待てるようにパスで持つ。
    private var pendingResolutions: [String: Task<Void, Never>] = [:]
    /// 解決の世代。同期の `reload()`(追加・削除・名前の変更)や次の裏の解決が始まったら進め、古い解決の結果は捨てる。
    private var resolutionGeneration = 0

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

    /// 追加・削除・名前の変更のあと(利用者の操作の直後)。すべてのブックマークをその場で解決し直す。
    /// 呼び出し側(と `add` の直後に `isPathCovered` を訊くテスト)は、戻った時点で一覧が新しいことを当てにしている。
    private func reload() {
        // 裏で走っている解決の結果は捨てる(ここで全部を解決し直すので、後から届く古い結果で一覧を書き換えない)。
        resolutionGeneration &+= 1
        pendingResolutions = [:]
        // 繋がっていないボリュームを指すブックマークは解決しない(解決はディスクイメージを勝手にマウントし直す・秒単位で止まる
        // ことがある。BookLocationResolver のコメント)。パスはブックマークに書かれた値を読むだけで、ファイルには触らない。
        // 保存したブックマーク自体は残す(繋げば、上のボリュームの知らせでまた解決する)。
        let mounts = MountTable.current()
        let newEntries = rawBookmarks()
            .compactMap { data -> Entry? in
                let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path
                if let path, mounts.isOnAnUnmountedVolume(URL(fileURLWithPath: path, isDirectory: true)) { return nil }
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

    /// 起動時とボリュームの取り付け・取り外しの知らせで、**メインを止めずに**解決し直す(2026-09-27、表示の切り替えの監査の 11)。
    ///
    /// - いま一覧にあるフォルダ(開いているもの)は解決し直さずにそのまま使う(2026-09-23 の 3 回目の監査の中 10 ―― 以前の
    ///   `reload(reusingOpenedFolders:)`)。外れたボリュームの上のものだけ閉じて一覧から外す(マウント表を読むだけ)。
    /// - まだ開いていないブックマークのうち、ネットワークボリュームの上のものは 1 件ずつ `FileIO` の上で解決し、済んだものから開いて
    ///   一覧へ足す。1 件ずつ別に待つので、応答しない共有の許可が 1 つあっても、ほかのフォルダの許可は遅れない。ローカルのものは
    ///   その場で解決する(下のループのコメント)。
    ///
    /// ■ 解決が済むまでの間
    /// そのフォルダは一覧に無い(`isPathCovered` は false)。**先に「ある」と答えてはいけない**: 許可済みの配下なのに見えない
    /// パスを「無い」と言い切る判定(BookExistenceProbe)が、スコープを開く前の `fileExists` の失敗を「消えた」と読んで保存データを
    /// 消しうる。答えが変わるのを待ちたい所は `waitForPendingResolutions(covering:)` を、やり直したい所は `accessGained` を使う。
    private func reloadInBackground() {
        resolutionGeneration &+= 1
        let generation = resolutionGeneration
        pendingResolutions = [:]
        let mounts = MountTable.current()

        // 外れたボリュームの上のフォルダを閉じる(以前の同期の経路と同じ。ファイルには触らない)。
        let kept = entries.filter { !mounts.isOnAnUnmountedVolume($0.url) }
        let keptPaths = Set(kept.map(\.id))
        for (path, url) in accessedURLsByPath where !keptPaths.contains(path) {
            url.stopAccessingSecurityScopedResource()
            accessedURLsByPath.removeValue(forKey: path)
        }
        if kept.count != entries.count { entries = kept }

        for data in rawBookmarks() {
            let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path
            if let path {
                if mounts.isOnAnUnmountedVolume(URL(fileURLWithPath: path, isDirectory: true)) { continue }
                if keptPaths.contains(path) { continue }
            }
            // ネットワークボリューム(MNT_LOCAL でないもの)の上のものだけを裏へ回し、ローカルのものは今までどおりその場で解決する。
            // 止まるのは応答しない共有で、ローカルの解決は数 ms。起動直後の仕事(スマートライブラリの集め直し・ファイルブラウザの
            // 最初の一覧など。どれも許可の一覧を待たずに読みに行く)が、解決の済む前に読んで空の結果を出す・保存するのを、
            // ローカルのフォルダについては今までどおり起こさない(解決の済む前は「許可なし」として扱う ―― 下の ■)。
            // パスを読めないブックマーク(壊れている等)もその場で解決を試す(以前の同期の経路と同じ)。
            guard let path, mounts.isRemote(URL(fileURLWithPath: path, isDirectory: true)) else {
                if let url = BookmarkResolution.resolve(data) { adoptResolvedFolder(url) }
                continue
            }
            let key = path
            pendingResolutions[key] = Task { [weak self] in
                // 起動時・ボリュームの知らせで裏で解決するので、繋ぎに行かない(BookmarkResolution)。
                let url = await FileIO.perform { BookmarkResolution.resolve(data) }
                guard let self, self.resolutionGeneration == generation else { return }
                self.pendingResolutions.removeValue(forKey: key)
                guard let url else { return }
                self.adoptResolvedFolder(url)
            }
        }
    }

    /// 裏で解決したフォルダを開いて一覧へ足す。
    private func adoptResolvedFolder(_ url: URL) {
        let path = url.path
        // 別のブックマーク(同じフォルダを指す古いもの)が先に足していれば何もしない。
        guard !entries.contains(where: { $0.id == path }) else { return }
        if accessedURLsByPath[path] == nil, url.startAccessingSecurityScopedResource() {
            accessedURLsByPath[path] = url
        }
        entries = (entries + [Entry(url: url)]).sorted { $0.url.path < $1.url.path }
        accessGained.send()
    }

    /// 裏の解決がまだ済んでいない許可のうち、`url` を覆いうるもの(`url` の祖先を指すもの)を待つ。
    /// 無ければすぐ戻る。**解決は止められない**(応答しない共有では SMB のタイムアウトまで戻らない)ので、利用者の操作の
    /// 途中で待つ所は `FileIO.withDeadline` で包むこと。
    ///
    /// 起動直後に「同じフォルダの本」を開こうとした・フォルダの許可を確かめた、というときに、裏の解決がまだ済んでいない
    /// だけのフォルダを「許可が無い」としてパネルを出さないために使う(AppState.ensureAccess)。
    func waitForPendingResolutions(covering url: URL) async {
        let tasks = pendingResolutions.filter { key, _ in
            isAncestor(URL(fileURLWithPath: key, isDirectory: true), of: url)
        }.map(\.value)
        for task in tasks { await task.value }
    }

    /// 裏の解決がすべて済むまで待つ(起動時の掃除など、許可の一覧を材料にする裏の仕事の前に。AppStores)。
    /// 上と同じく、応答しない共有があると長く戻らないので、期限で包むこと。
    func waitForPendingResolutions() async {
        for task in Array(pendingResolutions.values) { await task.value }
    }
}

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
    nonisolated struct Entry: Identifiable, Hashable, Sendable {
        let url: URL
        var id: String { url.path }

        /// 一覧に表示する名前。単純にパスの最後の部分を使うと、ボリュームのルートフォルダ
        /// (例:「Macintosh HD」を許可した場合の内部パスは"/")では"/"とだけ表示されてしまい、
        /// どこを指しているか分かりづらい。Finderが表示するのと同じ名前
        /// (`.localizedNameKey`)を優先的に使うことで、ルートフォルダなら「Macintosh HD」、
        /// 通常のフォルダならそのフォルダ名が表示されるようにする。
        ///
        /// **作るときに 1 度だけ求める**(2026-10-04 の監査 ST-16)。以前は環境設定の一覧を描くたびに `resourceValues` を
        /// 引いていて、応答しない共有の許可があるとメインが止まりえた。ネットワークボリュームの上では問い合わせずにパスの
        /// 最後の部分を使う(共有のルートはマウントポイントの名前 = 共有の名前で足りる)。
        let displayName: String

        init(url: URL, mounts: MountTable = .current()) {
            self.url = url
            displayName = Self.displayName(of: url, mounts: mounts)
        }

        static func displayName(of url: URL, mounts: MountTable) -> String {
            if !mounts.isRemote(url), !mounts.isOnAnUnmountedVolume(url),
               let localizedName = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName,
               !localizedName.isEmpty {
                return localizedName
            }
            return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }

        static func == (a: Entry, b: Entry) -> Bool { a.url == b.url }
        func hash(into hasher: inout Hasher) { hasher.combine(url) }
    }

    /// 開いている(解決できてアクセスを始めた)フォルダ。`isPathCovered` はこれだけを見る(解決の済む前は「許可なし」 ――
    /// `reloadInBackground` の ■)。
    @Published private(set) var entries: [Entry] = [] {
        didSet {
            guard entries != oldValue else { return }
            rebuildGrants()
            accessChanged.send()
        }
    }

    /// 保存してある許可 1 件(環境設定「フォルダのアクセス権」の一覧の 1 行。2026-10-04 の監査 ST-3)。
    ///
    /// 以前の一覧は `entries`(解決できて開いたフォルダ)だけを並べたので、外したボリューム・解決中・解決できなかった許可は見えず、
    /// 取り消せなかった(それだけなら「まだどのフォルダにもアクセスを許可していません」と出た)。いまは保存したブックマークから
    /// 作り、状態を添えて、どれでも取り消せる。**ファイルには触らない**(記録したパスはブックマークのデータから読むだけ)。
    nonisolated struct Grant: Identifiable, Hashable, Sendable {
        enum Status: Hashable {
            /// 解決できて、アクセスを開いている。
            case active
            /// 記録したパスのボリュームが繋がっていない(繋げば効く)。
            case notConnected
            /// ネットワークボリュームの上で、裏で解決している最中。
            case resolving
            /// 解決できなかった(消えた・ブックマークが壊れた)。
            case unresolvable
        }

        let bookmarkData: Data
        /// ブックマークに記録したパス(読めなければ nil)。
        let recordedPath: String?
        let status: Status
        /// 開いているフォルダ(`active` のとき)。
        let entry: Entry?
        var id: Data { bookmarkData }

        /// 一覧に出す名前とパス。開いていれば今の場所、そうでなければ記録したパス。
        var displayName: String {
            if let entry { return entry.displayName }
            guard let recordedPath else { return "" }
            let name = (recordedPath as NSString).lastPathComponent
            return name.isEmpty ? recordedPath : name
        }

        var path: String { entry?.url.path ?? recordedPath ?? "" }
    }

    /// 保存してある許可のすべて(`Grant`)。`entries` と保存したブックマーク・裏の解決が変わるたびに作り直す。
    @Published private(set) var grants: [Grant] = []

    /// 開いているフォルダ(`entries`)が変わった(差し替えの**後**に送る)。付与でも取り消しでも送る。ほかの窓の「アクセスを許可…」の
    /// 案内・ツリーの空の行が読み直す契機(2026-10-04 の監査 FBU-5。FileBrowserState.folderAccess)。
    let accessChanged = PassthroughSubject<Void, Never>()

    /// ブックマーク → それを解決して開いたフォルダのパス(`Grant` の状態と、取り消したときに閉じるフォルダを、解決し直さずに知るため)。
    private var resolvedPathByBookmark: [Data: String] = [:]

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
    /// という2つの漏れが同時に起きていた。開閉の管理をこのストアに閉じ、差分だけを開閉する
    /// (足すのは `adoptResolvedFolder`、閉じるのは `close(paths:)` と `reloadInBackground` の外れたボリューム)。
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
    /// 解決の世代。次の裏の解決が始まったら進め、古い解決の結果は捨てる(2026-10-04 の監査 ST-16 で、全部をメインで解決し直す
    /// 同期の `reload()` は無くした ―― 追加・取り消しは記録したパスで照合し、名前の変更は動いたフォルダだけを解決し直す)。
    private var resolutionGeneration = 0

    private var volumeObservers: [NSObjectProtocol] = []

    /// アプリの中で、許可したフォルダ(またはその親)の名前を変えた・移した(AppStores.handleFileSystemChange から)。
    /// 一覧のパスが古いままだと `isPathCovered` が新しいパスを「許可なし」と答えるので、そのフォルダだけ閉じて解決し直す
    /// (ブックマークは移動を追う)。以前は全部のブックマークをメインで解決し直していた(2026-10-04 の監査 ST-16 ―― ローカルの
    /// ものはその場で、ネットワークの上のものは裏で。`reloadInBackground`)。
    func handleFileSystemChange(_ change: FileSystemChange) {
        let moved = Set(entries.filter { change.relocatedPath(for: $0.url.path) != nil }.map(\.id))
        guard !moved.isEmpty else { return }
        close(paths: moved)
        reloadInBackground()
    }

    /// 開いているフォルダを閉じて一覧から外す(取り消し・移動の後。解決はしない)。
    private func close(paths: Set<String>) {
        for path in paths {
            accessedURLsByPath.removeValue(forKey: path)?.stopAccessingSecurityScopedResource()
        }
        resolvedPathByBookmark = resolvedPathByBookmark.filter { !paths.contains($0.value) }
        let kept = entries.filter { !paths.contains($0.id) }
        if kept.count != entries.count { entries = kept }
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

        // 同じパス、または新しく許可するフォルダの配下(子孫)にあたる既存の許可を取り除く。**照合は記録したパスで**(2026-10-04 の
        // 監査 ST-16。以前は全部のブックマークをメインで解決して比べたので、応答しない共有の許可が 1 つあると、追加のたびに止まりえた)。
        // 取り除いた許可で開いていたフォルダも、その配下なので閉じる(新しい許可が覆う)。
        var bookmarks = rawBookmarks()
        let redundant = bookmarks.filter { data in
            guard let recorded = Self.recordedPath(of: data) else { return false }
            return isAncestor(url, of: URL(fileURLWithPath: recorded, isDirectory: true))
        }
        bookmarks.removeAll { redundant.contains($0) }
        bookmarks.append(newData)
        defaults.set(bookmarks, forKey: Self.defaultsKey)
        close(paths: Set(redundant.compactMap { resolvedPathByBookmark[$0] ?? Self.recordedPath(of: $0) }))
        // 新しい許可だけを解決して開く(利用者が今パネルで選んだフォルダなので応答する。呼び出し側とテストは、戻った時点で
        // `isPathCovered` が新しい答えを返すことを当てにしている)。
        // `accessGained`(裏の解決で開いた、の知らせ)は送らない ―― 以前の追加と同じく、起動直後に見送った仕事のやり直しは頼まない
        // (`accessChanged` は送る)。
        let resolved = BookmarkResolution.resolve(newData) ?? url
        adoptResolvedFolder(resolved, from: newData, announcesGain: false)
        rebuildGrants()
        return true
    }

    /// 許可を取り消す(開いているフォルダから)。そのフォルダを開いた許可をすべて取り消す。
    func remove(_ entry: Entry) {
        for grant in grants where grant.entry?.id == entry.id { remove(grant) }
    }

    /// 許可を取り消す(環境設定の一覧の 1 行。開いていない ―― 外したボリューム・解決できない ―― 許可も取り消せる。ST-3)。
    /// 照合はブックマークのデータそのもの(解決しない。ST-16)。開いていたフォルダは、ほかの許可が同じフォルダを開いていなければ閉じる。
    func remove(_ grant: Grant) {
        var bookmarks = rawBookmarks()
        bookmarks.removeAll { $0 == grant.bookmarkData }
        defaults.set(bookmarks, forKey: Self.defaultsKey)
        let openedPath = resolvedPathByBookmark.removeValue(forKey: grant.bookmarkData) ?? grant.entry?.id
        pendingResolutions.removeValue(forKey: grant.recordedPath ?? "")
        if let openedPath, !resolvedPathByBookmark.values.contains(openedPath) {
            close(paths: [openedPath])
        }
        rebuildGrants()
    }

    /// ブックマークに記録したパス(データを読むだけで、ファイルにもボリュームにも触らない)。
    nonisolated static func recordedPath(of data: Data) -> String? {
        URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path
    }

    /// 環境設定の一覧(`grants`)を作り直す。ファイルには触らない(マウント表を読むだけ)。
    private func rebuildGrants() {
        let mounts = MountTable.current()
        let entriesByPath = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let next = rawBookmarks().map { data -> Grant in
            let recorded = Self.recordedPath(of: data)
            if let entry = (resolvedPathByBookmark[data] ?? recorded).flatMap({ entriesByPath[$0] }) {
                return Grant(bookmarkData: data, recordedPath: recorded, status: .active, entry: entry)
            }
            let status: Grant.Status
            if let recorded, mounts.isOnAnUnmountedVolume(URL(fileURLWithPath: recorded, isDirectory: true)) {
                status = .notConnected
            } else if let recorded, pendingResolutions[recorded] != nil {
                status = .resolving
            } else {
                status = .unresolvable
            }
            return Grant(bookmarkData: data, recordedPath: recorded, status: status, entry: nil)
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if next != grants { grants = next }
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

        resolvedPathByBookmark = resolvedPathByBookmark.filter { keptPaths.contains($0.value) }
        defer { rebuildGrants() }
        for data in rawBookmarks() {
            let path = Self.recordedPath(of: data)
            if resolvedPathByBookmark[data] != nil { continue }
            if let path {
                if mounts.isOnAnUnmountedVolume(URL(fileURLWithPath: path, isDirectory: true)) { continue }
                if keptPaths.contains(path) {
                    resolvedPathByBookmark[data] = path
                    continue
                }
            }
            // ネットワークボリューム(MNT_LOCAL でないもの)の上のものだけを裏へ回し、ローカルのものは今までどおりその場で解決する。
            // 止まるのは応答しない共有で、ローカルの解決は数 ms。起動直後の仕事(スマートライブラリの集め直し・ファイルブラウザの
            // 最初の一覧など。どれも許可の一覧を待たずに読みに行く)が、解決の済む前に読んで空の結果を出す・保存するのを、
            // ローカルのフォルダについては今までどおり起こさない(解決の済む前は「許可なし」として扱う ―― 下の ■)。
            // パスを読めないブックマーク(壊れている等)もその場で解決を試す(以前の同期の経路と同じ)。
            guard let path, mounts.isRemote(URL(fileURLWithPath: path, isDirectory: true)) else {
                if let url = BookmarkResolution.resolve(data) { adoptResolvedFolder(url, from: data) }
                continue
            }
            let key = path
            pendingResolutions[key] = Task { [weak self] in
                // 起動時・ボリュームの知らせで裏で解決するので、繋ぎに行かない(BookmarkResolution)。
                // 名前(Entry.displayName)も同じ糸の上で求める(ネットワークの上では問い合わせない ―― Entry のコメント)。
                let entry = await FileIO.perform { BookmarkResolution.resolve(data).map { Entry(url: $0) } }
                // 待つ間に取り消された許可(`remove(_:)` が pendingResolutions から外す)は開かない。
                guard let self, self.resolutionGeneration == generation,
                      self.pendingResolutions.removeValue(forKey: key) != nil else { return }
                guard let entry else { return self.rebuildGrants() }
                self.adoptResolvedFolder(entry.url, from: data, entry: entry)
            }
        }
    }

    /// 解決したフォルダを開いて一覧へ足す。
    private func adoptResolvedFolder(_ url: URL, from data: Data, entry: Entry? = nil, announcesGain: Bool = true) {
        let path = url.path
        resolvedPathByBookmark[data] = path
        // 別のブックマーク(同じフォルダを指す古いもの)が先に足していれば、一覧はそのまま(状態だけ作り直す)。
        guard !entries.contains(where: { $0.id == path }) else { return rebuildGrants() }
        if accessedURLsByPath[path] == nil, url.startAccessingSecurityScopedResource() {
            accessedURLsByPath[path] = url
        }
        entries = (entries + [entry ?? Entry(url: url)]).sorted { $0.url.path < $1.url.path }
        if announcesGain { accessGained.send() }
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

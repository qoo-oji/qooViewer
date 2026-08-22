import Foundation
import Combine
import AppKit

/// 「最近開いたファイルを開く」メニュー、およびサイドパネルの「履歴」モード用に、開いたことの
/// あるフォルダ/アーカイブの履歴を新しい順で保持する。保持件数は環境設定「一般」タブの
/// 「履歴の保存件数」(AppPreferences.recentFilesLimit、既定30件)に従う。
///
/// サンドボックス環境では単なるファイルパスの文字列を保存しても、次回アプリを起動したときに
/// そのURLへアクセスする権限がない(ユーザーが選んだファイルという証跡が失われる)。
/// そのため、パスではなく「セキュリティスコープ付きブックマーク」(bookmarkData)として
/// UserDefaultsに保存し、開くときにブックマークからURLを解決してアクセス許可を得る。
///
/// 【重要】ブックマークの解決(URL(resolvingBookmarkData:))は極めて重い。対象が未接続の外付け/
/// ネットワークボリュームを指していると、解決だけでボリュームの探索を試みて秒単位ブロックしうる。
/// そのためこのストアは、一覧の表示に必要な情報(パス・フォルダかどうか)を解決結果とは別に
/// キャッシュして永続化し、次の形にしている:
///   ・一覧の表示(メニュー・ウェルカム画面・サイドパネル)ではブックマークを一切解決しない
///   ・解決を行うのは、ユーザーが実際にその項目を選んで開くとき(resolveForOpening(_:))だけ
///   ・一覧の再検証は、メニューを開いたときではなく「古くなっている可能性が生まれたとき」
///     (アプリがアクティブになった/ボリュームがマウント・アンマウントされた)に非同期で行う
///
/// バグ修正(ユーザー報告): 以前はメニューが開かれる直前(NSMenu.didBeginTrackingNotification)に
/// 全件を同期で解決・存在確認していた。メニューバーの追跡開始と同じタイミングでメインスレッドを
/// 止めると、AppKitのメニュー更新・検証パスが間に合わず、未完成のメニューがそのまま表示される:
///   ・「ウインドウ」メニューからAppKitが動的に差し込む標準項目(画面全体に表示/中央に配置/
///     移動とサイズ変更/フルスクリーンのタイル表示など)が丸ごと欠ける
///   ・「編集」メニューではカット/コピー/ペーストが検証前の「有効」のまま表示され、欠けた項目
///     ぶん狭い幅で測られるため、自前の項目名が中央省略される
/// メニューバーを直接クリックしたときだけ再現し、別のメニューを開いた状態からカーソルを移動した
/// 場合は再現しない(その時点では最初のメニューで既に1回走り終えており、ファイルシステムの
/// キャッシュも温まっているため間に合う)ことが、原因特定の決め手になった。
@MainActor
final class RecentFilesStore: ObservableObject {
    /// 履歴1件分。一覧の表示に必要な情報はすべてここに入っており、表示のためにブックマークを
    /// 解決する必要はない。実際に開くときだけresolveForOpening(_:)でURLを解決する。
    struct Entry: Identifiable, Hashable, Sendable {
        /// 最後に検証した時点でのパス。表示・重複判定・「今開いている本」との照合に使う。
        let path: String
        /// フォルダかどうか。アイコンの出し分けに使う(記録時・再検証時にキャッシュ済み)。
        let isDirectory: Bool
        /// 開くときにだけ解決するセキュリティスコープ付きブックマーク。
        let bookmark: Data

        var id: String { path }
        var displayName: String {
            URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        /// 表示専用のURL(ファイル名・拡張子の取り出し用)。セキュリティスコープが付いていない
        /// ため、これを使って本を開いてはいけない(開くときは必ずresolveForOpening(_:)を通す)。
        var displayURL: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
    }

    /// UserDefaultsへ保存する形。旧形式(ブックマークデータの配列のみ)からの移行はloadStored()で
    /// 行う。Equatableなのは「再検証の結果が以前と同じなら書き戻さない」判定に使うため。
    private struct StoredEntry: Codable, Equatable, Sendable {
        let bookmark: Data
        /// 解決済みのパスのキャッシュ。旧形式からの移行直後だけ空文字列になりうる
        /// (直後のscheduleRefresh()が解決して埋める)。
        let path: String
        let isDirectory: Bool
    }

    @Published private(set) var entries: [Entry] = []

    /// 履歴として保持する件数。環境設定の値(AppPreferences.recentFilesLimit)をUserDefaultsから
    /// 直接読む(このストアはAppPreferencesを参照しない。理由はAppPreferences.recentFilesLimitの
    /// コメント参照)。設定される前・不正な値の場合は既定値へフォールバックし、範囲外の値は
    /// 丸めておく。
    private var maxCount: Int {
        let stored = UserDefaults.standard.object(forKey: AppPreferences.recentFilesLimitDefaultsKey) as? Double
        let value = stored ?? AppPreferences.defaultRecentFilesLimit
        let range = AppPreferences.recentFilesLimitRange
        return Int(min(max(value, range.lowerBound), range.upperBound))
    }

    /// 新形式(パス等のキャッシュを含む)の保存先。
    private let defaultsKey = "recentBookEntries"
    /// 旧形式(ブックマークデータの配列のみ)の保存先。移行のために読むほか、保存のたびに
    /// 併せて書き続ける(万一古いバージョンのアプリに戻したときに履歴が消えないようにするため)。
    ///
    /// この互換は片道であることに注意。loadStored()は新形式があればそちらを優先するため、
    /// 「古いバージョンへ戻す → そこで本を開く → また新しいバージョンへ上げる」という
    /// 往復をすると、古いバージョンで増えた履歴は読まれずに消える。両方を突き合わせて
    /// 併合することもできるが、順序をどう決めるかに正解が無く、この経路を通る人がまず
    /// いないため、あえて単純なままにしてある。
    private let legacyDefaultsKey = "recentBookBookmarks"

    /// 環境設定で保持件数が変更されたときに、その場で切り詰めるための監視トークン。
    private var limitChangeObserver: NSObjectProtocol?
    /// アプリがアクティブになったときに再検証するための監視トークン。
    private var activationObserver: NSObjectProtocol?
    /// ボリュームのマウント/アンマウントで再検証するための監視トークン(NSWorkspaceの通知)。
    private var volumeObservers: [NSObjectProtocol] = []
    /// 非同期の再検証(scheduleRefresh)が実行中かどうか。前回が終わらないうちに何本も
    /// 走らせないよう間引く。
    private var isRefreshing = false
    /// 再検証の実行中に、次の再検証の要求が来たかどうか。要求を捨てずに1回ぶんだけ覚えておき、
    /// 実行中のものが終わってから走らせる(scheduleRefresh/finishRefresh参照)。
    private var needsAnotherRefresh = false

    init() {
        // 起動時はキャッシュから即座に一覧を作る(ここではファイルアクセスを一切行わない)。
        publish(loadStored())
        // 実体の確認は起動直後に一度だけ、非同期で行う。旧形式からの移行(パスの穴埋め)も
        // ここで完了する。
        scheduleRefresh()

        // 保持件数を減らしたときに、次に本を開くまで古い履歴が残り続けないよう、その場で
        // 切り詰める。これはキャッシュを切るだけなのでファイルアクセスは発生しない。
        // queue: .mainにより実行時には必ずMainActor上で呼ばれるが、クロージャ自体の型は
        // 静的にMainActor隔離だと分からないため、MainActor.assumeIsolatedで明示する
        // (FavoritesStore.swift/ViewerViewModel.swiftの同種のコメント参照。Task {
        // @MainActor in ... }で包むとselfのキャプチャに関する別の警告/エラーになる)。
        limitChangeObserver = NotificationCenter.default.addObserver(
            forName: .recentFilesLimitDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyLimit()
            }
        }

        // 再検証のきっかけ。以前はメニューを開くたびに行っていたが、それがメニュー描画を
        // 止める原因だった(型のコメント参照)。代わりに、一覧が古くなっている可能性が
        // 生まれたタイミングだけを拾う。
        //   ・アプリがアクティブになったとき: 裏でFinderから削除・移動・リネームされた場合
        //   ・ボリュームのマウント/アンマウント: 外付け・ネットワークドライブの抜き差し
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleRefresh()
            }
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleRefresh()
                }
            }
        }
    }

    /// 予防: このストアはアプリ全体で1つ(QooViewerAppの@StateObject)で、実際にはアプリ終了まで
    /// 解放されないため現状これが呼ばれることは無い。ただし購読を登録したまま解除しない形を
    /// 残しておくと、将来ライフサイクルが変わったときに(NotificationCenterがクロージャを
    /// 強参照し続けるため)そのままリークになる。BookmarkStore.deinitと同じ形で対にしておく。
    deinit {
        if let limitChangeObserver {
            NotificationCenter.default.removeObserver(limitChangeObserver)
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in volumeObservers {
            workspaceCenter.removeObserver(observer)
        }
    }

    // MARK: - 記録・取り出し

    /// 本を開くのに成功したときに呼ぶ。履歴の先頭に追加し、同じファイルの重複は取り除く。
    ///
    /// 重複判定はキャッシュ済みのパス同士の比較で行う。以前は保存済みブックマークを1件ずつ
    /// 解決してパスを取り出していたため、本を1冊開くたびに履歴の件数ぶんの解決が走っていた。
    func record(url: URL) {
        var stored = loadStored()
        stored.removeAll { $0.path == url.path }

        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            // isDirectoryはアイコンの出し分けにしか使わないが、URLの末尾スラッシュの有無に
            // 頼ると渡され方によって揺れるため、ここで1回だけ実体に問い合わせて確定させる。
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                ?? url.hasDirectoryPath
            stored.insert(
                StoredEntry(bookmark: data, path: url.path, isDirectory: isDirectory),
                at: 0
            )
        }
        if stored.count > maxCount {
            stored = Array(stored.prefix(maxCount))
        }
        save(stored)
        publish(stored)
    }

    /// 履歴の項目を実際に開くためのURLを解決する。**ここでだけ**セキュリティスコープ付き
    /// ブックマークの解決(重いディスクI/O)を行う。一覧の表示からは絶対に呼ばないこと。
    ///
    /// 実体が失われている場合は、その項目を履歴から取り除いてnilを返す。以前はメニューを
    /// 開くたびに全件の存在確認を行っていたが、その確認こそがメニュー描画を止める原因だった
    /// ため、「実際に開こうとして初めて分かる」形に変えている。ここで確認するのは選ばれた
    /// 1件だけなので、メニュー描画を止めることはない。
    ///
    /// バグ修正: 当初はブックマークの**解決に失敗した場合**だけ取り除いていたが、それでは
    /// 削除済みのファイルが履歴に残り続けた。revalidate(_:)のコメントにもあるとおり、
    /// ブックマークの解決自体は対象が削除されていても成功する場合があるためで、
    /// 「解決はできる → 開こうとして失敗 → 履歴には残ったまま」という状態になっていた。
    /// 解決に加えて実際の存在確認まで行い、どちらで落ちても取り除く。
    func resolveForOpening(_ entry: Entry) -> URL? {
        guard let url = Self.resolvedURL(from: entry.bookmark), Self.fileExists(at: url) else {
            remove(entry)
            return nil
        }
        return url
    }

    /// セキュリティスコープを開いたうえで実体の有無を確認する。
    /// 呼び出し側(resolveForOpening経由で本を開く側)が改めてstartAccessingSecurityScopedResource()を
    /// 呼ぶが、start/stopは呼び出し回数で釣り合っていればよいため、ここで一時的に開いて閉じても
    /// 問題ない(revalidate(_:)の中で行っているのと同じこと)。
    private static func fileExists(at url: URL) -> Bool {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 履歴をすべて消去する(ユーザー要望)。
    ///
    /// 呼び出し元は3箇所 ―― メニューバー「最近開いたファイル」の末尾、サイドパネルの
    /// 履歴モードのゴミ箱ボタン、環境設定「リセット」画面。
    ///
    /// 新旧2つの保存形式を**どちらも**空にする。旧形式(legacyDefaultsKey)は、古い
    /// バージョンのアプリへ戻したときのために書き続けているもので(save(_:)のコメント参照)、
    /// ここで消し忘れると「消したはずの履歴が、古いバージョンで開くと復活する」ことになる。
    func removeAll() {
        // 判定は`entries`ではなく**保存済みのデータ**で行う。`entries`は表示用に絞り込んだ
        // 射影で、旧形式から移行した直後などパスが未解決の項目は除かれている(publish参照)。
        // `entries`が空でも保存済みのデータは残っていることがあり、そこで打ち切ると
        // 「すべて削除」したはずの履歴が次回起動時に復活する。
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: defaultsKey) != nil
            || defaults.object(forKey: legacyDefaultsKey) != nil
        else { return }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        publish([])
    }

    /// 指定の項目を履歴から取り除く。
    private func remove(_ entry: Entry) {
        var stored = loadStored()
        let before = stored.count
        stored.removeAll { $0.bookmark == entry.bookmark }
        guard stored.count != before else { return }
        save(stored)
        publish(stored)
    }

    // MARK: - 永続化

    /// 保存済みの履歴を読む。新形式が無ければ旧形式(ブックマークデータの配列)から移行する。
    /// 移行直後はパスが空のままだが、起動直後のscheduleRefresh()が解決して埋める。
    private func loadStored() -> [StoredEntry] {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([StoredEntry].self, from: data) {
            return decoded
        }
        let legacy = UserDefaults.standard.array(forKey: legacyDefaultsKey) as? [Data] ?? []
        return legacy.map { StoredEntry(bookmark: $0, path: "", isDirectory: false) }
    }

    private func save(_ stored: [StoredEntry]) {
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        // 旧バージョンのアプリに戻した場合でも履歴が残るよう、旧形式も併せて更新しておく。
        UserDefaults.standard.set(stored.map(\.bookmark), forKey: legacyDefaultsKey)
    }

    /// キャッシュから@Publishedの一覧を作る。ファイルアクセスは行わない。
    private func publish(_ stored: [StoredEntry]) {
        // パスが空のもの(旧形式から移行した直後で、まだ解決できていないもの)は表示しない。
        //
        // 同じパスが2件出てこないようにもする。record(url:)の重複判定はキャッシュ済みのパス
        // 同士の比較なので、パスが古いままの項目が残っている状態で同じ実体を開くと、
        // 別々の項目として2件入りうる。その後の再検証で両方が同じ新しいパスへ更新されると、
        // Entry.id(=path)が重複したままForEachへ渡ることになり、SwiftUIでは未定義の挙動になる。
        var seenPaths: Set<String> = []
        let newEntries = stored
            .filter { !$0.path.isEmpty && seenPaths.insert($0.path).inserted }
            .map { Entry(path: $0.path, isDirectory: $0.isDirectory, bookmark: $0.bookmark) }
        // バグ修正(ユーザー報告): @Publishedは値が同じでも代入のたびにobjectWillChangeを
        // 発火する。メニューバーが開かれている最中に発火すると、SwiftUIがメニューバーを
        // 組み立て直してAppKitのメニュー更新と競合するため、中身が変わったときだけ代入する。
        //
        // さらに、中身が実際に変わる場合は**メニューバーのメニューが開いている間は保留する**。
        // この一覧は「最近開いたファイル」メニューの項目数そのもの(「(なし)」1項目 ↔ N項目)に
        // なるうえ、本を開き終えた瞬間(record(url:))やボリュームのマウント(scheduleRefresh())と
        // いった、ユーザーのメニュー操作とは無関係なタイミングで変わる。開いている最中に
        // 項目数が変わるとmacOS 26ではメニューの再構築でアプリが落ちる
        // (詳細はMenuBarMenuGateの型コメント参照)。
        guard newEntries != entries else { return }
        MenuBarMenuGate.shared.run("RecentFilesStore.entries") { [weak self] in
            guard let self, newEntries != self.entries else { return }
            self.entries = newEntries
        }
    }

    /// 保持件数が減らされたときの切り詰め。キャッシュを切るだけでファイルアクセスは不要。
    private func applyLimit() {
        var stored = loadStored()
        guard stored.count > maxCount else { return }
        stored = Array(stored.prefix(maxCount))
        save(stored)
        publish(stored)
    }

    // MARK: - 再検証(非同期)

    /// 実体の存在確認とパスのキャッシュ更新を非同期に予約する。重い部分(revalidate)だけを
    /// メインアクターの外で走らせ、一覧への反映はメインアクターへ戻してから行う。
    private func scheduleRefresh() {
        guard !isRefreshing else {
            // 走行中に来た要求は捨てずに覚えておき、完了後にもう一度走らせる。
            // 以前はここで単に捨てていたため、再検証の最中に外付けドライブをマウントすると、
            // 次にアプリがアクティブになるまで一覧が古いままだった。
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true
        let snapshot = loadStored()
        guard !snapshot.isEmpty else {
            isRefreshing = false
            return
        }
        // [weak self]で受けたselfを、awaitをまたぐ前にguard letで強参照へ変換しておく
        // (そのまま参照するとSwift 6の並行性チェックで「Reference to captured var 'self' in
        // concurrently-executing code」になる。QooViewerApp.swiftの
        // applicationDidFinishLaunchingにある同種のコメント参照)。
        Task.detached(priority: .utility) { [weak self] in
            let refreshed = Self.revalidate(snapshot)
            guard let self else { return }
            await self.finishRefresh(refreshed, snapshot: snapshot)
        }
    }

    /// revalidate()の結果をメインアクター上で反映し、多重起動の抑止を解除する。
    /// 走行中に来ていた要求(needsAnotherRefresh)があれば、最後にもう一度走らせる。
    private func finishRefresh(_ refreshed: [StoredEntry], snapshot: [StoredEntry]) {
        isRefreshing = false
        defer {
            if needsAnotherRefresh {
                needsAnotherRefresh = false
                scheduleRefresh()
            }
        }
        // 再検証はメインアクターの外で走るため、その最中にrecord(url:)が新しい履歴を保存して
        // いることがありうる。その場合に古い結果を書き戻すと、いま追加したばかりの履歴を
        // 消してしまうため、開始時点と保存内容(ブックマークの並び)が変わっていないときだけ
        // 反映する。パスではなくブックマークで比べるのは、旧形式からの移行(パスが空→解決済み)
        // でも同一と判定できるようにするため。
        //
        // 捨てた場合はやり直しを予約する。そうしないと、この一度の取りこぼしがそのまま
        // 「次にアプリがアクティブになるまで検証されない」ことになる。
        guard loadStored().map(\.bookmark) == snapshot.map(\.bookmark) else {
            needsAnotherRefresh = true
            return
        }

        var result = refreshed
        if result.count > maxCount {
            result = Array(result.prefix(maxCount))
        }
        // 実体にもパスにも変化が無ければ、UserDefaultsへの書き戻しごと省く。
        if result != snapshot {
            save(result)
        }
        publish(result)
    }

    /// 保存済みの各件についてブックマークを解決し、実体がまだ存在するものだけを、最新のパス・
    /// 種別付きで返す。解決できたがファイルが存在しないもの・解決自体に失敗したものは落とす
    /// (そのままにしておくと、二度と復活しない無駄なデータが残り続けるため)。
    ///
    /// 1件ごとにセキュリティスコープ付きブックマークの解決と存在確認(ディスクI/O)が発生し、
    /// 対象が未接続の外付け/ネットワークボリュームを指している場合は解決だけで秒単位ブロック
    /// しうる。メインアクターの外(scheduleRefresh()のTask.detached)から呼べるよう`nonisolated`を
    /// 明示している(このプロジェクトの既定のアクター隔離はMainActorのため、明示しないと
    /// メインアクター限定になってしまう。Services/ArchiveReading.swift冒頭のコメント参照)。
    private nonisolated static func revalidate(_ stored: [StoredEntry]) -> [StoredEntry] {
        var result: [StoredEntry] = []
        for item in stored {
            guard let url = resolvedURL(from: item.bookmark) else { continue }
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            // ブックマークデータの解決自体は、対象が削除されていても成功する場合があるため、
            // 実際の存在確認が別途必要になる。ついでに種別(フォルダかどうか)も更新する。
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            // ブックマークは実体を追跡するため、リネーム・移動されていた場合はここで新しい
            // パスに更新される(表示名が古いままにならない)。
            result.append(
                StoredEntry(bookmark: item.bookmark, path: url.path, isDirectory: isDirectory.boolValue)
            )
        }
        return result
    }

    private nonisolated static func resolvedURL(from data: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}

extension Notification.Name {
    /// 環境設定「履歴の保存件数」が変更されたことをRecentFilesStoreへ知らせる通知
    /// (AppPreferences.recentFilesLimitのdidSetから送られる)。
    static let recentFilesLimitDidChange = Notification.Name("qooViewer.recentFilesLimitDidChange")
}

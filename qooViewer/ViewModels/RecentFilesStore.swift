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
@MainActor
final class RecentFilesStore: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let url: URL
        var id: String { url.path }
        var displayName: String { url.deletingPathExtension().lastPathComponent }
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
    private let defaultsKey = "recentBookBookmarks"
    /// メニューが開かれる直前に一覧を再チェックするための監視トークン。
    private var menuTrackingObserver: NSObjectProtocol?
    /// 環境設定で保持件数が変更されたときに、その場で切り詰めるための監視トークン。
    private var limitChangeObserver: NSObjectProtocol?

    init() {
        reload()
        // 保持件数を減らしたときに、次に本を開くまで古い履歴が残り続けないよう、その場で
        // 一覧を作り直す(reload()側でmaxCountまで切り詰められる)。menuTrackingObserverと
        // 同じ理由でMainActor.assumeIsolatedを使う。
        limitChangeObserver = NotificationCenter.default.addObserver(
            forName: .recentFilesLimitDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
            }
        }
        // 「最近使ったファイル」メニューを表示する直前に、削除・移動・リネームされていた
        // ファイルが一覧に残ったままにならないよう再チェックする。特定のメニュー(File)
        // だけに絞り込む簡単な方法がないため、このアプリ内でどのメニューが開かれても
        // 再チェックする(ファイルの存在確認は軽い処理なので負荷は問題にならない)。
        // queue: .mainにより実行時には必ずMainActor上で呼ばれるが、クロージャ自体の型は
        // 静的にMainActor隔離だと分からないため、MainActor.assumeIsolatedで明示する
        // (FavoritesStore.swift/ViewerViewModel.swiftの同種のコメント参照。Task {
        // @MainActor in ... }で包むとselfのキャプチャに関する別の警告/エラーになる)。
        menuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                // メニューバーのメニュー以外では何もしない。このreload()は履歴1件ごとに
                // セキュリティスコープ付きブックマークの解決とファイル存在確認(ディスクI/O)を
                // 行うため、ウインドウ内のドロップダウンを開くたびに走らせると体感できる遅延に
                // なる(詳細はMenuBarTracking.isMainMenu(_:)のコメント参照)。
                guard MenuBarTracking.isMainMenu(notification) else { return }
                self?.reload()
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
        if let menuTrackingObserver {
            NotificationCenter.default.removeObserver(menuTrackingObserver)
        }
    }

    /// 本を開くのに成功したときに呼ぶ。履歴の先頭に追加し、同じファイルの重複は取り除く。
    func record(url: URL) {
        var bookmarks = rawBookmarks()
        bookmarks.removeAll { resolvedURL(from: $0)?.path == url.path }

        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            bookmarks.insert(data, at: 0)
        }
        if bookmarks.count > maxCount {
            bookmarks = Array(bookmarks.prefix(maxCount))
        }
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
        reload()
    }

    private func rawBookmarks() -> [Data] {
        UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
    }

    private func resolvedURL(from data: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// 保存済みのブックマークからURL一覧を解決し直す。ブックマークデータ自体が解決できた場合でも、
    /// 実際にそのファイル/フォルダがまだ存在するか(削除・移動・リネームされていないか)を
    /// 別途確認し、存在しないものは一覧に表示しない。存在しなくなったブックマークは保存データ
    /// 自体からも取り除く(そのままにしておくと、二度と復活しない無駄なデータが残り続けるため)。
    private func reload() {
        let bookmarks = rawBookmarks()
        var survivingBookmarks: [Data] = []
        var newEntries: [Entry] = []
        for data in bookmarks {
            guard let url = resolvedURL(from: data), fileStillExists(at: url) else { continue }
            survivingBookmarks.append(data)
            newEntries.append(Entry(url: url))
        }
        // 環境設定で保持件数を減らした場合は、ここで超過分を捨てる(record(url:)側の
        // 切り詰めだけだと、次に本を開くまで古い履歴が残ってしまうため)。
        if survivingBookmarks.count > maxCount {
            survivingBookmarks = Array(survivingBookmarks.prefix(maxCount))
            newEntries = Array(newEntries.prefix(maxCount))
        }
        entries = newEntries
        if survivingBookmarks.count != bookmarks.count {
            UserDefaults.standard.set(survivingBookmarks, forKey: defaultsKey)
        }
    }

    /// セキュリティスコープ付きのURLが指すファイル/フォルダが、実際にまだ存在するかどうかを
    /// 確認する。ブックマークデータの解決(resolvedURL)自体は、対象が削除されていても
    /// 成功する場合があるため、この実際の存在確認が必要になる。
    private func fileStillExists(at url: URL) -> Bool {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

extension Notification.Name {
    /// 環境設定「履歴の保存件数」が変更されたことをRecentFilesStoreへ知らせる通知
    /// (AppPreferences.recentFilesLimitのdidSetから送られる)。
    static let recentFilesLimitDidChange = Notification.Name("qooViewer.recentFilesLimitDidChange")
}

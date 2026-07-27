import Foundation

/// 「起動時に前回開いていた本を自動的に開く」設定のために、直前にアクティブだった
/// ウインドウ/タブが表示していた本のURLを記録しておく仕組み。
///
/// すべてのウインドウ・タブを復元するわけではなく、終了時にアクティブだった1つの本だけを
/// 対象にする。そのため、キーウインドウになった/本を切り替えた、といったタイミングの
/// たびに記録を更新しておき、「最後にアクティブだった状態」が常にここに反映されるようにする
/// (ContentView.swiftのobserveWindowBecameKey/onChange(of: appState.currentBook)参照)。
/// アプリの終了時に何か特別な処理をする必要はない(終了時点で最後に記録された内容が
/// そのまま使われる)。
///
/// サンドボックス環境では単なるファイルパスの文字列を保存しても、次回アプリを起動したときに
/// そのURLへアクセスする権限がない。そのため、RecentFilesStoreと同じく
/// 「セキュリティスコープ付きブックマーク」(bookmarkData)としてUserDefaultsに保存する。
enum LastActiveBookStore {
    private static let defaultsKey = "qooViewer.lastActiveBookBookmark"

    /// アクティブなウインドウ/タブが表示している本が変わったとき、またはそのウインドウが
    /// キーウインドウになったときに呼ぶ。
    static func record(url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// アクティブなウインドウ/タブが「何も本を開いていない状態(ウェルカム画面)」になった
    /// ときに呼ぶ。記録をクリアすることで、次回起動時に誤って本を復元してしまわないようにする
    /// (終了時にウェルカム画面を見ていたなら、次回もウェルカム画面から始まるのが正しい)。
    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// 保存されているブックマークからURLを解決する。ブックマークが存在しない場合や、
    /// 指しているファイル/フォルダが実際にはもう存在しない(削除・移動された)場合はnilを返す。
    /// 内容が変わっていないかどうかまではここでは確認しない(呼び出し元のContentView.swift
    /// resolveLastActiveBookURLIfUnchanged参照。BookReadingStateの指紋と比較する必要があり、
    /// SwiftDataのModelContextを使うため、ここでは行わない)。
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

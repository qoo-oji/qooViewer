import Foundation

/// qooViewerが作る一時ファイル(入れ子になった書庫の展開物)の置き場所と、その後始末。
///
/// ■ なぜ専用の仕組みが要るのか
/// 入れ子の書庫(書庫の中の書庫・フォルダの中に並んだ書庫)を1冊として開くとき、rar/7zの
/// ライブラリがファイルパスを要求するため、中の書庫をいったん一時ファイルへ書き出す
/// (BookLoader.collectPages / BookContentsBrowserState.openNestedArchive参照)。その削除は
/// BookTemporaryResources / BookContentsBrowserStateの`deinit`に任せてあったが、
/// **本を開いたままアプリを終了すると`deinit`は走らない**(プロセスがそのまま消える)ため、
/// 終了のたびに数百MB〜1GB超の書庫が`~/Library/Containers/<bundle id>/Data/tmp`へ
/// 残り続けていた。実際に、11日ぶん・120個・8.4GBが溜まっているのを確認した。
/// OSはサンドボックスのこのディレクトリを自動では掃除しない(11日前のファイルが残っていた)。
///
/// ■ 三段構え
/// 1. 一時ファイルはすべて**起動ごとのサブディレクトリ**(`tmp/qooViewer-<pid>/`)に置く。
///    どのファイルがどのプロセスのものかが名前だけで分かる。
/// 2. 起動時に`removeStaleSessionDirectories()`で、**生きていないプロセスのサブディレクトリ**を
///    まとめて削除する。クラッシュ・強制終了・停電など、どんな終わり方をしても次の起動で
///    片付く。以前の版が`tmp/`直下へ直接書いていた`<UUID>.<書庫拡張子>`も同時に片付ける。
/// 3. 正常終了時は`removeSessionDirectory()`(AppDelegate.applicationWillTerminate)で自分の
///    ぶんをその場で消す。次回起動を待たずに空く。
///
/// 本を閉じたときの`deinit`による個別削除はそのまま残してある(長く起動したままの利用では
/// そちらが主役で、ここは取りこぼしを拾う網)。
///
/// nonisolated: BookLoader(Task.detached内)とBookContentsBrowserState(MainActor)の両方から
/// 使うため(ArchiveReading.swift冒頭のコメント参照)。状態を持たないので隔離は要らない。
nonisolated enum TemporaryFileStore {
    private static let sessionDirectoryPrefix = "qooViewer-"

    /// このプロセス専用のディレクトリ。初回のmakeFileURL(extension:)で作られる。
    static let sessionDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(sessionDirectoryPrefix)\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    /// 一時ファイルの置き場所を1つ払い出す(ファイル自体はまだ作らない)。
    /// セッションのディレクトリが無ければここで作る。作成に失敗した場合は、呼び出し側の
    /// `Data.write(to:)`が失敗してその入れ子の書庫が飛ばされるだけで、他には影響しない
    /// (従来の、`tmp/`直下への書き込みに失敗した場合と同じ扱い)。
    static func makeFileURL(extension ext: String) -> URL {
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        return sessionDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    /// 自分のセッションのディレクトリを丸ごと消す(正常終了時)。
    static func removeSessionDirectory() {
        try? FileManager.default.removeItem(at: sessionDirectory)
    }

    /// 他のセッションが残した一時ファイルを消す(起動時)。
    ///
    /// - `qooViewer-<pid>/`: そのpidのプロセスが生きていなければ消す。生きているかどうかは
    ///   `kill(pid, 0)`で判定する(シグナルは送らない。成功、または権限エラー(EPERM)なら
    ///   存在している)。pidが別のプロセスに再利用されていた場合は「生きている」と見なして
    ///   消さないが、その場合も次回以降の起動で消える。安全側に倒す。
    /// - `tmp/`直下の`<UUID>.<書庫拡張子>`: セッションディレクトリを導入する前の版が
    ///   残したもの。現在の版はこの形で書かないので、見つかれば必ず残骸。
    ///
    /// ディレクトリの列挙と削除を伴うため、メインスレッドで呼ばないこと
    /// (AppDelegate側でTask.detachedへ逃がしている)。
    static func removeStaleSessionDirectories() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for entry in entries {
            let name = entry.lastPathComponent
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if isDirectory, name.hasPrefix(sessionDirectoryPrefix) {
                guard let pid = pid_t(name.dropFirst(sessionDirectoryPrefix.count)),
                      pid != ownPID, !isProcessAlive(pid)
                else { continue }
                try? fileManager.removeItem(at: entry)
            } else if !isDirectory, isLegacyTemporaryArchive(name) {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// 以前の版が`tmp/`直下へ書いていた一時ファイルの名前か(`<UUID>.<書庫拡張子>`)。
    /// UUIDの形を厳密に見るのは、このディレクトリにある他のもの(OSの`TemporaryItems`、
    /// 状態復元の`savedState`、診断ログ等)を巻き込まないため。
    private static func isLegacyTemporaryArchive(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        return isArchiveFile(name) && UUID(uuidString: stem) != nil
    }
}

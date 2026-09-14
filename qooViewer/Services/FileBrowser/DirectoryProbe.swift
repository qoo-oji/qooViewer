import Foundation

/// ファイルブラウザのツリーで、行に開閉の三角を出すかを決める「直下にサブフォルダがあるか」の問い合わせ
/// (2026-09-13、ユーザー要望。qooLibrary の `DirectoryProbe.hasSubdirectory` を写したもの)。
///
/// **FileIO の上で呼ぶこと。** 応答しない共有では `opendir(3)` の時点で止まる(呼び出し側はネットワーク越しの
/// 場所をそもそも調べない ―― `MountTable.isRemote`)。
///
/// ■ 段階3で「調べない」にしていた理由と、それをどう避けるか
/// 三角のために子フォルダの中を読むと、(1) TCC の保護下の場所で許可のダイアログが出る、(2) ネットワークでは
/// 行の数だけ往復する。qooLibrary は (1) をパスの文字列だけで保護下の場所を除外し、(2) をマウント表で除外して
/// 解いていた。判定できないとき(除外・読めない)は nil を返し、呼び出し側は**三角を出す** ―― 誤って消すと
/// 開けるはずのフォルダが行き止まりになるが、誤って出しても「開いたら空だった」で済む。
nonisolated enum DirectoryProbe {
    /// 直下に、ツリーに出るフォルダ(隠しでない・パッケージでない・記号リンクでない)が 1 つでもあるか。
    /// 判定できなければ nil。
    ///
    /// `readdir(3)` を最初のサブフォルダで打ち切る。`d_type` を見れば 1 件ごとの `stat` が要らないので、
    /// `contentsOfDirectory` + `resourceValues` より桁で速い(qooLibrary 実測: 2,000 件で 0.89ms 対 4.66ms)。
    /// ディレクトリの `st_nlink` や `.directoryEntryCount` は APFS では全エントリ数で、フォルダの数ではない
    /// (同実測)ので、これより安い手段は無い。
    ///
    /// **数える規則はツリーの一覧(`FileBrowserListing.entries` → `isNavigableFolder`)と揃える**:
    /// - 名前が `.` で始まる項目と `UF_HIDDEN` の項目は数えない(`.skipsHiddenFiles` はどちらも隠す。qooLibrary では
    ///   `UF_HIDDEN` を見落として「空なのに三角が出る」になった)
    /// - パッケージは数えない(ツリーに出さない)
    /// - 記号リンクは数えない(一覧の `.isDirectoryKey` はリンク自身を見るので、ツリーに出ない)
    static func hasSubdirectory(at url: URL, protectedPrefixes: [String] = protectedPrefixes) -> Bool? {
        if isPrivacyProtected(url, prefixes: protectedPrefixes) { return nil }
        guard let directory = opendir(url.path) else { return nil }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            var value = entry.pointee
            let name = withUnsafePointer(to: &value.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name.hasPrefix(".") { continue }
            let type = Int32(value.d_type)
            let child = url.appendingPathComponent(name)
            var status = stat()
            switch type {
            case DT_DIR:
                // UF_HIDDEN を見るための lstat。引けなければ隠れていない側へ倒す(型コメントの害の非対称)。
                if lstat(child.path, &status) == 0, status.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
            case DT_UNKNOWN:
                // d_type を返さないファイルシステムのための保険。リンクは辿らない(lstat)。
                guard lstat(child.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
                      status.st_flags & UInt32(UF_HIDDEN) == 0
                else { continue }
            default:
                continue
            }
            if !isPackage(child) { return true }
        }
        return false
    }

    /// Finder が 1 つの項目として扱うディレクトリか。引けなければ「パッケージではない」に倒す。
    private static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    }

    /// TCC の許可を要する場所(またはその中)か。**ファイルシステムに一切問い合わせない**(パスの文字列だけ)。
    static func isPrivacyProtected(_ url: URL, prefixes: [String] = protectedPrefixes) -> Bool {
        let path = comparablePath(url)
        return prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// `url` を含む保護下の場所(いちばん長く一致するもの)。保護下でなければ nil。ファイルシステムには触れない。
    /// ファイルブラウザの絵が「いま見ているフォルダと同じ保護下の場所か」を比べるのに使う(段階 7a)。
    static func protectedPrefix(containing url: URL, prefixes: [String] = protectedPrefixes) -> String? {
        let path = comparablePath(url)
        return prefixes.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
    }

    /// 自分から(利用者が入っていないのに)`child` の中を読んでよいか。`child` が保護下の場所なら、`parent` も同じ保護下の場所にあるとき
    /// だけ(利用者がそこへ入っている = 許可は済んでいる)。ファイルシステムには触れない。
    static func mayReadChild(_ child: URL, of parent: URL, prefixes: [String] = protectedPrefixes) -> Bool {
        guard let prefix = protectedPrefix(containing: child, prefixes: prefixes) else { return true }
        return protectedPrefix(containing: parent, prefixes: prefixes) == prefix
    }

    /// 比べる形のパス。**起動ボリュームのデータ側の書き方(`FileBrowserState.dataVolumePrefix` を頭に付けたホーム)も頭を外して揃える**
    /// (2026-09-14 の 2 回目の監査 23。以前はその書き方のホームが保護下の一覧を素通りし、`/` をよく使う項目に登録すると
    /// 動画の先読み役が保護下へ入った)。
    private static func comparablePath(_ url: URL) -> String {
        MountTable.normalized(FileBrowserState.pathOutsideDataVolume(url.path))
    }

    /// 保護下の場所のうち、**許可が場所ごと 1 回で済む**もの(デスクトップ・書類・ダウンロード)。中へ入って許可を済ませれば、
    /// その中のどのフォルダを読んでも新しい確認は出ない。`~/Library` の中の他のアプリのデータは、アプリごとに確認が出うるので
    /// ここには入れない(ファイルブラウザの絵が、いま見ているフォルダと同じ場所なら中を読んでよい、と判断するのに使う。段階 7a)。
    static let categoryProtectedPrefixes: Set<String> = {
        let home = MountTable.normalized(FileBrowserListing.realHomeDirectory().path)
        return [home + "/Desktop", home + "/Documents", home + "/Downloads"]
    }()

    /// 保護下の場所。実際のホームから組み立てる(サンドボックスの `homeDirectoryForCurrentUser` はコンテナ)。
    ///
    /// qooLibrary の一覧(`~/Library` の中の他アプリのデータ・File Provider の置き場など。`~/Library` を開いただけで
    /// 許可のダイアログが次々に出た実測から)に、**デスクトップ・書類・ダウンロードを足した**。qooViewer はホームの
    /// 読み取りを許可してもらって一覧するので、ホームを開いた時点でこの 3 つの中を読むと、利用者が入ってもいないのに
    /// TCC のダイアログが出る(段階3の約束「入ったときだけ 1 回出る」を破る)。qooLibrary は許可の無い場所として
    /// `opendir` が失敗するのに任せていた。
    static let protectedPrefixes: [String] = {
        let home = MountTable.normalized(FileBrowserListing.realHomeDirectory().path)
        let library = home + "/Library"
        return [
            home + "/Desktop",
            home + "/Documents",
            home + "/Downloads",
            library + "/CloudStorage",
            library + "/Mobile Documents",
            library + "/Containers",
            library + "/Group Containers",
            library + "/Application Support",
            library + "/Mail",
            library + "/Safari",
            library + "/Messages",
            library + "/Cookies",
            library + "/IdentityServices",
            library + "/HomeKit",
            library + "/Suggestions",
            library + "/Metadata/CoreSpotlight",
        ]
    }()
}

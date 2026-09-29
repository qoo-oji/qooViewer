import Foundation

/// 記号リンク・Finder のエイリアスの**先**を決める(2026-09-29。docs/15「記号リンクとエイリアスの先」)。
///
/// 使う側は 2 つ:
/// - **裏の仕事**(アイコン・中の絵・クイックルック・一覧の先の控え `FileBrowserState.linkTargets`): `background…`。
///   触ってよい場所(ネットワーク越し・繋がっていないボリューム・TCC の保護下でない。`DirectoryProbe.mayReadUnentered`)だけを、
///   **段ごとに確かめてから** lstat する。断られたら nil。
/// - **利用者の操作**(開く・新規タブ・コレクション・展開・このアプリケーションで開く): `opening…`。Finder と同じくどこへでも行く
///   (エイリアスの解決はマウントもする。ダイアログは出さない)。
///
/// ■ 先の決め方(2026-09-29 実測)
/// `NSWorkspace.icon(forFile:)` や `QLPreviewPanel` にリンクの URL を渡しても先は解かれない(エイリアスは先がフォルダ・アプリのときしか
/// 解かれず、先がファイルなら白紙)。そこでどちらも**先のパスを自分で、先に触らずに**決める ―― 記号リンクは `readlink` の字面を解き
/// (`symbolicLinkTarget`。`standardizingPath` は `..` を実体で解こうとして先に触る)、エイリアスはブックマークデータに記録されたパスを
/// 読む(`URL.resourceValues(forKeys:fromBookmarkData:)`)。記録されたパスに何も無いときだけブックマークを解く(同じボリュームの中を
/// ファイル ID で追う。`BookmarkResolution` は使わない: あれはアプリが保存したセキュリティスコープ付きのブックマーク用で、エイリアス
/// ファイルのブックマークにスコープは無い)。そのパスを**段ごとに** `mayRead` で確かめてから lstat し、途中の記号リンクも追う
/// (`followingSymbolicLinks`。字面だけで判断すると `~/nas → /Volumes/NAS` のようなローカルの記号リンクを経由する先を「ローカル」と
/// 読み違え、`icon(forFile:)` が応答しない共有で 30 秒待った ―― レビュー 2026-09-29)。先がさらにエイリアスのファイルなら追う
/// (`maxAliasHops` 段まで。輪は諦める)。
///
/// **FileIO の上で呼ぶ**(リンク自身と、先の各段の lstat。`opening…` は応答しない共有で待ちうる ―― 利用者の操作なので構わないが、
/// メインでは呼ばない)。
nonisolated enum FileBrowserLinkResolver {
    /// 先と、その項目として扱うのに要る属性(先の stat 1 回)。
    struct Target: Sendable {
        let url: URL
        /// 先が在るか(無ければ種類も絵も無い。開く側は「見つからない」として鳴らす)。
        let exists: Bool
        let isDirectory: Bool
        let isPackage: Bool
        /// 先がさらにエイリアスのファイルか。`target(of:)` はエイリアスの鎖を追い切れなければ nil を返すので、ここは通常 false
        /// (`entry` の形を一覧の行と揃えるために持つ)。
        let isAliasFile: Bool
        let fileSize: Int64?
        let modificationDate: Date?

        /// 先の項目の行(一覧の `FileBrowserListing.makeEntry` と同じ形。種類の説明は要らないので nil)。
        var entry: FileBrowserEntry {
            FileBrowserEntry(
                url: url, displayName: url.lastPathComponent, isDirectory: isDirectory, isPackage: isPackage,
                isSymbolicLink: false, isVolume: false, fileSize: fileSize, typeDescription: nil, creationDate: nil,
                modificationDate: modificationDate, isHidden: false, isAliasFile: isAliasFile
            )
        }
    }

    static let maxAliasHops = 8

    // MARK: - 裏の仕事(触ってよい場所だけ)

    /// 記号リンク・エイリアス `url` の先。触ってよい場所(型コメント)を段ごとに確かめながら追い、途中で断れば nil。
    /// - Parameter currentFolder: 利用者が見ているフォルダ。先がデスクトップ・書類・ダウンロードの中なら、同じ場所の中を
    ///   見ているときだけ読む(フォルダの絵と同じ規則)。
    static func backgroundTarget(
        of url: URL, currentFolder: URL?, mountTable: MountTable,
        protectedPrefixes: [String] = DirectoryProbe.protectedPrefixes,
        categoryPrefixes: Set<String> = DirectoryProbe.categoryProtectedPrefixes
    ) -> URL? {
        target(of: url, bookmarkOptions: [.withoutUI, .withoutMounting]) { target in
            // ネットワーク越し・繋がっていないボリューム(`/Volumes/<名前>` が表に無い。触ると自動マウントや 30 秒の待ちになりうる)・
            // TCC の保護下(見ている場所と同じデスクトップ等の中を除く)は断る。**触らずに**決める。
            !mountTable.isOnAnUnmountedVolume(target)
                && DirectoryProbe.mayReadUnentered(
                    target, from: currentFolder, mountTable: mountTable,
                    prefixes: protectedPrefixes, categoryPrefixes: categoryPrefixes
                )
        }
    }

    /// `backgroundTarget` に先の stat 1 回を足したもの。
    static func backgroundTargetInfo(
        of url: URL, currentFolder: URL?, mountTable: MountTable,
        protectedPrefixes: [String] = DirectoryProbe.protectedPrefixes,
        categoryPrefixes: Set<String> = DirectoryProbe.categoryProtectedPrefixes
    ) -> Target? {
        backgroundTarget(
            of: url, currentFolder: currentFolder, mountTable: mountTable,
            protectedPrefixes: protectedPrefixes, categoryPrefixes: categoryPrefixes
        ).map(info(of:))
    }

    // MARK: - 利用者の操作(どこへでも)

    /// 記号リンク・エイリアス `url` の先。場所は選ばない(Finder と同じ)。記号リンク・エイリアスでなければ nil。
    static func openingTarget(of url: URL) -> URL? {
        target(of: url, bookmarkOptions: [.withoutUI]) { _ in true }
    }

    /// `openingTarget` に先の stat 1 回を足したもの。
    static func openingTargetInfo(of url: URL) -> Target? {
        openingTarget(of: url).map(info(of:))
    }

    // MARK: - 下請け

    private static func info(of target: URL) -> Target {
        let values = try? target.resourceValues(forKeys: [
            .isDirectoryKey, .isPackageKey, .isAliasFileKey, .isSymbolicLinkKey, .totalFileSizeKey, .fileSizeKey,
            .contentModificationDateKey,
        ])
        let isDirectory = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false
        return Target(
            url: target, exists: values != nil, isDirectory: isDirectory, isPackage: isPackage,
            isAliasFile: values?.isAliasFile == true && values?.isSymbolicLink != true,
            fileSize: isDirectory && !isPackage ? nil : (values?.totalFileSize ?? values?.fileSize).map(Int64.init),
            modificationDate: values?.contentModificationDate
        )
    }

    /// 先がさらにエイリアスのファイルなら追う(記号リンクは `followingSymbolicLinks` が解く)。
    private static func target(
        of url: URL, bookmarkOptions: URL.BookmarkResolutionOptions, mayRead: (URL) -> Bool
    ) -> URL? {
        var current = url
        for _ in 0..<maxAliasHops {
            guard let target = targetOnce(of: current, bookmarkOptions: bookmarkOptions, mayRead: mayRead) else { return nil }
            // 触ってよい先(mayRead 済み)の stat 1 回。
            let values = try? target.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
            guard values?.isAliasFile == true, values?.isSymbolicLink != true else { return target }
            current = target
        }
        return nil
    }

    private static func targetOnce(
        of url: URL, bookmarkOptions: URL.BookmarkResolutionOptions, mayRead: (URL) -> Bool
    ) -> URL? {
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            return followingSymbolicLinks(symbolicLinkTarget(destination, linkAt: url), mayRead: mayRead)
        }
        guard let data = try? URL.bookmarkData(withContentsOf: url),
              let recorded = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path,
              let recordedTarget = followingSymbolicLinks(URL(fileURLWithPath: recorded), mayRead: mayRead)
        else { return nil }
        if FileManager.default.fileExists(atPath: recordedTarget.path) { return recordedTarget }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data, options: bookmarkOptions, relativeTo: nil, bookmarkDataIsStale: &isStale
        ) else { return nil }
        return followingSymbolicLinks(resolved, mayRead: mayRead)
    }

    /// `path` の各段を、`mayRead` で確かめてから lstat し、記号リンクなら先(字面)に差し替えて先頭からやり直す。
    /// 記号リンクの無い絶対パスになったら返す。無い段に着いたら残りは字面のまま(先が無いのは呼ぶ側が見る)。
    /// 途中で `mayRead` が断る・`maxHops` を超える(ループ)・読めない記号リンクなら nil。**FileIO の上で呼ぶ**。
    static func followingSymbolicLinks(_ path: URL, mayRead: (URL) -> Bool, maxHops: Int = 32) -> URL? {
        var components = lexicalComponents(of: path.path)
        var hops = 0
        var index = 0
        while index < components.count {
            let prefix = URL(fileURLWithPath: "/" + components[0...index].joined(separator: "/"))
            guard mayRead(prefix) else { return nil }
            var status = stat()
            guard lstat(prefix.path, &status) == 0 else { break }
            if status.st_mode & S_IFMT == S_IFLNK {
                hops += 1
                guard hops <= maxHops,
                      let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: prefix.path)
                else { return nil }
                let replaced = lexicalComponents(of: symbolicLinkTarget(destination, linkAt: prefix).path)
                components = replaced + components[(index + 1)...]
                index = 0
                continue
            }
            index += 1
        }
        // 無い段で止まった残りも含めて、最後のパス全体をもう一度確かめる(呼ぶ側はこのパスを stat する)。
        let target = URL(fileURLWithPath: "/" + components.joined(separator: "/"))
        return mayRead(target) ? target : nil
    }

    /// `readlink` の値を絶対パスにする。相対ならリンクのあるフォルダから。`.`・`..` は**字面で**畳む(型コメント)。
    static func symbolicLinkTarget(_ destination: String, linkAt link: URL) -> URL {
        let absolute = destination.hasPrefix("/")
            ? destination
            : link.deletingLastPathComponent().path + "/" + destination
        return URL(fileURLWithPath: "/" + lexicalComponents(of: absolute).joined(separator: "/"))
    }

    /// パスの段(`.`・`..` を字面で畳んだもの)。
    private static func lexicalComponents(of path: String) -> [String] {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(String(component))
            }
        }
        return components
    }
}

import Foundation
import UniformTypeIdentifiers

/// ファイルブラウザの一覧の1行(改善要望7 段階3、2026-09-13)。
///
/// サイドパネルのフォルダブラウザ(DirectoryBrowser.Entry)と同じく、**表示・並べ替え・絞り込みに
/// 要る値を読み込みの時点で全部持つ**。以後は画面の側で一切ディスクに触らない ―― 触ると、
/// 絞り込みの1文字ごと・行の描画ごとに全件のI/Oが走る(あちらで実際に起きた)。
///
/// あちらとの違い:
/// - **すべてのファイルを出す**(あちらは開ける本だけ)。Finderの代わりなので。
/// - **サブフォルダの中を見ない**(「直下に画像があるか」を調べない)。1フォルダを開くたびに
///   子フォルダの数だけ列挙が増えるうえ、`~/Library`の保護領域へ降りた瞬間にTCCのダイアログが
///   出る(qooLibraryで実際に「開くだけで次々出る」になった。検討メモ §3.3)。
///   画像フォルダかどうかは「開く」を選んだときに1回だけ調べる。
nonisolated struct FileBrowserEntry: Identifiable, Hashable, Sendable, FolderBrowserSortable {
    let url: URL
    let displayName: String
    /// フォルダ(パッケージも含む。`.app`は`true`)。
    let isDirectory: Bool
    /// パッケージ(`.app`、`.photoslibrary`など)。**中へは降りない**(Finderと同じ。
    /// 写真ライブラリの中を覗くと出るTCCも止まる)。
    let isPackage: Bool
    let isSymbolicLink: Bool
    /// コンピュータ(ボリューム一覧)の行。
    let isVolume: Bool
    /// ファイルのサイズ。フォルダは常に nil(Finderと同じく中身を合計しない)。
    let fileSize: Int64?
    /// Finderの「種類」。拡張子ごとに1回だけ問い合わせた値(FileBrowserListing.typeDescription)。
    let typeDescription: String?
    let creationDate: Date?
    let modificationDate: Date?

    /// 選択・スクロール先の鍵。**末尾の`/`を持たないパス**(FileBrowserState.id(for:))。
    /// 列挙はフォルダのURLを末尾`/`付きで返し、外から渡されるURLは付いていないことが多いので、
    /// URLの`==`で突き合わせると同じ項目が別物になる。
    var id: String { url.path }

    /// 中へ移動できるフォルダ(パッケージではないフォルダ)。
    var isNavigableFolder: Bool { isDirectory && !isPackage }

    /// 並べ替えの「フォルダを上に」でフォルダの側に寄せるか(パッケージはファイルの側。Finderと同じ)。
    var sortsAsFolder: Bool { isNavigableFolder }

    /// qooViewer で本として開けるファイル(書庫・PDF・EPUB・画像)。フォルダは含まない
    /// (画像フォルダかどうかは開くときに調べる。型コメント参照)。
    var opensAsBook: Bool {
        guard !isDirectory else { return false }
        let name = url.lastPathComponent
        return isArchiveFile(name) || isPDFFile(name) || isEpubFile(name) || isImageFile(name)
    }

    /// ファイルブラウザで展開できる書庫(zip / cbz / epub / rar / cbr / 7z / cb7。段階 6)。判定は拡張子だけ
    /// (中身が違えば展開するときに「読めません」と伝える)。
    var isExtractableArchive: Bool {
        !isDirectory && archiveKind(forFileName: url.lastPathComponent) != nil
    }
}

/// 一覧の読み込みに失敗した理由。右ペインの中央の案内を出し分ける。
nonisolated enum FileBrowserLoadError: Error, Equatable, Sendable {
    /// 読む権限が無い(サンドボックス・TCC)。「アクセスを許可…」を出す。
    case needsAccess
    /// フォルダが無い(消された・移された)。状態は祖先へ退避する。
    case notFound
    /// 繋がっていないボリューム上のフォルダ。
    case volumeUnavailable
    /// それ以外。`localizedDescription`をそのまま見せる。
    case other(String)

    static func classify(_ error: Error, folder: URL, mountTable: MountTable = .current()) -> FileBrowserLoadError {
        if let loadError = error as? FileBrowserLoadError { return loadError }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError:
                return .needsAccess
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return mountTable.isOnAnUnmountedVolume(folder) ? .volumeUnavailable : .notFound
            default:
                break
            }
        }
        let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap {
            $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil
        } ?? (nsError.domain == NSPOSIXErrorDomain ? Int32(nsError.code) : nil)
        switch posix {
        case EPERM, EACCES:
            return .needsAccess
        case ENOENT, ENOTDIR:
            return mountTable.isOnAnUnmountedVolume(folder) ? .volumeUnavailable : .notFound
        default:
            return .other(nsError.localizedDescription)
        }
    }
}

/// ファイルブラウザの一覧を読む(改善要望7 段階3)。**ブロッキングする処理なので必ず`FileIO`の上から呼ぶ**
/// (`DirectoryBrowser.listingAsync`は`Task.detached`で、応答しない共有で協調プールごと止まる ――
/// FileIOの型コメント)。
nonisolated enum FileBrowserListing {
    /// 列挙と一緒に先読みさせるキー。**ここに無いキーを後から読むと、1件ごとの往復になる**
    /// (qooLibrary 実測)。種類(`localizedTypeDescription`)だけは拡張子ごとに1回で済むので含めない。
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .localizedNameKey,
        .totalFileSizeKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
    ]

    /// フォルダの直下を読む。隠しファイルは出さない(Finderの既定と同じ)。
    ///
    /// `contentsOfDirectory`ではなく`enumerator`: APFSで約3倍速い(検討メモ §12)。その代わり、
    /// 列挙の入口で失敗したことは例外ではなくエラーハンドラで知らされるので、ここで拾って投げ直す。
    static func entries(in folder: URL) throws -> [FileBrowserEntry] {
        var rootError: Error?
        let folderPath = MountTable.normalized(folder.path)
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                // 子の1件が読めないだけなら続ける(その行は属性の欠けた行になる)。
                if MountTable.normalized(url.path) == folderPath { rootError = error }
                return true
            }
        ) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: folder.path])
        }
        var kindCache: [String: String] = [:]
        var result: [FileBrowserEntry] = []
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            if count % 256 == 0, Cancellation.isRequestedInCurrentScope { throw CancellationError() }
            result.append(makeEntry(url, kindCache: &kindCache))
        }
        if let rootError { throw rootError }
        // 列挙器は存在しないフォルダでも空の列挙を返すことがあるので、空のときだけ確かめる
        // (中身があるなら在るに決まっている。確かめるのは1回の stat)。
        if result.isEmpty {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
            }
            if !isDirectory.boolValue {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
            }
            // 読めないフォルダを空と取り違えない(列挙器がエラーハンドラを呼ばない場合への保険)。
            if access(folder.path, R_OK) != 0 {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: folder.path])
            }
        }
        return result
    }

    /// 1行ぶんを組み立てる。先読み済みの値だけを読む。
    static func makeEntry(_ url: URL, kindCache: inout [String: String]) -> FileBrowserEntry {
        let values = try? url.resourceValues(forKeys: Set(resourceKeys))
        let isDirectory = values?.isDirectory ?? url.hasDirectoryPath
        let isPackage = values?.isPackage ?? false
        let name: String = {
            if let localized = values?.localizedName, !localized.isEmpty { return localized }
            return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }()
        return FileBrowserEntry(
            url: url,
            displayName: name,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: values?.isSymbolicLink ?? false,
            isVolume: false,
            fileSize: isDirectory && !isPackage ? nil : (values?.totalFileSize ?? values?.fileSize).map(Int64.init),
            typeDescription: typeDescription(for: url, isDirectory: isDirectory, isPackage: isPackage, cache: &kindCache),
            creationDate: values?.creationDate,
            modificationDate: values?.contentModificationDate
        )
    }

    /// 「コンピュータ」に並べるボリューム。マウント表から作り、**ネットワーク越しのボリュームには
    /// 触らない**(名前の問い合わせも、応答しない共有では戻ってこない)。
    ///
    /// 出すのは起動ボリューム(`/`)と`/Volumes/`直下のうち、Finderに出すもの(`MNT_DONTBROWSE`でない)
    /// だけ。`/System/Volumes/Data`やTime Machineのスナップショット、`-nobrowse`で付けたディスク
    /// イメージは出ない(Finderと同じ)。
    static func volumeEntries(mountTable: MountTable) -> [FileBrowserEntry] {
        let volumeKind = UTType.volume.localizedDescription
        return mountTable.entries.compactMap { mount in
            guard !mount.isHiddenFromBrowsing,
                  mount.mountPoint == "/" || MountTable.volumeRoot(of: mount.mountPoint) == mount.mountPoint
            else { return nil }
            let url = URL(fileURLWithPath: mount.mountPoint, isDirectory: true)
            var name = mount.mountPoint == "/" ? "/" : url.lastPathComponent
            var creationDate: Date?
            var modificationDate: Date?
            if mount.isLocal,
               let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .localizedNameKey, .creationDateKey, .contentModificationDateKey]) {
                name = values.volumeLocalizedName ?? values.localizedName ?? name
                creationDate = values.creationDate
                modificationDate = values.contentModificationDate
            }
            return FileBrowserEntry(
                url: url, displayName: name, isDirectory: true, isPackage: false, isSymbolicLink: false,
                isVolume: true, fileSize: nil,
                typeDescription: volumeKind,
                creationDate: creationDate, modificationDate: modificationDate
            )
        }
    }

    /// 絞り込み(検索欄。現フォルダの中だけ ―― 決定事項 Q9)。照合の規則はウェルカム画面の検索と同じ
    /// (LibrarySearchQuery)。
    static func filtered(_ entries: [FileBrowserEntry], by text: String) -> [FileBrowserEntry] {
        guard let query = LibrarySearchQuery(text) else { return entries }
        return entries.filter { query.matches(normalized: LibrarySearchQuery.normalized($0.displayName)) }
    }

    /// 実際のホームフォルダ。**`FileManager.homeDirectoryForCurrentUser`はサンドボックスではコンテナを
    /// 返す**ので、パスワードデータベースから引く(qooLibrary 実測)。
    static func realHomeDirectory() -> URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// `url`から上へたどって、最初に実在するフォルダ。消えたフォルダを表示していたときの退避先。
    /// ボリュームごと外れていれば nil(= コンピュータへ)。**ブロッキングするのでFileIOの上で。**
    static func nearestExistingAncestor(of url: URL, mountTable: MountTable = .current()) -> URL? {
        if mountTable.isOnAnUnmountedVolume(url) { return nil }
        var candidate = url.deletingLastPathComponent()
        while candidate.path != "/" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }

    /// Finderの「種類」。拡張子ごとに1回だけ LaunchServices へ問い合わせる
    /// (DirectoryBrowser.typeDescriptionと同じ考え方。パッケージは素のフォルダと分ける)。
    ///
    /// **文字列はOSの言語で返る**(環境設定の表示言語には従わない)。LaunchServicesの説明文を
    /// アプリの言語で引く手段が無いため。Finderの「種類」列と同じ文字列になる、というほうを取った。
    private static func typeDescription(
        for url: URL, isDirectory: Bool, isPackage: Bool, cache: inout [String: String]
    ) -> String? {
        let prefix = isPackage ? "p:" : (isDirectory ? "d:" : "f:")
        let key = prefix + url.pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let description: String?
        if isDirectory, !isPackage {
            description = UTType.folder.localizedDescription
        } else {
            description = (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription
        }
        if let description { cache[key] = description }
        return description
    }
}

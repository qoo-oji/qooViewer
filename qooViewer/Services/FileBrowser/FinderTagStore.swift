import Foundation

/// Finder のタグの読み書き(2026-11-03、利用者の要望。ホームのインスペクタ。実測は docs/14「インスペクタ」の「タグ」)。
/// **どの関数もブロッキングする**ので `FileIO` の上で呼ぶ。
///
/// ■ なぜ `URL.tagNames` を正にしないか(macOS 27 で実測)
/// - 許可の外のファイルでは**エラーにならず**、色付きのタグがあれば `FinderInfo` の色 1 つだけ(`['Blue']`)、色無しなら nil を返す。
///   「タグ無し」「タグが欠けている」と見分けが付かない。`getxattr` なら `EPERM` で分かる
/// - 色が取れない。壊れた値も黙って nil になる
///
/// ■ 書き方(どれも使い捨てのボリューム・NAS で実測)
/// - 足す・外す: `setxattr` で配列を書き、`FinderInfo` の色を Finder と同じ「最後の色付きのタグの色」に揃える。xattr だけ書くと
///   `FinderInfo` が古いままになる(`labelNumber` とタグの色がずれる)
/// - 全部外す: `NSURL` に空の配列を渡す(Finder の画面で外したときと同じ状態 = 空の配列 + 色 0。属性そのものは残る)。
///   **`removexattr` は使わない**: SMB の NAS では成功を返すのに消えず、`FinderInfo` の色も残る。空の配列を xattr で書くだけでも色が残り、
///   `tagNames` が `['Blue']` を返し続ける
/// - **書き込みの後は読み直して確かめる**(成功を返しても効いていないことがある ―― 上の `removexattr`)
/// - **ネットワークボリュームには書かない**(利用者の指定。読むだけ。画面が淡色にするだけでなく、ここでも断る)
///
/// ■ 副作用
/// サンドボックスの中からタグを書くと、macOS がそのファイルに `com.apple.quarantine` を付ける(`setxattr` だけでも付く。読むだけなら
/// 付かない)。アプリからは消せない(`EPERM`)。`docs/14` を参照。
///
/// 値はファイルに書かれたもの(他のアプリも書く)なので信用しない: 配列でなければ「壊れている」とし、**空に読み替えない**
/// (空に読むと「タグ無し」と表示し、その上に足すと元の値を消す)。
nonisolated enum FinderTagStore {
    static let tagsAttribute = "com.apple.metadata:_kMDItemUserTags"
    static let finderInfoAttribute = "com.apple.FinderInfo"

    /// 読んだ結果。「読めなかった」を空の一覧にしない。
    enum Reading: Equatable, Sendable {
        case tags([FinderTag])
        /// ファイルが無い。
        case notFound
        /// サンドボックス・権限で読めない(`EPERM` / `EACCES`)。
        case denied
        /// 値が壊れている(文字列の配列でない)。
        case corrupted
        case failed(Int32)
    }

    enum WriteError: Error, Equatable {
        /// ネットワークボリューム(利用者の指定で読むだけ)。
        case networkVolume
        /// 書く前に読めなかった。
        case unreadable(Reading)
        /// 書けなかった(`errno`)。
        case failed(Int32)
        /// 書いたはずの値が読めなかった(成功を返したのに効いていない)。
        case notApplied
    }

    /// ファイルの形の事実(編集できるかの判定の材料。呼ぶのは読むときに 1 回)。
    struct Location: Equatable, Sendable {
        var isOnNetworkVolume: Bool
        var isMountPoint: Bool
        /// 読み取り専用のボリュームにある、または書き込み権限が無い。ネットワークボリュームでは問い合わせない(どのみち書かない)。
        var isUnwritable: Bool
    }

    // MARK: - 読む

    /// - Parameter localization: 古いラベルだけのファイルのタグ名を引く言語(`FinderTagColor.finderLocalization`)。
    static func read(at url: URL, localization: String = FinderTagColor.finderLocalization()) -> Reading {
        let raw: [UInt8]?
        switch attribute(tagsAttribute, of: url) {
        case .value(let bytes): raw = bytes
        case .absent: raw = nil
        case .failure(let code): return reading(forErrno: code)
        }
        var tags: [FinderTag] = []
        if let raw, !raw.isEmpty {
            guard let list = (try? PropertyListSerialization.propertyList(from: Data(raw), options: [], format: nil)) as? [String] else {
                return .corrupted
            }
            tags = list.map(FinderTag.init(rawValue:))
        }
        // タグの配列が無く色だけあるファイル(Finder のラベル時代のファイル)は、Finder も色の名前のタグとして見せる。
        if tags.isEmpty, case .value(let info) = attribute(finderInfoAttribute, of: url),
           let color = FinderTagColor.fromFinderInfo(info) {
            tags = [FinderTag(name: color.name(localization: localization), color: color)]
        }
        return .tags(tags)
    }

    /// `errno` の読み分け(`ENOTSUP` = 拡張属性の無いファイルシステムなので、タグが無いのと同じ)。
    static func reading(forErrno code: Int32) -> Reading {
        switch code {
        case ENOENT, ENOTDIR: .notFound
        case EPERM, EACCES: .denied
        case ENOTSUP: .tags([])
        default: .failed(code)
        }
    }

    /// 編集できるかの材料を読む。
    static func location(of url: URL, mounts: MountTable = .current()) -> Location {
        let path = MountTable.normalized(url.path)
        if NetworkVolumeReading.isOnNetworkVolume(url, mounts: mounts) {
            return Location(isOnNetworkVolume: true, isMountPoint: false, isUnwritable: false)
        }
        let readOnlyVolume = (try? URL(filePath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return Location(
            isOnNetworkVolume: false, isMountPoint: mounts.isMounted(path),
            isUnwritable: readOnlyVolume || access(path, W_OK) != 0
        )
    }

    // MARK: - 書く

    /// 変更を当てて、書いた後の一覧を返す。**書く直前に読み直す**(開いている間に Finder で変えたタグを消さない)。
    @discardableResult
    static func apply(
        _ edit: FinderTagEdit, at url: URL, localization: String = FinderTagColor.finderLocalization()
    ) throws -> [FinderTag] {
        guard !NetworkVolumeReading.isOnNetworkVolume(url) else { throw WriteError.networkVolume }
        let target = resolvingSymbolicLink(url)
        let current: [FinderTag]
        switch read(at: target, localization: localization) {
        case .tags(let tags): current = tags
        case let other: throw WriteError.unreadable(other)
        }
        guard let updated = edit.applied(to: current, localization: localization) else { return current }
        try write(updated, to: target)
        // 成功を返しても効いていないことがある(型コメント)。
        guard case .tags(let reread) = read(at: target, localization: localization),
              reread.map(\.name) == updated.map(\.name) else { throw WriteError.notApplied }
        return reread
    }

    /// 一覧を丸ごと書く。
    private static func write(_ tags: [FinderTag], to url: URL) throws {
        if tags.isEmpty {
            do {
                try (url as NSURL).setResourceValue([String](), forKey: .tagNamesKey)
            } catch {
                throw WriteError.failed(posixCode(of: error))
            }
            return
        }
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: tags.map(\.rawValue), format: .binary, options: 0)
        } catch {
            throw WriteError.failed(EINVAL)
        }
        try setAttribute(tagsAttribute, [UInt8](data), of: url)
        try syncFinderInfo(with: tags, of: url)
    }

    /// `FinderInfo` の色を、Finder と同じ「最後の色付きのタグの色」に揃える(レッド → ブルーの順で付けると 4 = ブルー。実測)。
    private static func syncFinderInfo(with tags: [FinderTag], of url: URL) throws {
        let color = tags.last(where: { $0.color != nil })?.color
        var info = [UInt8](repeating: 0, count: 32)
        switch attribute(finderInfoAttribute, of: url) {
        case .value(let bytes) where bytes.count == 32:
            info = bytes
        case .value, .absent:
            // 色を付けないなら、無い属性をわざわざ作らない。
            if color == nil { return }
        case .failure(let code):
            throw WriteError.failed(code)
        }
        let updated = FinderTagColor.settingFinderInfo(info, to: color)
        if updated != info { try setAttribute(finderInfoAttribute, updated, of: url) }
    }

    /// `NSURL` の失敗の理由(許可の外は `NSOSStatusErrorDomain` -5000 で返る。実測)。
    private static func posixCode(of error: Error) -> Int32 {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        if let posix = [error, underlying].compactMap({ $0 }).first(where: { $0.domain == NSPOSIXErrorDomain }) {
            return Int32(posix.code)
        }
        return error.domain == NSOSStatusErrorDomain && error.code == -5000 ? EACCES : EIO
    }

    /// リンクは先へ書く(`getxattr` はリンクを辿るが、`NSURL` の書き込みはリンク自身へ向かうことがあるので揃える)。
    private static func resolvingSymbolicLink(_ url: URL) -> URL {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return url }
        return url.resolvingSymlinksInPath()
    }

    // MARK: - 拡張属性

    private enum AttributeResult {
        case value([UInt8])
        case absent
        case failure(Int32)
    }

    /// 大きさを聞いてから読む(その間に伸びると `ERANGE` なので数回だけ聞き直す。Finder が同時に書きうる)。
    private static func attribute(_ name: String, of url: URL) -> AttributeResult {
        let path = url.path
        for _ in 0..<4 {
            let size = getxattr(path, name, nil, 0, 0, 0)
            if size < 0 {
                let code = errno
                return code == ENOATTR ? .absent : .failure(code)
            }
            if size == 0 { return .value([]) }
            var buffer = [UInt8](repeating: 0, count: size)
            let got = getxattr(path, name, &buffer, size, 0, 0)
            if got >= 0 { return .value(Array(buffer[0..<got])) }
            let code = errno
            if code == ENOATTR { return .absent }
            if code != ERANGE { return .failure(code) }
        }
        return .failure(ERANGE)
    }

    private static func setAttribute(_ name: String, _ bytes: [UInt8], of url: URL) throws {
        let result = setxattr(url.path, name, bytes, bytes.count, 0, 0)
        if result != 0 { throw WriteError.failed(errno) }
    }
}

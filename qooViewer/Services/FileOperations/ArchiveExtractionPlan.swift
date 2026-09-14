import Foundation

/// 展開で「どのエントリを、展開先の中のどの相対パスへ書くか」を決める(改善要望7 段階 6、2026-09-14)。
/// **純粋関数**(ファイルシステムに触らない)。書庫の索引は攻撃者が書ける値なので、ここで全部疑う。
///
/// ■ 捨てるもの(qooLibrary の `EntryPathValidation` を写し、足りなかったものを足した)
/// - 絶対パス(`/…`、`\…`、`C:\…`)と、要素に `..` を含むもの。**区切りは `/` と `\` の両方で見る**
///   (Windows で作られた書庫の `..\..\x` を、macOS の名前としては `\` を含む 1 要素と読んで通すと、
///   それを解釈するほかのツールへ渡ったときに外へ出る)。
/// - NUL・制御文字を含むもの、1 要素が 255 バイト・全体が PATH_MAX を超えるもの(書こうとしても失敗する)。
/// - 記号リンク(展開先の外を指すリンクを経由した書き込み ―― いわゆる Zip Slip の変形 ―― の入口になる)。
/// - `__MACOSX/` と `._*`(`isAppleDoubleEntry`。**qooLibrary には無かった穴**。Finder で圧縮した書庫には必ず入り、
///   展開すると中身の無い `._001.jpg` が並ぶ)。これは危険ではないので、利用者への報告には並べない。
///
/// ■ 名前がぶつかるとき(APFS の既定は大文字小文字と正規化を区別しない)
/// - ファイルどうし・ファイルとフォルダ → 後から来たほうを `name 2`(Finder の「両方残す」と同じ規則。FileNameValidation)。
/// - フォルダどうし(`A/` と `a/`)→ 同じフォルダにまとめる(区別しないディスクへ書けば OS がそうする。分けると
///   1 冊の本のページが 2 つのフォルダに割れる)。
/// - まったく同じパスが 2 回 → 後のものは捨てる(reader は同じパスから 1 つしか引けないので、同じ中身の複製になるだけ)。
nonisolated struct ArchiveExtractionPlan: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        /// reader に渡す鍵。
        let sourcePath: String
        /// 展開先(一時フォルダ)の中の相対パス。衝突を避けたあとの名前。
        let relativePath: String
        let isDirectory: Bool
        let uncompressedSize: UInt64
        let modified: Date?
    }

    /// 捨てたエントリと理由(利用者に見せる)。
    struct Rejection: Sendable, Equatable {
        let path: String
        let reason: ArchiveEntryRejection
    }

    private(set) var items: [Item] = []
    private(set) var rejections: [Rejection] = []
    /// ファイルの宣言サイズの合計。**飽和加算**(細工された索引の UInt64 の近くの値で `+` がトラップした ―― qooLibrary)。
    private(set) var declaredTotalBytes: UInt64 = 0
    /// **書き出さないが、ソリッドの書庫では読み飛ばすために伸長される**ファイル(`__MACOSX`・捨てたエントリ・同じパスの 2 つ目)の
    /// 宣言サイズの合計(飽和加算。2026-09-14 の 2 回目の監査 21)。以前は限度に数えなかったので、捨てられるエントリに伸長爆弾を
    /// 隠した 7z / rar は、限度の検査も書いた量の数えも通り抜けて伸長し続けた(中止も読み飛ばしの中までは届かない)。
    private(set) var skippedDeclaredBytes: UInt64 = 0
    private(set) var fileCount = 0
    /// 暗号化されたエントリがある(展開しない)。
    private(set) var hasEncryptedEntries = false

    init(entries: [ArchiveEntryDescriptor]) {
        var namer = Namer()
        var seenSourcePaths: Set<String> = []
        func skip(_ entry: ArchiveEntryDescriptor) {
            guard entry.kind != .directory else { return }
            let (sum, overflow) = skippedDeclaredBytes.addingReportingOverflow(entry.uncompressedSize)
            skippedDeclaredBytes = overflow ? .max : sum
        }
        for entry in entries {
            if entry.isEncrypted { hasEncryptedEntries = true }
            if isAppleDoubleEntry(entry.path) {
                skip(entry)
                continue
            }
            let components: [String]
            switch Self.components(of: entry.path) {
            case let .success(value):
                components = value
            case let .failure(reason):
                rejections.append(Rejection(path: entry.path, reason: reason))
                skip(entry)
                continue
            }
            switch entry.kind {
            case .symbolicLink:
                rejections.append(Rejection(path: entry.path, reason: .symbolicLink))
                skip(entry)
            case .directory:
                let relative = namer.directory(for: components[...])
                guard seenSourcePaths.insert("d:" + relative).inserted else { continue }
                items.append(Item(
                    sourcePath: entry.path, relativePath: relative, isDirectory: true, uncompressedSize: 0, modified: entry.modified
                ))
            case .file:
                guard seenSourcePaths.insert(entry.path).inserted else {
                    skip(entry)
                    continue
                }
                let relative = namer.file(for: components)
                items.append(Item(
                    sourcePath: entry.path, relativePath: relative, isDirectory: false,
                    uncompressedSize: entry.uncompressedSize, modified: entry.modified
                ))
                fileCount += 1
                let (sum, overflow) = declaredTotalBytes.addingReportingOverflow(entry.uncompressedSize)
                declaredTotalBytes = overflow ? .max : sum
            }
        }
    }

    // MARK: - パスの検証

    /// エントリのパスを、展開先の中で使ってよい要素の並びにする。使えなければ理由。
    static func components(of path: String) -> Result<[String], ArchiveEntryRejection> {
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return .failure(.invalidCharacters)
        }
        if path.hasPrefix("/") || path.hasPrefix("\\") || Self.hasDrivePrefix(path) {
            return .failure(.unsafePath)
        }
        // 全体の長さ(= 入れ子の段数)にも上限を置く(2026-09-14 の 2 回目の監査)。展開先の中の相対パスだけで PATH_MAX を超える
        // エントリは、書こうとしても必ず失敗する。上限が無いと、名前長に上限の無い zip / 7z の細工された索引で計画作りの費用が
        // 段数の 2 乗に伸びる(スタック溢れの件は Namer のコメント)。
        guard path.utf8.count <= maxPathBytes else { return .failure(.nameTooLong) }
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component.split(separator: "\\", omittingEmptySubsequences: false).contains("..") {
                return .failure(.unsafePath)
            }
            if component == "." { continue }
            guard component.utf8.count <= 255 else { return .failure(.nameTooLong) }
            components.append(String(component))
        }
        return components.isEmpty ? .failure(.unsafePath) : .success(components)
    }

    /// エントリのパス全体の上限(バイト)。macOS の PATH_MAX と同じ。
    static let maxPathBytes = Int(PATH_MAX)

    /// `C:` `C:\` `C:/` で始まる(Windows の絶対パス)。
    private static func hasDrivePrefix(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars.prefix(2))
        guard scalars.count == 2, scalars[1] == ":" else { return false }
        return (scalars[0].value >= 0x41 && scalars[0].value <= 0x5A) || (scalars[0].value >= 0x61 && scalars[0].value <= 0x7A)
    }

    // MARK: - 限度

    /// 展開を始める前の検査(宣言の値で)。書いている最中にも実際の量で同じ限度を見る(ArchiveExtractor)。
    func checkLimits(_ limits: ArchiveExtractionLimits, archiveSize: Int64, archive: URL) throws {
        guard fileCount <= limits.maxEntries else {
            throw ArchiveOperationError.tooManyEntries(archive: archive, count: fileCount, limit: limits.maxEntries)
        }
        // 伸長する量は、書き出すぶんと読み飛ばすぶんの合計(`skippedDeclaredBytes` のコメント)。
        let (sum, overflow) = declaredTotalBytes.addingReportingOverflow(skippedDeclaredBytes)
        let decodedBytes = overflow ? UInt64.max : sum
        guard decodedBytes <= limits.maxTotalBytes else {
            throw ArchiveOperationError.tooLarge(archive: archive, limit: limits.maxTotalBytes)
        }
        guard !limits.exceedsCompressionRatio(expandedBytes: decodedBytes, archiveSize: archiveSize) else {
            throw ArchiveOperationError.suspiciousCompressionRatio(archive: archive)
        }
    }
}

/// 使えないエントリの理由。
nonisolated enum ArchiveEntryRejection: Error, Sendable, Equatable {
    /// 絶対パス・`..`・空のパス。
    case unsafePath
    /// NUL・制御文字。
    case invalidCharacters
    /// 1 要素が 255 バイトを超える、またはパス全体が PATH_MAX を超える。
    case nameTooLong
    case symbolicLink

    var message: String {
        let locale = AppLanguage.currentLocale
        switch self {
        case .unsafePath:
            return String(localized: "It was skipped because its path points outside the destination folder.", language: locale)
        case .invalidCharacters:
            return String(localized: "It was skipped because its name contains control characters.", language: locale)
        case .nameTooLong:
            return String(localized: "It was skipped because its name is too long.", language: locale)
        case .symbolicLink:
            return String(localized: "Symbolic links aren’t extracted.", language: locale)
        }
    }
}

/// 伸長爆弾よけの限度(計画 §6)。テストは小さな値で確かめる。
nonisolated struct ArchiveExtractionLimits: Sendable, Equatable {
    /// 書き出す合計(20GB)。
    var maxTotalBytes: UInt64 = 20 * 1024 * 1024 * 1024
    /// ファイルの数(10 万)。
    var maxEntries = 100_000
    /// 書庫の大きさに対する展開後の大きさの倍率(1,000 倍)。
    var maxCompressionRatio: UInt64 = 1_000
    /// 展開後の合計がこれ以下なら倍率を問わない(100MB)。0 を詰めた小さなファイルの入った正当な書庫を断らない。
    var ratioFloorBytes: UInt64 = 100 * 1024 * 1024
    /// 始める前に展開先の空き容量を見る。**テストのための逃げ道**(書き込みの最中のディスクフルを確かめる)。
    var checksFreeSpace = true

    static let standard = ArchiveExtractionLimits()

    func exceedsCompressionRatio(expandedBytes: UInt64, archiveSize: Int64) -> Bool {
        guard expandedBytes > ratioFloorBytes else { return false }
        let (allowed, overflow) = UInt64(max(archiveSize, 1)).multipliedReportingOverflow(by: maxCompressionRatio)
        return !overflow && expandedBytes > allowed
    }
}

/// 展開先の名前を決める(衝突の規則は ArchiveExtractionPlan の型コメント)。
nonisolated private struct Namer {
    /// 書庫の中のフォルダのパス(畳んだもの)→ 展開先の相対パス。
    private var directories: [String: String] = [:]
    /// 展開先の相対パスのフォルダ → その中で使った名前(畳んだもの)とフォルダか。
    private var taken: [String: [String: Bool]] = [:]

    /// **親から順にループで組み立てる**(2026-09-14 の 2 回目の監査)。以前は要素ごとに自分を再帰で呼び、段ごとに畳んだキーを
    /// 全要素から作り直していたので、3000 段の入れ子のエントリ 1 つだけの 12KB の zip で FileIO のスレッドのスタックが溢れて
    /// アプリごと落ちた(抜き出したコードで実測)。段数そのものは `components(of:)` の全体長の上限で抑える。
    mutating func directory(for components: ArraySlice<String>) -> String {
        var parent = ""
        var key = ""
        for name in components {
            let folded = FileNameValidation.foldedForComparison(name)
            key = key.isEmpty ? folded : key + "/" + folded
            if let known = directories[key] {
                parent = known
                continue
            }
            let actualName: String
            switch taken[parent]?[folded] {
            case true?:
                // 大文字小文字だけ違うフォルダ(`A/` と `a/`)はまとめる。
                actualName = existingName(in: parent, folded: folded) ?? name
            case false?:
                // 同じ名前のファイルが先にある。
                actualName = availableName(for: name, in: parent, isDirectory: true)
                taken[parent, default: [:]][FileNameValidation.foldedForComparison(actualName)] = true
                names[parent + "/" + FileNameValidation.foldedForComparison(actualName)] = actualName
            case nil:
                actualName = name
                taken[parent, default: [:]][folded] = true
                names[parent + "/" + folded] = name
            }
            let relative = parent.isEmpty ? actualName : parent + "/" + actualName
            directories[key] = relative
            parent = relative
        }
        return parent
    }

    mutating func file(for components: [String]) -> String {
        let parent = directory(for: components.dropLast())
        let name = components[components.count - 1]
        let actualName = availableName(for: name, in: parent, isDirectory: false)
        taken[parent, default: [:]][FileNameValidation.foldedForComparison(actualName)] = false
        return parent.isEmpty ? actualName : parent + "/" + actualName
    }

    /// 畳んだ名前 → 最初に使った実際の名前(フォルダをまとめるとき、先に来た綴りに揃える)。
    private var names: [String: String] = [:]

    /// 番号を付けて避けるときに、次に試す番号(フォルダ + 種類 + 畳んだ名前ごと)。
    private var nextNumbers: [String: Int] = [:]

    /// `parent` の中で空いている名前(`name 2` …)。**前に同じ名前を避けたときの番号の続きから探す**(2026-09-14 の 2 回目の監査 16。
    /// 以前は毎回 2 から数え直したので、同じ名前が大文字小文字違いで 4000 件並ぶ書庫で 2.9 秒、件数の上限を確かめる前に掛かった)。
    /// `taken` は増える一方なので、前に塞がっていた番号は今も塞がっている ―― 続きから探しても結果は変わらない。
    private mutating func availableName(for name: String, in parent: String, isDirectory: Bool) -> String {
        func isTaken(_ candidate: String) -> Bool { taken[parent]?[FileNameValidation.foldedForComparison(candidate)] != nil }
        guard isTaken(name) else { return name }
        let memo = parent + "\u{0}" + (isDirectory ? "d" : "f") + FileNameValidation.foldedForComparison(name)
        var number = nextNumbers[memo] ?? 2
        var candidate = FileNameValidation.numberedName(name, number: number, isDirectory: isDirectory)
        while isTaken(candidate) {
            number += 1
            candidate = FileNameValidation.numberedName(name, number: number, isDirectory: isDirectory)
        }
        nextNumbers[memo] = number + 1
        return candidate
    }

    private func existingName(in parent: String, folded: String) -> String? {
        names[parent + "/" + folded]
    }
}

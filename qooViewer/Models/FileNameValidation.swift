import Foundation

/// ユーザーが入力した名前を、ファイルシステムへ渡す前に検査する唯一の窓口と、衝突しない名前の付け方
/// (改善要望7 段階 2、2026-09-13。名前の変更・新規フォルダ・一括リネーム・「両方残す」が共用する)。
///
/// ■ 何を禁止するか(qooLibrary 実測)
/// macOS がマウントしうる形式すべて(APFS / 大文字小文字区別 APFS / HFS+ / exFAT / FAT / UDF / SMB)で
/// **拒否されたのは `/` と `.` と `..` だけ**だった。Windows で禁止の `\ : * ? " < > |`、改行・制御文字、
/// 末尾の空白やドット、先頭のドットはどれも作れる。作れる名前を理由なく拒まないので禁止しない。
/// NUL は C 文字列の終端なので渡しようがなく、これも断る。
///
/// ■ `/` は `:` へ置き換えず、理由を返す
/// Finder は `/` を受け付けて POSIX 上は `:` として保存するが、入力した名前と保存される名前が
/// 食い違う。「その文字は使えない」と伝えるほうが意図に忠実(qooLibrary でのユーザー判断を踏襲)。
/// 置き換えずに `appendingPathComponent` へ渡すと**パス区切りとして解釈され、名前の変更のつもりが
/// 別フォルダへの移動になる**(実測で再現)ので、ここで必ず断る。
///
/// ■ 長さ
/// 単位が形式ごとに違う(APFS/HFS+ は NFD 後の UTF-16 単位 255、SMB は UTF-8 で 255 バイト、UDF は
/// さらに短い)。ここでは**いちばん緩い APFS の規則**だけを見る。より短い上限の宛先(SMB)は
/// FileOperationService の事前検査が宛先ごとに見る ―― ここで UTF-8 255 バイトまで一律に断ると、
/// Mac の中では作れる日本語 86 文字以上の名前が作れなくなる。
nonisolated enum FileNameValidation {
    enum Failure: Error, Sendable, Equatable {
        case empty
        /// `/` または NUL を含む。
        case forbiddenCharacter(String)
        /// `.` / `..`。
        case reservedDotName
        /// NFD 後の UTF-16 単位で上限を超える。
        case tooLong(units: Int)
    }

    static let maxNameUnits = 255

    /// 入力を整えて返す。使えない名前なら `Failure` を投げる。
    /// 整えるのは前後の空白と改行を落とすことだけ(Finder も落とす)。文字の置き換えはしない。
    static func validated(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }
        if trimmed.contains("/") { throw Failure.forbiddenCharacter("/") }
        if trimmed.unicodeScalars.contains("\0") { throw Failure.forbiddenCharacter("\\0") }
        guard trimmed != ".", trimmed != ".." else { throw Failure.reservedDotName }
        let units = trimmed.decomposedStringWithCanonicalMapping.utf16.count
        guard units <= maxNameUnits else { throw Failure.tooLong(units: units) }
        return trimmed
    }

    static func isAcceptable(_ raw: String) -> Bool {
        (try? validated(raw)) != nil
    }

    // MARK: - 衝突しない名前

    /// `name` が `isTaken` で塞がっていれば、Finder と同じ `name 2.ext`、`name 3.ext` … の最初に空いた名前。
    /// 塞がっていなければ `name` そのもの。
    ///
    /// **既存の数字を解釈しない**(計画 §2.3 の決定)。`photo 2.jpg` がぶつかったら `photo 2 2.jpg` になる。
    /// 名前の末尾の数字が「連番」なのか「巻数」なのか(`第 2` や `vol 2`)は名前からは分からず、
    /// 剥がすと本の名前を書き換えてしまうため。
    ///
    /// 拡張子の扱いは Finder に合わせる: 先頭のドットだけの名前(`.hidden`)とフォルダは全体を基部にする。
    static func nextAvailableName(for name: String, isDirectory: Bool = false, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let (base, ext) = split(name, isDirectory: isDirectory)
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// 既にある名前の集合から選ぶ版(純粋関数。テストと一括リネームの計画用)。
    /// 比較は**正規化(NFC)と大文字小文字を畳んで**行う ―― APFS の既定は大文字小文字を区別せず、
    /// 正規化違いは区別版の APFS でも同一視される(qooLibrary 実測)ので、畳まないと実在の衝突を見逃す。
    static func nextAvailableName(for name: String, isDirectory: Bool = false, existing: Set<String>) -> String {
        let folded = Set(existing.map(foldedForComparison))
        return nextAvailableName(for: name, isDirectory: isDirectory) { folded.contains(foldedForComparison($0)) }
    }

    /// 新規フォルダの名前。1 つ目は「名称未設定フォルダ」、塞がっていれば「名称未設定フォルダ 2」…。
    ///
    /// - Note: 2 つ目以降の番号の付け方は Finder の「新規フォルダ」の既知の挙動(`untitled folder 2`)に
    ///   合わせてあるが、**この機の Finder ではまだ確かめていない**(計画 §2.4)。段階 4 で新規フォルダの
    ///   ボタンを置くときに実機の Finder と突き合わせる。
    static func untitledFolderName(existing: Set<String>, locale: Locale = AppLanguage.currentLocale) -> String {
        nextAvailableName(
            for: String(localized: "untitled folder", language: locale),
            isDirectory: true,
            existing: existing
        )
    }

    static func foldedForComparison(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func split(_ name: String, isDirectory: Bool) -> (base: String, ext: String) {
        guard !isDirectory else { return (name, "") }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = String(name[name.index(after: dot)...])
        guard !ext.isEmpty, !ext.contains(" ") else { return (name, "") }
        return (String(name[..<dot]), ext)
    }
}

extension FileNameValidation.Failure: LocalizedError {
    nonisolated var errorDescription: String? {
        let locale = AppLanguage.currentLocale
        switch self {
        case .empty:
            return String(localized: "Enter a name.", language: locale)
        case let .forbiddenCharacter(character):
            return String(format: String(localized: "A name can’t contain “%@”.", language: locale), character)
        case .reservedDotName:
            return String(localized: "The names “.” and “..” are reserved by the system.", language: locale)
        case let .tooLong(units):
            return String(
                format: String(localized: "The name is too long (%1$lld characters; the limit is %2$lld).", language: locale),
                units, FileNameValidation.maxNameUnits
            )
        }
    }
}

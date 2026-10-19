import Foundation
import StackNestViewerKit

/// StackNest の本のページの名前(書庫のエントリのパスの役)と、StackNest のページ番号(`pages/{n}` の n)の対応。
///
/// ■ 名前は StackNest が manifest で返す(`?pageNames=1`。部品の `requestsPageNames`)
/// 書庫の本なら書庫の中のパス(`第1話/001.jpg`)、フォルダの本ならファイル名。これをそのまま `PageSource.archive` の
/// エントリのパスにするので、表示名・場所(`PageRef.location`)・サイドパネルの本の中身ブラウザのフォルダ・ページの鍵
/// (`PageRef.sortKey` ―― ブックマークとレイアウトの鍵)が、ローカルの書庫の本と同じ道で実際の名前になる。
/// 名前を返さない StackNest(古い版・PDF の本など)では、これまでどおり番号の仮の名前(`000041.jpg`。`StackNestPageNaming`)。
///
/// ■ 番号は名前から引く
/// ページを取るとき・読書位置を書き戻すときの番号は、必ずこの表で名前から引く。実際の名前の本では、名前が仮の名前と同じ形
/// (`000001.jpg`)でも `StackNestPageNaming.pageIndex(fromEntryName:)` で番号を読まない(書庫の中の `000001.jpg` は 0 番かもしれない)。
///
/// ■ 名前は信頼しない
/// 名前は本の中から来た文字列で、qooViewer はファイルのパスとして使わない(StackNest の本をディスクへ書き出す道は無い)。
/// それでもフォルダの階層として並べるので、空の区切り・`.` は落とし、`..` を含む名前・揃えた後に重なる名前が 1 つでもあれば、
/// 一覧ごと仮の名前に戻す(番号と名前の対応が崩れた一覧を部分的に使わない ―― 部品の検査と同じ考え方)。
nonisolated final class StackNestPageMap: Sendable {
    /// エントリのパス(StackNest のページ番号の順。`entryNames[n]` が `pages/{n}`)。
    let entryNames: [String]
    /// StackNest が返した実際の名前か(false なら番号の仮の名前)。
    let usesRealNames: Bool
    private let indexByName: [String: Int]

    private init(entryNames: [String], usesRealNames: Bool) {
        self.entryNames = entryNames
        self.usesRealNames = usesRealNames
        var table: [String: Int] = [:]
        table.reserveCapacity(entryNames.count)
        for (index, name) in entryNames.enumerated() { table[name] = index }
        indexByName = table
    }

    /// ページ数と、manifest の名前(無ければ nil)から作る。名前が使えなければ番号の仮の名前。
    convenience init(names: [String]?, pageCount: Int) {
        if let real = Self.normalizedEntryNames(names, pageCount: pageCount) {
            self.init(entryNames: real, usesRealNames: true)
        } else {
            self.init(entryNames: StackNestPageNaming.entryNames(pageCount: pageCount), usesRealNames: false)
        }
    }

    convenience init(_ manifest: StackNestBookManifest) {
        self.init(names: manifest.pageNames, pageCount: manifest.pageCount)
    }

    /// エントリのパス → StackNest のページ番号。この本の名前でなければ nil。
    func pageIndex(ofEntry entry: String) -> Int? {
        indexByName[entry]
    }

    /// StackNest のページ番号 → エントリのパス。
    func entryName(forPage page: Int) -> String? {
        entryNames.indices.contains(page) ? entryNames[page] : nil
    }

    /// manifest の名前を、エントリのパスとして使える形にする。使えなければ nil(番号の仮の名前にする)。
    ///
    /// 部品が数・空・重複・制御文字・長さは確かめ済み。ここでは区切りの形を揃える: 空の区切りと `.` は落とし
    /// (`./001.jpg` → `001.jpg`、先頭の `/` も)、`..` を含む名前が 1 つでもあれば使わない(フォルダの外を指す形を中身ブラウザに
    /// 組ませない)。揃えた結果が重なるときも使わない(番号と名前の対応を崩さない)。
    static func normalizedEntryNames(_ names: [String]?, pageCount: Int) -> [String]? {
        guard let names, names.count == pageCount, pageCount > 0 else { return nil }
        var result: [String] = []
        result.reserveCapacity(names.count)
        var seen = Set<String>()
        for name in names {
            let parts = name.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
            guard !parts.isEmpty, !parts.contains("..") else { return nil }
            let joined = parts.joined(separator: "/")
            guard seen.insert(joined).inserted else { return nil }
            result.append(joined)
        }
        return result
    }
}

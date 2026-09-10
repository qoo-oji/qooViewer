import Foundation
import SwiftData

/// 「このアプリが何らかの保存データを持っている本」を数え上げる役。
///
/// 元は`MetadataEditorViewModel.collectKnownBookIDs()`の中にだけあった。コレクション表紙を
/// zipから読み込む画面(ShelfCoverImportViewModel)が、**まったく同じ母体**に対して名前で
/// 照合する必要が出たので切り出した ―― 2か所で別々に数えると、「メタデータの編集に出ている
/// のに、読み込みでは見つからない本」が生まれる。
@MainActor
enum KnownBooks {
    /// 母体になるストア一式。呼び出し側がどれも1つずつ持っている前提
    /// (AppStores。ModelContextも共有の1つ)。
    struct Sources {
        let metadataStore: BookMetadataStore
        let bookmarkStore: BookmarkStore
        let layoutStore: LayoutStore
        let favoritesStore: FavoritesStore
        let collectionStore: CollectionStore
        let modelContext: ModelContext
    }

    /// bookID(本のパス)を重複なく集める。
    static func collect(from sources: Sources) -> Set<String> {
        var bookIDs = sources.metadataStore.registeredBookIDs
        bookIDs.formUnion(sources.layoutStore.layoutBookIDs)
        bookIDs.formUnion(sources.layoutStore.coverOverrideBookIDs())
        bookIDs.formUnion(sources.layoutStore.shelfCoverBookIDs())
        bookIDs.formUnion(sources.bookmarkStore.groups.map(\.bookID))
        bookIDs.formUnion(sources.favoritesStore.allRegisteredBookIDs())
        bookIDs.formUnion(sources.collectionStore.allRegisteredBookIDs())
        // 読書位置。一度でも開いた本はすべてここに含まれるため、実質的にこれが母体になる
        // (BookReadingStateはLibraryDataPrunerによって上限件数まで自動的に間引かれる。
        // 環境設定「一般」の「データを保持する本の数」参照)。
        let readingStates = (try? sources.modelContext.fetch(FetchDescriptor<BookReadingState>())) ?? []
        bookIDs.formUnion(readingStates.map(\.bookID))
        return bookIDs
    }

    /// 照合用の鍵 → その名前を持つ本(複数ありうる)。
    ///
    /// 鍵は本の名前(フォルダはフォルダ名、ファイルは拡張子を落としたもの)を
    /// **NFCへ揃えて小文字に畳んだもの**。
    ///
    /// ■ 正規化を畳まないと日本語の本がほぼ全滅する
    /// APFSは書かれたバイト列をそのまま保つので、フォルダの本の名前はNFD(「は」+結合濁点)で
    /// 返ってくることがある。一方、手元で作ったzipのエントリ名はNFCになりがちで、素の`==`では
    /// 一致しない(zip書き出し側でNFCへ揃えているのも同じ理由。
    /// `nfcNormalizedForExport`のコメント参照)。
    ///
    /// 大文字小文字も畳む ―― macOSのファイルシステムは既定で区別しないので、`第1巻.jpg`と
    /// `第1巻.JPG`が別の本を指すことは実際には無い。
    static func matchKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// bookIDの集合から「名前 → 本」の索引を作る。
    static func index(of bookIDs: Set<String>) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for bookID in bookIDs.sorted() {
            let key = matchKey(MetadataEditorViewModel.baseName(forBookID: bookID))
            result[key, default: []].append(bookID)
        }
        return result
    }
}

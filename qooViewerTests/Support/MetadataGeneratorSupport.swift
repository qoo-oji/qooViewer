import Foundation
import QooMetaKit

@testable import qooViewer

/// メタデータ生成(`MetadataGenerator`)をテストの `InMemoryLibrary` の上に作る口(2026-09-22)。
///
/// 母体は、`books`(開いた本として渡す ―― 記録どおりの場所にあると確かめ済み)と、行のある本。実体の確かめ(`probe`)は、
/// 渡された本をすべて「ある」と答える(テストの本は架空のパスで、ディスクには無い)。記録(`MetadataCorpusStore`)は保存しない。
@MainActor
extension InMemoryLibrary {
    func makeMetadataGenerator(books: [String] = [], knownBooks: Set<String> = [],
                               corpus: MetadataCorpusStore? = nil) -> MetadataGenerator {
        let corpus = corpus ?? MetadataCorpusStore(url: nil)
        let generator = MetadataGenerator(
            metadataStore: metadata, rulesStore: metadataRules, corpusStore: corpus,
            knownBooks: { knownBooks }, probe: { Set($0) })
        for book in books { generator.noteBookOpened(book) }
        return generator
    }
}

@MainActor
extension BookMetadataStore {
    /// 行の無い本を、その本 1 冊だけのファイル名の読みで、ロックせずに作る(テストの下ごしらえ。アプリでは値を作るのは
    /// メタデータ生成だけ ―― 以前の `registerParsed` と同じ中身)。
    func registerParsedForTesting(bookID: String, rules: CompiledRules) {
        guard metadata(forBookID: bookID) == nil else { return }
        upsertAll([BatchEntry(bookID: bookID, values: MetadataParsing.values(forBookID: bookID, rules: rules),
                              state: BookMetadataRowState(isLocked: false))])
    }
}

import Foundation
import SwiftData
import Testing

@testable import qooViewer

/// 本ではないフォルダの保存データを起動時に消す(ViewModels/NonBookFolderSweeper.swift。2026-09-22、利用者の指示)。
/// ストアはテスト専用のライブラリ(InMemoryLibrary)の上。
@MainActor
struct NonBookFolderSweeperTests {
    /// メタデータと読書位置を付ける(棚を 1 冊として開いていた頃に残ったものと同じ形)。
    private func record(_ path: String, in library: InMemoryLibrary) throws {
        _ = library.metadata.upsert(bookID: path, author: "A", title: "T", series: "", seriesIndex: "", sourceURL: nil)
        library.context.insert(BookReadingState(bookID: path))
        try library.context.save()
    }

    private func readingStateIDs(_ library: InMemoryLibrary) throws -> Set<String> {
        Set(try library.context.fetch(FetchDescriptor<BookReadingState>()).map(\.bookID))
    }

    @Test("棚の保存データは消え、空のフォルダ・画像フォルダ・章ごとの画像フォルダ・見つからないフォルダ・書庫は残る")
    func onlyFoldersConfirmedNotToBeBooksAreSwept() async throws {
        let library = try InMemoryLibrary(label: "non-book-sweep")
        defer { library.close() }
        let suite = PreferencesSuite(label: "non-book-sweep")
        let temporary = try TemporaryDirectory("non-book-sweep")

        let shelf = try temporary.directory("shelf")
        try Data("a".utf8).write(to: shelf.appendingPathComponent("01.cbz"))
        let empty = try temporary.directory("empty")
        let imageFolder = try temporary.directory("images")
        try Data("a".utf8).write(to: imageFolder.appendingPathComponent("001.jpg"))
        let chapters = try temporary.directory("chapters")
        let chapter = chapters.appendingPathComponent("ch1", isDirectory: true)
        try FileManager.default.createDirectory(at: chapter, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: chapter.appendingPathComponent("001.jpg"))
        let gone = temporary.file("gone").path
        let archive = shelf.appendingPathComponent("01.cbz").path

        for path in [shelf.path, empty.path, imageFolder.path, chapters.path, gone, archive] {
            try record(path, in: library)
        }

        let swept = await NonBookFolderSweeper.sweep(
            favoritesStore: library.favorites, collectionStore: library.collections, bookmarkStore: library.bookmarks,
            layoutStore: library.layouts, metadataStore: library.metadata,
            folderAccess: FolderAccessStore(defaults: suite.defaults), modelContext: library.context)

        // 空のフォルダは、画像をいったん外へ出しただけの本かもしれないので消さない(2026-09-22 の監査)。
        #expect(swept == 1)
        let kept: Set = [empty.path, imageFolder.path, chapters.path, gone, archive]
        #expect(library.metadata.registeredBookIDs == kept)
        #expect(try readingStateIDs(library) == kept)
    }

    @Test("外付けのフォルダは、記録したボリュームの UUID が今のボリュームと一致するときだけ消す")
    func externalFoldersNeedAMatchingVolumeUUID() async throws {
        guard let volume = DisposableVolume.make(.apfs, "non-book-volume") else { return }
        let library = try InMemoryLibrary(label: "non-book-volume")
        defer { library.close() }
        let suite = PreferencesSuite(label: "non-book-volume")
        let identified = volume.url.appendingPathComponent("identified", isDirectory: true)
        let pathOnly = volume.url.appendingPathComponent("path-only", isDirectory: true)
        for folder in [identified, pathOnly] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("a".utf8).write(to: folder.appendingPathComponent("01.cbz"))
        }
        // 識別子(ボリュームの UUID を含む)つきの行と、パスだけの行(読書位置だけ)。
        _ = library.metadata.upsert(bookID: identified.path, author: "A", title: "T", series: "", seriesIndex: "",
                                    sourceURL: identified)
        library.context.insert(BookReadingState(bookID: pathOnly.path))
        try library.context.save()

        let swept = await NonBookFolderSweeper.sweep(
            favoritesStore: library.favorites, collectionStore: library.collections, bookmarkStore: library.bookmarks,
            layoutStore: library.layouts, metadataStore: library.metadata,
            folderAccess: FolderAccessStore(defaults: suite.defaults), modelContext: library.context)

        #expect(swept == 1)
        #expect(library.metadata.registeredBookIDs.isEmpty)
        #expect(try readingStateIDs(library) == [pathOnly.path], "UUID を記録していない外付けの記録は、同じ名前の別のディスクかもしれないので消さない")
    }

    @Test("書庫・PDF・EPUB の名前の本は調べない")
    func bookFilesAreNotCandidates() {
        let ids: Set = ["/a/b.cbz", "/a/c.pdf", "/a/d.epub", "/a/e.rar", "/a/folder"]
        #expect(NonBookFolderSweeper.candidates(in: ids) == ["/a/folder"])
    }
}

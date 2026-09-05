import Foundation
import Testing

@testable import qooViewer

/// 拡張子から「何のファイルか」を決める判定(Services/ArchiveReading.swift)。
///
/// ページの数え上げ・Reader の選択・入れ子書庫の解決がすべてこの数本の関数を通るため、
/// 判定が1つずれると開けないページが混ざる。判定を増やすときは Info.plist の書類の型も
/// 揃える(その一致は scripts/ci/check-extensions.sh が見ている)。
struct ArchiveClassificationTests {
    @Test("画像の判定は拡張子の大文字小文字を問わない")
    func imageDetectionIgnoresCase() {
        #expect(isImageFile("001.JPG"))
        #expect(isImageFile("folder/001.jpeg"))
        #expect(isImageFile("001.avif"))
        #expect(isImageFile("001.txt") == false)
        #expect(isImageFile("001") == false)
    }

    @Test("書庫の判定に PDF と EPUB は含めない")
    func archiveDetectionExcludesPdfAndEpub() {
        #expect(isArchiveFile("book.cbz"))
        #expect(isArchiveFile("book.CB7"))
        #expect(isArchiveFile("book.pdf") == false)
        #expect(isArchiveFile("book.epub") == false)
        #expect(isPDFFile("book.PDF"))
        #expect(isEpubFile("book.EPUB"))
    }

    @Test("拡張子から Reader の種類が決まる")
    func archiveKindFollowsTheExtension() {
        #expect(archiveKind(forFileName: "book.cbz") == .zip)
        // EPUB は zip コンテナなので読み出しは zip と同じ(読み順の解決だけが別経路)。
        #expect(archiveKind(forFileName: "book.epub") == .zip)
        #expect(archiveKind(forFileName: "book.7z") == .sevenZip)
        #expect(archiveKind(forFileName: "book.cbr") == .rar)
        #expect(archiveKind(forFileName: "book.pdf") == nil)
    }

    /// ユーザー報告 2026-09-03: Finder の「圧縮」で作った cbz に入る `__MACOSX/B_src/._001.jpg`
    /// は拡張子が .jpg なので isImageFile を通ってしまい、3ページの本が6ページになる。
    @Test("macOS が書庫に入れるリソースフォークを弾く")
    func appleDoubleEntriesAreRejected() {
        #expect(isAppleDoubleEntry("__MACOSX/B_src/._001.jpg"))
        #expect(isAppleDoubleEntry("._001.jpg"))
        // 入れ子の書庫の中にも同じ構造が現れるので、先頭要素だけを見るのでは足りない。
        #expect(isAppleDoubleEntry("inner/__MACOSX/._cover.png"))
        #expect(isAppleDoubleEntry("B_src/001.jpg") == false)
        #expect(isAppleDoubleEntry("_private/001.jpg") == false)
    }
}

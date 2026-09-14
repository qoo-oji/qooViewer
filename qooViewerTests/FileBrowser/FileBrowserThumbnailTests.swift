import CoreGraphics
import Foundation
import Testing

@testable import qooViewer

/// ファイルブラウザのアイコン表示の絵(段階 7a。Services/FileBrowserThumbnails/)。
///
/// 絵の中身は `PageImageFactory` の番号(R = ページ番号)で確かめる。キャッシュは一時フォルダのもの、提供役は
/// テストの中で作る(実物の `FileBrowserThumbnailDiskCache.shared` と AppStores の提供役には触らない)。
@MainActor
struct FileBrowserThumbnailTests {
    // MARK: - 種類

    @Test("名前で種類を決める。パッケージ・記号リンクは作らない")
    func kindByName() {
        func kind(_ name: String, folder: Bool = false, package: Bool = false, link: Bool = false) -> BookThumbnailer.Kind? {
            BookThumbnailer.kind(forName: name, isNavigableFolder: folder, isPackage: package, isSymbolicLink: link)
        }
        #expect(kind("a.JPG") == .image)
        #expect(kind("a.cbz") == .archive)
        #expect(kind("a.cb7") == .archive)
        #expect(kind("a.rar") == .archive)
        #expect(kind("a.epub") == .epub)
        #expect(kind("a.pdf") == .pdf)
        #expect(kind("chapter", folder: true) == .folder)
        #expect(kind("a.txt") == nil)
        #expect(kind("Some.app", package: true) == nil)
        #expect(kind("a.jpg", link: true) == nil)
    }

    @Test("フォルダはネットワーク越しと保護下の場所では作らない。デスクトップ等の中を見ているときの同じ場所の中は作る")
    func folderKindRespectsProtectedLocations() {
        let desktop = "/Users/someone/Desktop"
        let support = "/Users/someone/Library/Application Support"
        let prefixes = [desktop, support]
        let categories: Set<String> = [desktop]
        func folder(_ path: String) -> FileBrowserEntry {
            FileBrowserEntry(
                url: URL(fileURLWithPath: path, isDirectory: true), displayName: "", isDirectory: true, isPackage: false,
                isSymbolicLink: false, isVolume: false, fileSize: nil, typeDescription: nil, creationDate: nil,
                modificationDate: nil
            )
        }
        func kind(_ entry: FileBrowserEntry, in current: String, mountTable: MountTable = MountTable(entries: [])) -> BookThumbnailer.Kind? {
            FileBrowserThumbnailProvider.kind(
                for: entry, currentFolder: URL(fileURLWithPath: current, isDirectory: true), mountTable: mountTable,
                protectedPrefixes: prefixes, categoryPrefixes: categories
            )
        }
        // ホームを見ているときのデスクトップそのもの → 中を読むと TCC の確認が出るので作らない。
        #expect(kind(folder(desktop), in: "/Users/someone") == nil)
        // デスクトップの中を見ているときの、その中のフォルダ → 許可は済んでいる。
        #expect(kind(folder(desktop + "/Book"), in: desktop) == .folder)
        // Application Support の中は、中を見ていても作らない(アプリごとに確認が出うる)。
        #expect(kind(folder(support + "/Other"), in: support) == nil)
        // 保護下でない場所。
        #expect(kind(folder("/opt/Book"), in: "/opt") == .folder)
        // ネットワーク越し。
        let remote = MountTable(entries: [
            .init(mountPoint: "/", mountedFrom: "disk", fileSystemType: "apfs", isLocal: true, isHiddenFromBrowsing: false),
            .init(mountPoint: "/Volumes/Share", mountedFrom: "//server/share", fileSystemType: "smbfs", isLocal: false, isHiddenFromBrowsing: false),
        ])
        // (パスの検査が `/Volumes/<名前>/<名前>` を蔵書の置き場として止めるので、共有の根そのものを見る。)
        #expect(kind(folder("/Volumes/Share"), in: "/Volumes", mountTable: remote) == nil)
    }

    // MARK: - 先頭の絵の選び方

    @Test("台帳の本: 1 ページ目が書庫の直下のエントリなら、絵に選ぶエントリはそれと同じ", arguments: Fixtures.bookPaths)
    func archiveChoiceMatchesFirstPage(_ relativePath: String) async throws {
        let url = Fixtures.url(relativePath)
        guard isArchiveFile(relativePath) else { return }
        guard let book = try? await FixtureBook.load(url),
              let first = book.pages.first,
              case .archive(let locator, let entryPath) = first.source, !locator.isNested
        else { return }
        let reader = try makeArchiveReader(for: url)
        #expect(try BookThumbnailer.firstImageEntryPath(in: reader) == entryPath)
    }

    @Test("zip: __MACOSX と隠しファイルを外し、正準順(数字は数値として)の先頭を選ぶ")
    func zipPicksCanonicalFirstImage() throws {
        let temporary = try TemporaryDirectory("thumb-zip")
        var zip = ZipFixtureBuilder()
        zip.add("__MACOSX/._001.png", Data("x".utf8))
        zip.add(".hidden/000.png", PageImageFactory.png(number: 9))
        zip.add("010.png", PageImageFactory.png(number: 10))
        zip.add("b/001.png", PageImageFactory.png(number: 11))
        zip.add("2.png", PageImageFactory.png(number: 2))
        zip.add("notes.txt", text: "not a page")
        let url = temporary.file("book.cbz")
        try zip.write(to: url)
        let image = try #require(BookThumbnailer.thumbnail(of: url, kind: .archive, maxPixelSize: 512))
        #expect(PageColorReader.number(in: image) == 2)
    }

    @Test("画像の無い書庫・壊れた書庫は絵を作らない")
    func archiveWithoutImages() throws {
        #expect(BookThumbnailer.thumbnail(of: Fixtures.url("zip/zip-no-images.cbz"), kind: .archive, maxPixelSize: 512) == nil)
        #expect(BookThumbnailer.thumbnail(of: Fixtures.url("zip/zip-not-a-zip.cbz"), kind: .archive, maxPixelSize: 512) == nil)
    }

    @Test("フォルダ: 直下の画像のうち正準順の先頭。隠しファイル・UF_HIDDEN・サブフォルダの中は見ない")
    func folderPicksDirectImages() throws {
        let temporary = try TemporaryDirectory("thumb-folder")
        let folder = try FixtureFolder.make(at: temporary.file("Book"), pages: [
            .init("10.png", number: 10),
            .init("3.jpg", number: 3),
            .init(".0.png", number: 1),
            .init("0-flagged.png", number: 4),
            .init("0-sub/001.png", number: 5),
        ], extraFiles: ["00.txt": "text"])
        #expect(chflags(folder.appendingPathComponent("0-flagged.png").path, UInt32(UF_HIDDEN)) == 0)
        #expect(BookThumbnailer.firstImageFile(inFolder: folder)?.lastPathComponent == "3.jpg")
        let image = try #require(BookThumbnailer.thumbnail(of: folder, kind: .folder, maxPixelSize: 512))
        #expect(abs((PageColorReader.number(in: image) ?? 0) - 3) <= 2)

        let chaptersOnly = try FixtureFolder.make(at: temporary.file("Chapters"), pages: [.init("ch1/001.png", number: 1)])
        #expect(BookThumbnailer.thumbnail(of: chaptersOnly, kind: .folder, maxPixelSize: 512) == nil)
    }

    @Test("EPUB は spine の先頭、PDF は 1 ページ目")
    func epubAndPDF() throws {
        let temporary = try TemporaryDirectory("thumb-docs")
        var epub = EpubFixtureBuilder.pages(3)
        epub.manifestReversed = true
        let epubURL = temporary.file("book.epub")
        try epub.write(to: epubURL)
        let epubImage = try #require(BookThumbnailer.thumbnail(of: epubURL, kind: .epub, maxPixelSize: 512))
        #expect(PageColorReader.number(in: epubImage) == 1)

        let pdfURL = temporary.file("book.pdf")
        try PDFFixtureBuilder.write(to: pdfURL, pageNumbers: [7, 8], imageFormat: .png)
        let pdfImage = try #require(BookThumbnailer.thumbnail(of: pdfURL, kind: .pdf, maxPixelSize: 300))
        #expect(abs((PageColorReader.number(in: pdfImage) ?? 0) - 7) <= 2)
        // 長辺が要求の大きさになる(PDF はページの pt より大きく描ける)。
        #expect(max(pdfImage.width, pdfImage.height) == 300)
    }

    @Test("画像は長辺を縮めて読む。小さい画像は拡大しない")
    func imageDownsampling() throws {
        let temporary = try TemporaryDirectory("thumb-image")
        let url = temporary.file("page.png")
        try PageImageFactory.png(number: 5).write(to: url)
        let image = try #require(BookThumbnailer.thumbnail(of: url, kind: .image, maxPixelSize: 512))
        #expect(image.width == PageImageFactory.width)
        #expect(PageColorReader.number(in: image) == 5)
    }

    @Test("JPEG にするとき透明な地は白になる")
    func jpegFlattensTransparencyOnWhite() throws {
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: 4, height: 4))
        let transparent = try #require(context.makeImage())
        let jpeg = try #require(FileBrowserThumbnailProvider.jpegData(from: transparent))
        #expect((PageColorReader.number(in: jpeg) ?? 0) > 245)
    }

    // MARK: - 鍵とディスクキャッシュ

    @Test("鍵は名前を変えても同じ、中身(サイズ・更新日時)が変わると別")
    func keyFollowsContentNotName() throws {
        let temporary = try TemporaryDirectory("thumb-key")
        let url = temporary.file("a.png")
        try PageImageFactory.png(number: 1).write(to: url)
        let table = MountTable.current()
        let original = try #require(FileBrowserThumbnailKey.of(url, mountTable: table))
        let renamed = temporary.file("b.png")
        try FileManager.default.moveItem(at: url, to: renamed)
        #expect(FileBrowserThumbnailKey.of(renamed, mountTable: table) == original)
        try PageImageFactory.png(number: 1, wide: true).write(to: renamed)
        let rewritten = try #require(FileBrowserThumbnailKey.of(renamed, mountTable: table))
        #expect(rewritten != original)
        #expect(rewritten.fileName != original.fileName)
    }

    @Test("ディスクキャッシュ: 書いて読める、無効なら読まない・書かない、無効にすると消える")
    func diskCacheRoundTripAndDisable() async throws {
        let temporary = try TemporaryDirectory("thumb-disk")
        let directory = temporary.file("cache")
        let cache = FileBrowserThumbnailDiskCache(directory: directory)
        let key = FileBrowserThumbnailKey(volume: "v", inode: 1, modified: 2, size: 3)
        let data = PageImageFactory.jpeg(number: 4)
        await cache.store(data, for: key)
        #expect(await cache.data(for: key) == data)
        #expect(await cache.totalBytes() == data.count)

        await cache.configure(isEnabled: false, maxTotalBytes: 1024 * 1024, generation: 1)
        #expect(await cache.data(for: key) == nil)
        // 削除は裏で走るので、消えるまで少し待つ。
        for _ in 0..<100 where FileManager.default.fileExists(atPath: directory.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await cache.store(data, for: key)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        // 古い世代の設定は捨てる。
        await cache.configure(isEnabled: true, maxTotalBytes: 1024 * 1024, generation: 1)
        #expect(await cache.isEnabled == false)
    }

    // MARK: - 提供役

    private func entry(_ url: URL, in folder: URL) throws -> FileBrowserEntry {
        try #require(FileBrowserListing.entries(in: folder).first { $0.url.lastPathComponent == url.lastPathComponent })
    }

    @Test("提供役: 1 回目は作り、2 回目はメモリ、別の提供役でもディスクから読む(作り直さない)")
    func providerCachesInMemoryAndOnDisk() async throws {
        let temporary = try TemporaryDirectory("thumb-provider")
        let folder = try temporary.directory("shelf")
        var zip = ZipFixtureBuilder()
        zip.add("001.png", PageImageFactory.png(number: 1))
        let url = folder.appendingPathComponent("book.cbz")
        try zip.write(to: url)
        let bookEntry = try entry(url, in: folder)
        let disk = FileBrowserThumbnailDiskCache(directory: temporary.file("cache"))

        let provider = FileBrowserThumbnailProvider(diskCache: disk)
        let first = try #require(await provider.thumbnail(for: bookEntry, kind: .archive, pixelSize: 128))
        #expect(provider.generatedCount == 1)
        #expect(PageColorReader.number(in: try #require(first.makeImage())) == 1)
        _ = await provider.thumbnail(for: bookEntry, kind: .archive, pixelSize: 128)
        #expect(provider.generatedCount == 1)

        let another = FileBrowserThumbnailProvider(diskCache: disk)
        let fromDisk = try #require(await another.thumbnail(for: bookEntry, kind: .archive, pixelSize: 256))
        #expect(another.generatedCount == 0)
        #expect(abs((PageColorReader.number(in: try #require(fromDisk.makeImage())) ?? 0) - 1) <= 2)
    }

    @Test("提供役: 作れなかった絵は覚えて作り直さない。中身が変われば試し直す")
    func providerRemembersFailures() async throws {
        let temporary = try TemporaryDirectory("thumb-failure")
        let folder = try temporary.directory("shelf")
        var zip = ZipFixtureBuilder()
        zip.add("notes.txt", text: "no pages")
        let url = folder.appendingPathComponent("book.cbz")
        try zip.write(to: url)
        let provider = FileBrowserThumbnailProvider(diskCache: FileBrowserThumbnailDiskCache(directory: temporary.file("cache")))

        #expect(await provider.thumbnail(for: try entry(url, in: folder), kind: .archive, pixelSize: 128) == nil)
        #expect(await provider.thumbnail(for: try entry(url, in: folder), kind: .archive, pixelSize: 256) == nil)
        #expect(provider.generatedCount == 1)

        var fixed = ZipFixtureBuilder()
        fixed.add("notes.txt", text: "now with a page")
        fixed.add("001.png", PageImageFactory.png(number: 1))
        try fixed.write(to: url)
        #expect(await provider.thumbnail(for: try entry(url, in: folder), kind: .archive, pixelSize: 128) != nil)
        #expect(provider.generatedCount == 2)
    }

    @Test("提供役: 同じ絵を同時に頼まれても 1 回だけ作る。取り消されたセルには nil が返る")
    func providerDeduplicatesAndHonorsCancellation() async throws {
        let temporary = try TemporaryDirectory("thumb-dedupe")
        let folder = try temporary.directory("shelf")
        for index in 1...8 {
            var zip = ZipFixtureBuilder()
            zip.add("001.png", PageImageFactory.png(number: UInt8(index)))
            try zip.write(to: folder.appendingPathComponent("book\(index).cbz"))
        }
        let entries = try FileBrowserListing.entries(in: folder)
        let provider = FileBrowserThumbnailProvider(diskCache: FileBrowserThumbnailDiskCache(directory: temporary.file("cache")))
        let target = try #require(entries.first)

        async let a = provider.thumbnail(for: target, kind: .archive, pixelSize: 128)
        async let b = provider.thumbnail(for: target, kind: .archive, pixelSize: 128)
        let results = await [a, b]
        #expect(results.allSatisfy { $0 != nil })
        #expect(provider.generatedCount == 1)

        // 同時に 4 件までしか走らないので、後ろに並んだ仕事を取り消すと始まる前に捨てられる。
        let tasks = entries.dropFirst().map { entry in
            Task { await provider.thumbnail(for: entry, kind: .archive, pixelSize: 128) }
        }
        tasks.forEach { $0.cancel() }
        for task in tasks {
            #expect(await task.value == nil)
        }
        await provider.waitUntilIdle()
        #expect(provider.generatedCount < entries.count)
    }

    @Test("段: 表示の大きさの 2 倍を超えるいちばん小さい段")
    func pixelTiers() {
        #expect(FileBrowserThumbnailProvider.pixelTier(forDisplaySize: 48) == 128)
        #expect(FileBrowserThumbnailProvider.pixelTier(forDisplaySize: 64) == 128)
        #expect(FileBrowserThumbnailProvider.pixelTier(forDisplaySize: 96) == 256)
        #expect(FileBrowserThumbnailProvider.pixelTier(forDisplaySize: 256) == 512)
    }
}

import Foundation
import Testing

@testable import qooViewer

/// Finder のタグの読み書き(FinderTagStore)とインスペクタの節の状態(HomeInspectorTagsModel)。期待値の形は Finder で付けたタグの実測
/// (2026-11-03、docs/14「インスペクタ」の「タグ」: `レッド\n6` と `ブルー\n4` で `FinderInfo` の 10 バイト目が 0x08)。
///
/// テストホストには Xcode が `/` の読み取りの例外を足しているので、**許可の外(`denied`)はここでは起きない** ―― 読み分けの表だけ確かめる。
/// 実物の拒否は Release と同じ権限の探査アプリで実測した(docs/14)。
struct FinderTagStoreTests {
    private static let ja = "ja"

    private static func makeFile(_ folder: URL, _ name: String = "book.cbz") -> URL {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("body\n".utf8))
        return url
    }

    private static func writeRaw(_ values: [String], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        let result = data.withUnsafeBytes { setxattr(url.path, FinderTagStore.tagsAttribute, $0.baseAddress, $0.count, 0, 0) }
        #expect(result == 0)
    }

    private static func writeFinderInfoColor(_ color: FinderTagColor, to url: URL) {
        var info = [UInt8](repeating: 0, count: 32)
        info[9] = UInt8(color.rawValue) << 1
        #expect(setxattr(url.path, FinderTagStore.finderInfoAttribute, info, 32, 0, 0) == 0)
    }

    private static func rawTags(_ url: URL) throws -> [String]? {
        let size = getxattr(url.path, FinderTagStore.tagsAttribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        _ = getxattr(url.path, FinderTagStore.tagsAttribute, &buffer, size, 0, 0)
        return try PropertyListSerialization.propertyList(from: Data(buffer), options: [], format: nil) as? [String]
    }

    private static func finderInfoColor(_ url: URL) -> FinderTagColor? {
        var buffer = [UInt8](repeating: 0, count: 32)
        guard getxattr(url.path, FinderTagStore.finderInfoAttribute, &buffer, 32, 0, 0) == 32 else { return nil }
        return FinderTagColor.fromFinderInfo(buffer)
    }

    private static func tagNames(_ url: URL) -> [String]? {
        try? URL(filePath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames
    }

    // MARK: - 形

    @Test("要素の形: 色付きは 名前\\n色番号、色無しは 名前。触らないタグは形を変えない")
    func parsesTheFinderForm() {
        #expect(FinderTag(rawValue: "レッド\n6").name == "レッド")
        #expect(FinderTag(rawValue: "レッド\n6").color == .red)
        #expect(FinderTag(rawValue: "名前").color == nil)
        #expect(FinderTag(rawValue: "名前\n0").color == nil)
        #expect(FinderTag(rawValue: "名前\n0").rawValue == "名前\n0")
        #expect(FinderTag(rawValue: "名前\nxyz").name == "名前")
        #expect(FinderTag(rawValue: "名前\nxyz").color == nil)
        #expect(FinderTag(name: "ブルー", color: .blue).rawValue == "ブルー\n4")
        #expect(FinderTag(name: "x", color: nil).rawValue == "x")
    }

    @Test("足す: 標準の色の名前なら色付き、同じ名前(大文字小文字の違いも)は足さない、空は足さない")
    func addRules() {
        let tags = [FinderTag(rawValue: "Book\n0")]
        #expect(FinderTagEdit.add(name: "レッド").applied(to: tags, localization: Self.ja)?.last?.rawValue == "レッド\n6")
        #expect(FinderTagEdit.add(name: "Red").applied(to: tags, localization: "en")?.last?.rawValue == "Red\n6")
        // ほかの言語の色の名前は、その言語の Finder でなければただの名前。
        #expect(FinderTagEdit.add(name: "Red").applied(to: tags, localization: Self.ja)?.last?.rawValue == "Red")
        #expect(FinderTagEdit.add(name: "  自作 ").applied(to: tags, localization: Self.ja)?.last?.rawValue == "自作")
        #expect(FinderTagEdit.add(name: "a\nb").applied(to: tags, localization: Self.ja)?.last?.rawValue == "a b")
        #expect(FinderTagEdit.add(name: "book").applied(to: tags, localization: Self.ja) == nil)
        #expect(FinderTagEdit.add(name: "   ").applied(to: tags, localization: Self.ja) == nil)
    }

    @Test("外す: 名前で外す。無ければ変わらない")
    func removeRules() {
        let tags = [FinderTag(rawValue: "A\n1"), FinderTag(rawValue: "B")]
        #expect(FinderTagEdit.remove(name: "a").applied(to: tags, localization: Self.ja) == [FinderTag(rawValue: "B")])
        #expect(FinderTagEdit.remove(name: "C").applied(to: tags, localization: Self.ja) == nil)
    }

    @Test("Finder の言語は OS の言語の並びから選ぶ。名前の表は全言語 7 色")
    func standardNames() {
        #expect(FinderTagColor.finderLocalization(preferredLanguages: ["ja-JP", "en-JP"]) == "ja")
        #expect(FinderTagColor.finderLocalization(preferredLanguages: ["en-US"]) == "en")
        #expect(FinderTagColor.red.name(localization: "ja") == "レッド")
        #expect(FinderTagColor.blue.name(localization: "en") == "Blue")
        #expect(FinderTagColor.gray.name(localization: "未知") == "Gray")
        for (language, names) in FinderTagColor.names {
            #expect(names.count == FinderTagColor.allCases.count, "\(language)")
        }
    }

    @Test("errno の読み分け: 拒否と「タグ無し」を分ける")
    func errnoMapping() {
        #expect(FinderTagStore.reading(forErrno: EPERM) == .denied)
        #expect(FinderTagStore.reading(forErrno: EACCES) == .denied)
        #expect(FinderTagStore.reading(forErrno: ENOENT) == .notFound)
        #expect(FinderTagStore.reading(forErrno: ENOTSUP) == .tags([]))
        #expect(FinderTagStore.reading(forErrno: EIO) == .failed(EIO))
    }

    // MARK: - 読む

    @Test("読む: タグ無し・Finder の形・無いファイル・壊れた値を読み分ける")
    func reading() throws {
        let folder = try TemporaryDirectory()
        let file = Self.makeFile(folder.url)
        #expect(FinderTagStore.read(at: file, localization: Self.ja) == .tags([]))

        try Self.writeRaw(["レッド\n6", "ブルー\n4", "自作"], to: file)
        #expect(FinderTagStore.read(at: file, localization: Self.ja)
            == .tags([FinderTag(rawValue: "レッド\n6"), FinderTag(rawValue: "ブルー\n4"), FinderTag(rawValue: "自作")]))

        #expect(FinderTagStore.read(at: folder.url.appendingPathComponent("無い.cbz"), localization: Self.ja) == .notFound)

        let broken = Self.makeFile(folder.url, "broken.cbz")
        let junk = Array("not a plist".utf8)
        #expect(setxattr(broken.path, FinderTagStore.tagsAttribute, junk, junk.count, 0, 0) == 0)
        #expect(FinderTagStore.read(at: broken, localization: Self.ja) == .corrupted)
    }

    @Test("古いラベルだけのファイルは、Finder と同じく色の名前のタグとして読む")
    func legacyLabel() throws {
        let folder = try TemporaryDirectory()
        let file = Self.makeFile(folder.url)
        Self.writeFinderInfoColor(.red, to: file)
        #expect(FinderTagStore.read(at: file, localization: Self.ja) == .tags([FinderTag(rawValue: "レッド\n6")]))
    }

    // MARK: - 書く

    @Test("足す: ほかのタグの形を保ち、FinderInfo の色を最後の色付きのタグに揃える(Finder と同じ)")
    func addKeepsOthersAndSyncsTheColor() throws {
        let folder = try TemporaryDirectory()
        let file = Self.makeFile(folder.url)
        try Self.writeRaw(["自作\n0", "レッド\n6"], to: file)

        let tags = try FinderTagStore.apply(.add(name: "ブルー"), at: file, localization: Self.ja)
        #expect(tags.map(\.rawValue) == ["自作\n0", "レッド\n6", "ブルー\n4"])
        #expect(try Self.rawTags(file) == ["自作\n0", "レッド\n6", "ブルー\n4"])
        #expect(Self.finderInfoColor(file) == .blue)
        #expect(Self.tagNames(file) == ["自作", "レッド", "ブルー"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "body\n")

        // 色付きのタグを外すと、前の色へ戻る。
        try FinderTagStore.apply(.remove(name: "ブルー"), at: file, localization: Self.ja)
        #expect(Self.finderInfoColor(file) == .red)
    }

    @Test("FinderInfo のほかのビットは変えない")
    func keepsOtherFinderInfoBits() throws {
        let folder = try TemporaryDirectory()
        let file = Self.makeFile(folder.url)
        var info = [UInt8](repeating: 0, count: 32)
        info[0] = 0x41
        info[8] = 0x40
        info[9] = 0x01
        #expect(setxattr(file.path, FinderTagStore.finderInfoAttribute, info, 32, 0, 0) == 0)
        try FinderTagStore.apply(.add(name: "レッド"), at: file, localization: Self.ja)
        var after = [UInt8](repeating: 0, count: 32)
        #expect(getxattr(file.path, FinderTagStore.finderInfoAttribute, &after, 32, 0, 0) == 32)
        #expect(after[0] == 0x41)
        #expect(after[8] == 0x40)
        #expect(after[9] == 0x01 | (6 << 1))
    }

    @Test("全部外す: タグも色も残らない(空の配列だけ書くと色が残って tagNames に出る罠)")
    func removingEverythingClearsTheColor() throws {
        let folder = try TemporaryDirectory()
        let file = Self.makeFile(folder.url)
        try Self.writeRaw(["ブルー\n4"], to: file)
        Self.writeFinderInfoColor(.blue, to: file)

        let tags = try FinderTagStore.apply(.remove(name: "ブルー"), at: file, localization: Self.ja)
        #expect(tags.isEmpty)
        #expect(Self.tagNames(file) == nil)
        #expect(Self.finderInfoColor(file) == nil)
        #expect(FinderTagStore.read(at: file, localization: Self.ja) == .tags([]))
    }

    @Test("古いラベルだけのファイルからも外せる。足せばラベルもタグとして残る")
    func editingLegacyLabel() throws {
        let folder = try TemporaryDirectory()
        let file = Self.makeFile(folder.url)
        Self.writeFinderInfoColor(.red, to: file)
        try FinderTagStore.apply(.add(name: "自作"), at: file, localization: Self.ja)
        #expect(try Self.rawTags(file) == ["レッド\n6", "自作"])

        let other = Self.makeFile(folder.url, "other.cbz")
        Self.writeFinderInfoColor(.red, to: other)
        #expect(try FinderTagStore.apply(.remove(name: "レッド"), at: other, localization: Self.ja).isEmpty)
        #expect(FinderTagStore.read(at: other, localization: Self.ja) == .tags([]))
    }

    @Test("書く直前に読み直す: 開いている間に Finder で足されたタグを消さない")
    func editsTheLatestList() throws {
        let folder = try TemporaryDirectory()
        let file = Self.makeFile(folder.url)
        try Self.writeRaw(["A"], to: file)
        // 画面が A だけを見ている間に Finder が B を足した。
        try Self.writeRaw(["A", "B\n2"], to: file)
        try FinderTagStore.apply(.add(name: "C"), at: file, localization: Self.ja)
        #expect(try Self.rawTags(file) == ["A", "B\n2", "C"])
    }

    @Test("壊れた値には上書きしない")
    func refusesToOverwriteCorruptedTags() throws {
        let folder = try TemporaryDirectory()
        let file = Self.makeFile(folder.url)
        let junk = Array("not a plist".utf8)
        #expect(setxattr(file.path, FinderTagStore.tagsAttribute, junk, junk.count, 0, 0) == 0)
        #expect(throws: FinderTagStore.WriteError.unreadable(.corrupted)) {
            try FinderTagStore.apply(.add(name: "A"), at: file, localization: Self.ja)
        }
        var after = [UInt8](repeating: 0, count: junk.count)
        #expect(getxattr(file.path, FinderTagStore.tagsAttribute, &after, junk.count, 0, 0) == junk.count)
        #expect(after == junk)
    }

    @Test("フォルダの本にも書ける")
    func folderBook() throws {
        let folder = try TemporaryDirectory()
        let book = folder.url.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: false)
        try FinderTagStore.apply(.add(name: "レッド"), at: book, localization: Self.ja)
        #expect(Self.tagNames(book) == ["レッド"])
        #expect(Self.finderInfoColor(book) == .red)
        #expect(try FinderTagStore.apply(.remove(name: "レッド"), at: book, localization: Self.ja).isEmpty)
        #expect(Self.tagNames(book) == nil)
    }

    @Test("記号リンクは先のタグを読み書きする。全部外すときも先へ届く")
    func symbolicLinkGoesToTheTarget() throws {
        let folder = try TemporaryDirectory()
        let file = Self.makeFile(folder.url)
        let link = folder.url.appendingPathComponent("link.cbz")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        try FinderTagStore.apply(.add(name: "レッド"), at: link, localization: Self.ja)
        #expect(try Self.rawTags(file) == ["レッド\n6"])
        try FinderTagStore.apply(.remove(name: "レッド"), at: link, localization: Self.ja)
        #expect(FinderTagStore.read(at: file, localization: Self.ja) == .tags([]))
        #expect(Self.finderInfoColor(file) == nil)
    }

    @Test("ネットワークボリュームには書かない(読むのはよい)")
    func networkVolumeIsReadOnly() throws {
        let folder = try TemporaryDirectory()
        NetworkVolumeReading.treatAsRemoteForTesting(folder.url)
        defer { NetworkVolumeReading.endTreatingAsRemoteForTesting(folder.url) }
        let file = Self.makeFile(folder.url)
        try Self.writeRaw(["レッド\n6"], to: file)

        #expect(FinderTagStore.read(at: file, localization: Self.ja) == .tags([FinderTag(rawValue: "レッド\n6")]))
        #expect(FinderTagStore.location(of: file).isOnNetworkVolume)
        #expect(throws: FinderTagStore.WriteError.networkVolume) {
            try FinderTagStore.apply(.add(name: "ブルー"), at: file, localization: Self.ja)
        }
        #expect(throws: FinderTagStore.WriteError.networkVolume) {
            try FinderTagStore.apply(.remove(name: "レッド"), at: file, localization: Self.ja)
        }
        #expect(try Self.rawTags(file) == ["レッド\n6"])
    }

    @Test("読み取り専用の項目は編集できないものとして読む")
    func unwritableItem() throws {
        let folder = try TemporaryDirectory()
        let file = Self.makeFile(folder.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        #expect(FinderTagStore.location(of: file).isUnwritable)
    }

    // exFAT のテストは置かない: タグは `._名前` に入り、作業フォルダを消すときに `._` だけ残るフォルダの rmdir でカーネルが固まりうる
    // (CLAUDE.md の FAT/exFAT の注意)。exFAT の足す・外す・全部外すは使い捨てのイメージで実測した(docs/14「インスペクタ」の「タグ」)。
}

/// インスペクタの節の状態。
@MainActor
struct HomeInspectorTagsModelTests {
    private static let local = FinderTagStore.Location(isOnNetworkVolume: false, isMountPoint: false, isUnwritable: false)

    @Test("変更できない理由の順: シークレット → ネットワーク → 読み取り専用モード → 書けない項目")
    func refusalOrder() {
        typealias Model = HomeInspectorTagsModel
        let network = FinderTagStore.Location(isOnNetworkVolume: true, isMountPoint: false, isUnwritable: false)
        var unwritable = Self.local
        unwritable.isUnwritable = true
        var mountPoint = Self.local
        mountPoint.isMountPoint = true

        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: false, location: Self.local) == nil)
        #expect(Model.refusal(allowsEditing: false, refusesFileChanges: false, location: Self.local) == .privateWindow)
        #expect(Model.refusal(allowsEditing: false, refusesFileChanges: true, location: network) == .privateWindow)
        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: true, location: network) == .networkVolume)
        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: false, location: network) == .networkVolume)
        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: true, location: Self.local) == .readOnlyMode)
        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: false, location: unwritable) == .notWritable)
        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: false, location: mountPoint) == .notWritable)
        // 読み終わるまでは変えさせない。
        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: false, location: nil) == .notWritable)
    }

    @Test("読む・足す・外す。続けて足しても前の変更を落とさない")
    func loadAndApply() async throws {
        let folder = try TemporaryDirectory()
        let file = folder.url.appendingPathComponent("book.cbz")
        FileManager.default.createFile(atPath: file.path, contents: Data("body\n".utf8))
        let model = HomeInspectorTagsModel()
        await model.load(HomeInspectorTagTarget(url: file))
        #expect(model.content == .tags([]))
        #expect(model.location?.isOnNetworkVolume == false)

        _ = model.apply(.add(name: "A")) { nil }
        _ = model.apply(.add(name: "B")) { nil }
        await model.apply(.add(name: "C")) { nil }?.value
        #expect(model.content == .tags(["A", "B", "C"].map(FinderTag.init(rawValue:))))
        #expect(model.applyError == nil)

        await model.apply(.remove(name: "B")) { nil }?.value
        #expect(model.content == .tags(["A", "C"].map(FinderTag.init(rawValue:))))
    }

    @Test("順番が来たときに断る条件を見直す(待っている間に読み取り専用へ切り替わったら書かない)")
    func rechecksRefusalWhenItsTurnComes() async throws {
        let folder = try TemporaryDirectory()
        let file = folder.url.appendingPathComponent("book.cbz")
        FileManager.default.createFile(atPath: file.path, contents: Data("body\n".utf8))
        let model = HomeInspectorTagsModel()
        await model.load(HomeInspectorTagTarget(url: file))
        await model.apply(.add(name: "A")) { .readOnlyMode }?.value
        #expect(model.content == .tags([]))
        #expect(FinderTagStore.read(at: file) == .tags([]))
    }

    @Test("ネットワークボリュームは読めて、変更は失敗として出す(ファイルは変わらない)")
    func networkVolumeShowsTagsAndRefusesChanges() async throws {
        let folder = try TemporaryDirectory()
        NetworkVolumeReading.treatAsRemoteForTesting(folder.url)
        defer { NetworkVolumeReading.endTreatingAsRemoteForTesting(folder.url) }
        let file = folder.url.appendingPathComponent("book.cbz")
        FileManager.default.createFile(atPath: file.path, contents: Data("body\n".utf8))
        let data = try PropertyListSerialization.data(fromPropertyList: ["レッド\n6"], format: .binary, options: 0)
        _ = data.withUnsafeBytes { setxattr(file.path, FinderTagStore.tagsAttribute, $0.baseAddress, $0.count, 0, 0) }

        let model = HomeInspectorTagsModel()
        await model.load(HomeInspectorTagTarget(url: file))
        #expect(model.content == .tags([FinderTag(rawValue: "レッド\n6")]))
        #expect(HomeInspectorTagsModel.refusal(
            allowsEditing: true, refusesFileChanges: false, location: model.location
        ) == .networkVolume)

        // 画面は淡色にするが、古い画面から来ても書かない。
        await model.apply(.add(name: "ブルー")) { nil }?.value
        #expect(model.applyError == .networkVolume)
        #expect(model.content == .tags([FinderTag(rawValue: "レッド\n6")]))
    }

    @Test("ブックマークがあれば解いた先を読み書きする(コレクションの本。記録したパスから動いていても届く)")
    func followsTheBookmark() async throws {
        let folder = try TemporaryDirectory()
        let original = folder.url.appendingPathComponent("book.cbz")
        FileManager.default.createFile(atPath: original.path, contents: Data("body\n".utf8))
        let bookmark = try original.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let moved = folder.url.appendingPathComponent("moved.cbz")
        try FileManager.default.moveItem(at: original, to: moved)

        let model = HomeInspectorTagsModel()
        await model.load(HomeInspectorTagTarget(url: original, bookmark: bookmark))
        #expect(model.content == .tags([]))
        await model.apply(.add(name: "A")) { nil }?.value
        #expect(model.content == .tags([FinderTag(rawValue: "A")]))
        #expect(FinderTagStore.read(at: moved) == .tags([FinderTag(rawValue: "A")]))
    }

    @Test("無いファイル・壊れた値は「タグ無し」と出さない")
    func unavailableIsNotEmpty() async throws {
        let folder = try TemporaryDirectory()
        let model = HomeInspectorTagsModel()
        await model.load(HomeInspectorTagTarget(url: folder.url.appendingPathComponent("無い.cbz")))
        #expect(model.content == .unavailable(.notFound))

        let broken = folder.url.appendingPathComponent("broken.cbz")
        FileManager.default.createFile(atPath: broken.path, contents: Data())
        let junk = Array("not a plist".utf8)
        #expect(setxattr(broken.path, FinderTagStore.tagsAttribute, junk, junk.count, 0, 0) == 0)
        await model.load(HomeInspectorTagTarget(url: broken))
        #expect(model.content == .unavailable(.corrupted))
    }

    @Test("相手が変わった後に、前の相手の書き込みの結果を出さない")
    func staleWriteDoesNotOverwriteNewTarget() async throws {
        let folder = try TemporaryDirectory()
        let first = folder.url.appendingPathComponent("first.cbz")
        let second = folder.url.appendingPathComponent("second.cbz")
        for file in [first, second] { FileManager.default.createFile(atPath: file.path, contents: Data()) }
        let model = HomeInspectorTagsModel()
        await model.load(HomeInspectorTagTarget(url: first))
        let writing = model.apply(.add(name: "A")) { nil }
        await model.load(HomeInspectorTagTarget(url: second))
        await writing?.value
        #expect(model.content == .tags([]))
        // 書き込み自体は、頼んだときの相手へ届く。
        #expect(FinderTagStore.read(at: first) == .tags([FinderTag(rawValue: "A")]))
        #expect(FinderTagStore.read(at: second) == .tags([]))
    }
}

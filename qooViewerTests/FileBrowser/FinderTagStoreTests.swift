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
        // 改行は LF だけではない(貼り付け)。CRLF は 1 つの区切り。
        #expect(FinderTagEdit.add(name: "a\r\nb").applied(to: tags, localization: Self.ja)?.last?.rawValue == "a b")
        #expect(FinderTagEdit.add(name: "a\rb").applied(to: tags, localization: Self.ja)?.last?.rawValue == "a b")
        #expect(FinderTagEdit.add(name: "a\u{2028}b").applied(to: tags, localization: Self.ja)?.last?.rawValue == "a b")
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

    @Test("ローカルに見えるパスでも、リンクを辿ってネットワークボリュームに着くなら書かない(途中の段のリンクも)")
    func linkLeadingToNetworkVolumeIsReadOnly() throws {
        let remote = try TemporaryDirectory()
        NetworkVolumeReading.treatAsRemoteForTesting(remote.url)
        defer { NetworkVolumeReading.endTreatingAsRemoteForTesting(remote.url) }
        let local = try TemporaryDirectory()
        let file = Self.makeFile(remote.url)
        try Self.writeRaw(["レッド\n6"], to: file)

        let fileLink = local.url.appendingPathComponent("link.cbz")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: file)
        let folderLink = local.url.appendingPathComponent("nas")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: remote.url)
        let underFolderLink = folderLink.appendingPathComponent("book.cbz")

        for url in [fileLink, underFolderLink] {
            #expect(!NetworkVolumeReading.isOnNetworkVolume(url))
            #expect(FinderTagStore.leadsToNetworkVolume(url))
            #expect(FinderTagStore.location(of: url).isOnNetworkVolume)
            #expect(throws: FinderTagStore.WriteError.networkVolume) {
                try FinderTagStore.apply(.add(name: "ブルー"), at: url, localization: Self.ja)
            }
            #expect(throws: FinderTagStore.WriteError.networkVolume) {
                try FinderTagStore.apply(.remove(name: "レッド"), at: url, localization: Self.ja)
            }
        }
        #expect(try Self.rawTags(file) == ["レッド\n6"])
        #expect(!FinderTagStore.leadsToNetworkVolume(Self.makeFile(local.url, "local.cbz")))
    }

    @Test("リンクの輪は書く先が決まらないので書かない")
    func linkLoopIsNotWritten() throws {
        let folder = try TemporaryDirectory()
        let a = folder.url.appendingPathComponent("a")
        let b = folder.url.appendingPathComponent("b")
        try FileManager.default.createSymbolicLink(atPath: a.path, withDestinationPath: b.path)
        try FileManager.default.createSymbolicLink(atPath: b.path, withDestinationPath: a.path)
        #expect(FinderTagStore.location(of: a).isUnwritable)
        #expect(throws: FinderTagStore.WriteError.unreadable(.failed(ELOOP))) {
            try FinderTagStore.apply(.add(name: "A"), at: a, localization: Self.ja)
        }
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

/// 閉包から書き換える値(`var` を捕まえると `@Sendable` 扱いの閉包で CI だけ落ちる)。
@MainActor
private final class MainActorBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
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

        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: false, fileBrowserEnabled: true, location: Self.local) == nil)
        #expect(Model.refusal(allowsEditing: false, refusesFileChanges: false, fileBrowserEnabled: true, location: Self.local) == .privateWindow)
        #expect(Model.refusal(allowsEditing: false, refusesFileChanges: true, fileBrowserEnabled: true, location: network) == .privateWindow)
        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: true, fileBrowserEnabled: true, location: network) == .networkVolume)
        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: false, fileBrowserEnabled: true, location: network) == .networkVolume)
        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: true, fileBrowserEnabled: true, location: Self.local) == .readOnlyMode)
        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: false, fileBrowserEnabled: true, location: unwritable) == .notWritable)
        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: false, fileBrowserEnabled: true, location: mountPoint) == .notWritable)
        // 読み終わるまでは変えさせない。
        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: false, fileBrowserEnabled: true, location: nil) == .notWritable)
        // ファイルブラウザが OFF なら(`refusesFileChanges` は読み取り専用と同じ扱いでも)理由はそう言う。ネットワークのほうが先。
        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: true, fileBrowserEnabled: false, location: Self.local) == .fileBrowserOff)
        #expect(Model.refusal(allowsEditing: true, refusesFileChanges: true, fileBrowserEnabled: false, location: network) == .networkVolume)
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

        _ = model.apply(.add(name: "A")) { _ in nil }
        _ = model.apply(.add(name: "B")) { _ in nil }
        await model.apply(.add(name: "C")) { _ in nil }?.value
        #expect(model.content == .tags(["A", "B", "C"].map(FinderTag.init(rawValue:))))
        #expect(model.applyError == nil)

        await model.apply(.remove(name: "B")) { _ in nil }?.value
        #expect(model.content == .tags(["A", "C"].map(FinderTag.init(rawValue:))))
    }

    @Test("順番が来たときに断る条件を見直す(待っている間に読み取り専用へ切り替わったら書かない)")
    func rechecksRefusalWhenItsTurnComes() async throws {
        let folder = try TemporaryDirectory()
        let file = folder.url.appendingPathComponent("book.cbz")
        FileManager.default.createFile(atPath: file.path, contents: Data("body\n".utf8))
        let model = HomeInspectorTagsModel()
        await model.load(HomeInspectorTagTarget(url: file))
        // 入口では通り、順番が来たときには断る。
        let asked = MainActorBox(0)
        let recorder = FeedbackRecorder()
        await UserFeedback.$recorder.withValue(recorder) {
            await model.apply(.add(name: "A")) { _ in
                asked.value += 1
                return asked.value == 1 ? nil : .readOnlyMode
            }?.value
        }
        #expect(asked.value == 2)
        #expect(model.content == .tags([]))
        #expect(FinderTagStore.read(at: file) == .tags([]))
        // 黙って捨てない。
        #expect(recorder.beeps.count == 1)
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
            allowsEditing: true, refusesFileChanges: false, fileBrowserEnabled: true, location: model.location
        ) == .networkVolume)

        // 画面は淡色にするが、古い画面から来ても書かない。
        await model.apply(.add(name: "ブルー")) { _ in nil }?.value
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
        await model.apply(.add(name: "A")) { _ in nil }?.value
        #expect(model.content == .tags([FinderTag(rawValue: "A")]))
        #expect(FinderTagStore.read(at: moved) == .tags([FinderTag(rawValue: "A")]))
    }

    @Test("順番を待つ間に別の項目を選んでも、前の項目への変更は受け付けたときの場所で判定して書く")
    func queuedEditKeepsItsOwnLocation() async throws {
        let folder = try TemporaryDirectory()
        let first = folder.url.appendingPathComponent("first.cbz")
        let second = folder.url.appendingPathComponent("second.cbz")
        for file in [first, second] { FileManager.default.createFile(atPath: file.path, contents: Data()) }
        let model = HomeInspectorTagsModel()
        await model.load(HomeInspectorTagTarget(url: first))
        // 画面と同じ判定(読めていなければ断る)。
        let policy: @MainActor (FinderTagStore.Location?) -> HomeInspectorTagsModel.EditRefusal? = {
            HomeInspectorTagsModel.refusal(allowsEditing: true, refusesFileChanges: false, fileBrowserEnabled: true, location: $0)
        }
        let recorder = FeedbackRecorder()
        await UserFeedback.$recorder.withValue(recorder) {
            model.apply(.add(name: "A"), refusal: policy)
            let queued = model.apply(.add(name: "B"), refusal: policy)
            await model.load(HomeInspectorTagTarget(url: second))
            await queued?.value
        }
        #expect(FinderTagStore.read(at: first) == .tags(["A", "B"].map(FinderTag.init(rawValue:))))
        #expect(FinderTagStore.read(at: second) == .tags([]))
        #expect(recorder.beeps.isEmpty)
    }

    @Test("選び直す前の項目へ確定できる。読み終えた次の項目へは付かず、読めていない項目へは断ってビープ")
    func commitsToThePreviousItem() async throws {
        let folder = try TemporaryDirectory()
        let first = HomeInspectorTagTarget(url: folder.url.appendingPathComponent("first.cbz"))
        let second = HomeInspectorTagTarget(url: folder.url.appendingPathComponent("second.cbz"))
        for target in [first, second] { FileManager.default.createFile(atPath: target.url.path, contents: Data()) }
        let policy: @MainActor (FinderTagStore.Location?) -> HomeInspectorTagsModel.EditRefusal? = {
            HomeInspectorTagsModel.refusal(allowsEditing: true, refusesFileChanges: false, fileBrowserEnabled: true, location: $0)
        }
        let model = HomeInspectorTagsModel()
        await model.load(first)
        // 画面の順: 相手が変わる → `onChange` が前の項目へ確定する(次の読みはまだ終わっていない)。
        let reading = Task { await model.load(second) }
        await model.apply(.add(name: "A"), to: first, refusal: policy)?.value
        await reading.value
        #expect(FinderTagStore.read(at: first.url) == .tags([FinderTag(rawValue: "A")]))
        #expect(FinderTagStore.read(at: second.url) == .tags([]))
        #expect(model.content == .tags([]))

        // 次の項目が読めた後は、前の項目の場所はもう分からない。
        let recorder = FeedbackRecorder()
        UserFeedback.$recorder.withValue(recorder) {
            #expect(model.apply(.add(name: "B"), to: first, refusal: policy) == nil)
        }
        #expect(recorder.beeps.count == 1)
        #expect(FinderTagStore.read(at: first.url) == .tags([FinderTag(rawValue: "A")]))
    }

    @Test("別の項目を選んだ後の失敗は黙らない(次の項目の欄には出さない)")
    func lateFailureIsReported() async throws {
        let remote = try TemporaryDirectory()
        NetworkVolumeReading.treatAsRemoteForTesting(remote.url)
        defer { NetworkVolumeReading.endTreatingAsRemoteForTesting(remote.url) }
        let local = try TemporaryDirectory()
        let failing = HomeInspectorTagTarget(url: remote.url.appendingPathComponent("first.cbz"))
        let next = HomeInspectorTagTarget(url: local.url.appendingPathComponent("second.cbz"))
        FileManager.default.createFile(atPath: failing.url.path, contents: Data())
        FileManager.default.createFile(atPath: next.url.path, contents: Data())

        let model = HomeInspectorTagsModel(remoteReads: HomeInspectorRemoteTagReads())
        await model.load(failing)
        let reported = MainActorBox<[HomeInspectorTagTarget]>([])
        let recorder = FeedbackRecorder()
        await UserFeedback.$recorder.withValue(recorder) {
            let writing = model.apply(.add(name: "A"), refusal: { _ in nil }, onLateFailure: { reported.value.append($0) })
            await model.load(next)
            await writing?.value
        }
        #expect(reported.value == [failing])
        #expect(recorder.beeps.count == 1)
        #expect(model.applyError == nil)
        #expect(model.content == .tags([]))
    }

    @Test("同じ項目のブックマークが更新されただけなら、読み込み中に戻さず変更の結果も出す")
    func bookmarkUpdateIsTheSameItem() async throws {
        let folder = try TemporaryDirectory()
        let file = folder.url.appendingPathComponent("book.cbz")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let bookmark = try file.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let model = HomeInspectorTagsModel()
        await model.load(HomeInspectorTagTarget(url: file))
        let writing = model.apply(.add(name: "A")) { _ in nil }
        await model.load(HomeInspectorTagTarget(url: file, bookmark: bookmark))
        await writing?.value
        #expect(model.content == .tags([FinderTag(rawValue: "A")]))
    }

    // MARK: - TCC の保護下

    private static func normalized(_ url: URL) -> String { MountTable.normalized(url.path) }

    @Test("ファイルブラウザの項目: 保護下は読まない。リンクの先も途中の段のリンクも。場所も問い合わせない")
    func protectedLocationIsNotRead() async throws {
        let folder = try TemporaryDirectory()
        let visible = folder.url.appendingPathComponent("visible", isDirectory: true)
        let protected = folder.url.appendingPathComponent("protected", isDirectory: true)
        for directory in [visible, protected] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let file = protected.appendingPathComponent("book.cbz")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let raw = try PropertyListSerialization.data(fromPropertyList: ["レッド\n6"], format: .binary, options: 0)
        _ = raw.withUnsafeBytes { setxattr(file.path, FinderTagStore.tagsAttribute, $0.baseAddress, $0.count, 0, 0) }
        let fileLink = visible.appendingPathComponent("link.cbz")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: file)
        let folderLink = visible.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: protected)
        let plainLocal = visible.appendingPathComponent("plain.cbz")
        FileManager.default.createFile(atPath: plainLocal.path, contents: Data())

        let prefix = Self.normalized(protected)
        let tagged = FinderTagStore.Reading.tags([FinderTag(rawValue: "レッド\n6")])
        #expect(FinderTagStore.read(at: file) == tagged)

        // 見ている場所は外。
        let outside = HomeInspectorTagTarget.Browsed(currentFolder: visible)
        let model = HomeInspectorTagsModel(protectedPrefixes: [prefix], categoryPrefixes: [prefix])
        for url in [file, fileLink, folderLink.appendingPathComponent("book.cbz"), protected] {
            await model.load(HomeInspectorTagTarget(url: url, browsed: outside))
            #expect(model.content == .unavailable(.protectedLocation), "\(url.lastPathComponent)")
            #expect(model.location == nil)
        }
        // 外の普通の項目は読む。
        await model.load(HomeInspectorTagTarget(url: plainLocal, browsed: outside))
        #expect(model.content == .tags([]))

        // 同じデスクトップ等の中を見ているなら読む(許可は場所ごとに済んでいる)。そこからの場所の外への出口ではない。
        let inside = HomeInspectorTagTarget.Browsed(currentFolder: protected)
        await model.load(HomeInspectorTagTarget(url: file, browsed: inside))
        #expect(model.content == .tags([FinderTag(rawValue: "レッド\n6")]))
        #expect(model.location != nil)

        // `~/Library` の中のように許可が場所ごとに済まない所は、中を見ていても読まない(絵と同じ)。
        let library = HomeInspectorTagsModel(protectedPrefixes: [prefix], categoryPrefixes: [])
        await library.load(HomeInspectorTagTarget(url: file, browsed: inside))
        #expect(library.content == .unavailable(.protectedLocation))

        // スマートライブラリ・コレクションの本は利用者が選んだ場所なので読む。
        await library.load(HomeInspectorTagTarget(url: file))
        #expect(library.content == .tags([FinderTag(rawValue: "レッド\n6")]))
    }

    // MARK: - 応答しない共有

    /// 読みを止めておける箱(応答しない共有の代わり)。
    nonisolated private final class ReadGate: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var started: [String] = []

        func enter(_ target: HomeInspectorTagTarget) {
            lock.withLock { started.append(target.url.lastPathComponent) }
            release.wait()
        }
        func open(_ count: Int = 1) { for _ in 0..<count { release.signal() } }
        var names: [String] { lock.withLock { started } }
    }

    @Test("ネットワーク越しの読みは 1 度に 1 本。選び直しでスレッドを増やさず、返った後に読むのは最新の頼みだけ")
    func remoteReadsDoNotPileUp() async throws {
        let remote = try TemporaryDirectory()
        NetworkVolumeReading.treatAsRemoteForTesting(remote.url)
        defer { NetworkVolumeReading.endTreatingAsRemoteForTesting(remote.url) }
        let targets = ["a.cbz", "b.cbz", "c.cbz"].map { HomeInspectorTagTarget(url: remote.url.appendingPathComponent($0)) }
        for target in targets { FileManager.default.createFile(atPath: target.url.path, contents: Data()) }

        let gate = ReadGate()
        defer { gate.open(8) }
        let lane = HomeInspectorRemoteTagReads()
        let model = HomeInspectorTagsModel(remoteReads: lane, beforeRead: { gate.enter($0) })
        let first = Task { await model.load(targets[0]) }
        #expect(await eventuallyHere { gate.names == ["a.cbz"] })

        // a が返らない間に選び直す。節が作り直されても(別の model でも)同じ列に並ぶ。
        let second = Task { await model.load(targets[1]) }
        let other = HomeInspectorTagsModel(remoteReads: lane, beforeRead: { gate.enter($0) })
        let third = Task { await model.load(targets[2]) }
        let fourth = Task { await other.load(targets[1]) }
        // 待ち: 起きないこと(選び直しの 0.2 秒の待ちより長く、a の後ろに並んだままか)。
        try await Task.sleep(for: .milliseconds(500))
        #expect(gate.names == ["a.cbz"])

        gate.open(8)
        await first.value
        await second.value
        await third.value
        await fourth.value
        #expect(model.content == .tags([]))
        #expect(other.content == .tags([]))
        // 読んだのは a・c(model の最新)・b(other の頼み)の 3 回。model の古い b の頼みは読まれない(読めば 4 回になる)。
        #expect(gate.names.sorted() == ["a.cbz", "b.cbz", "c.cbz"])
        #expect(gate.names.first == "a.cbz")
    }

    @Test("ローカルの項目は、応答しない共有の読みに待たされない")
    func localReadsDoNotWaitForTheShare() async throws {
        let remote = try TemporaryDirectory()
        NetworkVolumeReading.treatAsRemoteForTesting(remote.url)
        defer { NetworkVolumeReading.endTreatingAsRemoteForTesting(remote.url) }
        let local = try TemporaryDirectory()
        let stuck = HomeInspectorTagTarget(url: remote.url.appendingPathComponent("a.cbz"))
        let plain = HomeInspectorTagTarget(url: local.url.appendingPathComponent("b.cbz"))
        for target in [stuck, plain] { FileManager.default.createFile(atPath: target.url.path, contents: Data()) }

        let gate = ReadGate()
        defer { gate.open(4) }
        let lane = HomeInspectorRemoteTagReads()
        let blocked = HomeInspectorTagsModel(remoteReads: lane, beforeRead: { gate.enter($0) })
        let first = Task { await blocked.load(stuck) }
        #expect(await eventuallyHere { gate.names == ["a.cbz"] })

        let model = HomeInspectorTagsModel(remoteReads: lane)
        await model.load(plain)
        #expect(model.content == .tags([]))
        gate.open()
        await first.value
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
        let writing = model.apply(.add(name: "A")) { _ in nil }
        await model.load(HomeInspectorTagTarget(url: second))
        await writing?.value
        #expect(model.content == .tags([]))
        // 書き込み自体は、頼んだときの相手へ届く。
        #expect(FinderTagStore.read(at: first) == .tags([FinderTag(rawValue: "A")]))
        #expect(FinderTagStore.read(at: second) == .tags([]))
    }
}

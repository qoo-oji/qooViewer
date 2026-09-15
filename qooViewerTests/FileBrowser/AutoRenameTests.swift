import Darwin
import Foundation
import Testing

@testable import qooViewer

/// 自動リネームの名前の決め方と書き終わりの判定(Models/AutoRename.swift)。設計は docs/plans/auto-rename-study.md。
struct AutoRenameTests {
    /// 登録済みの拡張子は機械で変わるので固定の表(BulkRenameTests と同じ理由)。
    private nonisolated static let registered: Set<String> = ["txt", "jpg", "png", "zip", "cbz", "rar", "pdf", "epub"]

    private nonisolated static func isRegistered(_ ext: String) -> Bool {
        registered.contains(ext.lowercased())
    }

    private func decide(
        _ name: String, isDirectory: Bool = false, _ rules: [AutoRename.RuleText], existing: [String] = []
    ) -> AutoRename.Decision {
        AutoRename.decide(
            name: name, isDirectory: isDirectory, rules: rules, existingNames: Set(existing + [name]),
            isRegistered: Self.isRegistered
        )
    }

    private func rule(_ find: String, _ replace: String, caseSensitive: Bool = false, folders: Bool = false) -> AutoRename.RuleText {
        .init(find: find, replaceWith: replace, isCaseSensitive: caseSensitive, includesFolders: folders)
    }

    // MARK: - 置き換え

    @Test("置き換えは全部の出現。大文字小文字は規則ごとに選ぶ(既定は区別しない)")
    func caseSensitivityIsPerRule() {
        #expect(decide("Tag tag TAG.zip", [rule("tag", "x")]) == .rename(to: "x x x.zip"))
        #expect(decide("Tag tag TAG.zip", [rule("tag", "x", caseSensitive: true)]) == .rename(to: "Tag x TAG.zip"))
        #expect(decide("abc.zip", [rule("zzz", "x")]) == .unchanged)
    }

    @Test("登録済みの拡張子には掛けない(一括リネームと違う)")
    func registeredExtensionIsLeftAlone() {
        #expect(decide("c.txt", [rule("txt", "qq")]) == .unchanged)
        #expect(decide("x.txt", [rule("x", "yx")]) == .skipped(.wouldKeepChanging(result: "yx.txt")))
        #expect(decide("pack.zip.cbz", [rule("zip", "z")]) == .unchanged)
        // 登録されていない拡張子は名前の一部。
        #expect(decide("a.b.q", [rule(".q", "")]) == .rename(to: "a.b"))
    }

    @Test("規則は上から順にかける")
    func rulesApplyInOrder() {
        // 「_ を空白に」の後に「空白 2 つを 1 つに」。逆順だと空白 2 つが残る。
        #expect(decide("a__b.zip", [rule("_", " "), rule("  ", " ")]) == .rename(to: "a b.zip"))
        #expect(decide("a__b.zip", [rule("  ", " "), rule("_", " ")]) == .skipped(.wouldKeepChanging(result: "a  b.zip")))
    }

    @Test("フォルダには「フォルダの名前も変える」規則だけをかける")
    func foldersOnlyGetFolderRules() {
        #expect(decide("tag folder", isDirectory: true, [rule("tag", "x")]) == .unchanged)
        #expect(decide("tag folder", isDirectory: true, [rule("tag", "x", folders: true)]) == .rename(to: "x folder"))
        #expect(decide("tag folder", isDirectory: true, [rule("tag", "x"), rule("folder", "dir", folders: true)])
                == .rename(to: "tag dir"))
    }

    // MARK: - 変え続けない

    @Test("もう一度かけると変わる規則では変えない(a → aa)")
    func growingReplacementIsSkipped() {
        #expect(decide("a.txt", [rule("a", "aa")]) == .skipped(.wouldKeepChanging(result: "aa.txt")))
    }

    @Test("互いに戻し合う 2 つの規則では変えない")
    func mutuallyReversingRulesAreSkipped() {
        // A → B → A で 1 回目は元に戻る(変わらない)。
        #expect(decide("A.txt", [rule("A", "B"), rule("B", "A")]) == .unchanged)
        // B → C, C → B でも同じ。変わるのは 1 回目で結果が揺れるときだけ。
        #expect(decide("x.txt", [rule("x", "yx")]) == .skipped(.wouldKeepChanging(result: "yx.txt")))
    }

    @Test("大文字小文字だけを変える規則は落ち着く")
    func caseOnlyChangeSettles() {
        #expect(decide("vol.zip", [rule("vol", "Vol")]) == .rename(to: "Vol.zip"))
        #expect(decide("Vol.zip", [rule("vol", "Vol")]) == .unchanged)
    }

    // MARK: - 衝突と使えない名前

    @Test("重なる名前は name 2 で避ける")
    func collisionIsAvoidedWithNumber() {
        #expect(decide("a [x].zip", [rule(" [x]", "")], existing: ["a.zip"]) == .rename(to: "a 2.zip"))
        #expect(decide("a [x].zip", [rule(" [x]", "")], existing: ["a.zip", "A 2.zip"]) == .rename(to: "a 3.zip"))
    }

    @Test("避けた名前に規則がまた掛かるなら変えない")
    func avoidedNameThatWouldChangeAgainIsSkipped() {
        // 「 2」を消す規則で避けると「a 2.zip」がまた「a.zip」へ向かう。
        #expect(decide("a 2 2.zip", [rule(" 2", "")], existing: ["a.zip"]) == .skipped(.avoidedNameWouldKeepChanging(result: "a 2.zip")))
    }

    @Test("使えない名前になるなら変えない")
    func invalidResultsAreSkipped() {
        #expect(decide("x.txt", [rule("x", "")]) == .skipped(.invalidName(result: ".txt", problem: .leadingDot)))
        guard case .skipped(.invalidName(_, .invalid(.forbiddenCharacter("/")))) = decide("a-b", [rule("-", "/")]) else {
            Issue.record("/ を含む名前を断らなかった")
            return
        }
    }

    // MARK: - 規則と対象

    @Test("対象は自分自身と、サブフォルダを含めるときの配下のフォルダを覆う")
    func targetCoverage() {
        let direct = AutoRenameTarget(path: "/Volumes/X/A/", includesSubfolders: false)
        #expect(direct.path == "/Volumes/X/A")
        #expect(direct.covers(folder: "/Volumes/X/A"))
        #expect(!direct.covers(folder: "/Volumes/X/A/B"))
        let deep = AutoRenameTarget(path: "/Volumes/X/A", includesSubfolders: true)
        #expect(deep.covers(folder: "/Volumes/X/A/B/C"))
        #expect(!deep.covers(folder: "/Volumes/X/AB"))
    }

    @Test("確認済みの印は規則の中身と対象の設定が変わると外れる")
    func confirmationSignatureTracksContents() {
        var rule = AutoRenameRule(find: "a", replaceWith: "b")
        var target = AutoRenameTarget(path: "/Volumes/X/A")
        target.confirmedSignature = target.signature(for: rule)
        #expect(target.isConfirmed(for: rule))
        rule.name = "名前だけ変える"
        #expect(target.isConfirmed(for: rule), "名前は中身ではない")
        rule.isCaseSensitive = true
        #expect(!target.isConfirmed(for: rule))
        rule.isCaseSensitive = false
        target.includesSubfolders = false
        #expect(!target.isConfirmed(for: rule))
    }

    @Test("表示名は名前、無ければ中身から")
    func displayName() {
        let en = Locale(identifier: "en")
        #expect(AutoRenameRule(name: " Tags ", find: "a").displayName(locale: en) == "Tags")
        #expect(AutoRenameRule(find: "a", replaceWith: "b").displayName(locale: en) == "“a” → “b”")
        #expect(AutoRenameRule().displayName(locale: en) == "Untitled Rule")
    }

    @Test("後から足した項目の無い JSON も読める。書いて読めば同じ")
    func codableRoundTripAndDefaults() throws {
        let id = UUID()
        let old = #"[{"id":"\#(id.uuidString)","find":"a","targets":[]}]"#
        let decoded = try JSONDecoder().decode([AutoRenameRule].self, from: Data(old.utf8))
        #expect(decoded.first?.isEnabled == true)
        #expect(decoded.first?.includesFolders == false)
        #expect(decoded.first?.isCaseSensitive == false)
        let rule = AutoRenameRule(
            name: "n", find: "a", replaceWith: "b", isCaseSensitive: true, includesFolders: true,
            targets: [AutoRenameTarget(path: "/Volumes/X/A", volumeUUID: "U", bookmark: Data([1, 2]), includesSubfolders: false,
                                       state: .disabledMissing, stateBeforeMissing: .enabled, suppressesMoveSuggestion: true,
                                       confirmedSignature: "s")]
        )
        let again = try JSONDecoder().decode(AutoRenameRule.self, from: JSONEncoder().encode(rule))
        #expect(again == rule)
    }

    // MARK: - 書き終わり

    private func fileObservation(size: Int64, modifiedAgo: TimeInterval, at: Date, busy: Bool = false) -> AutoRename.Observation {
        .init(snapshot: .file(.init(size: size, modified: at.addingTimeInterval(-modifiedAgo), isBeingCopiedByFinder: busy)), at: at)
    }

    @Test("ファイル: 古ければ通し、新しければ 2 回の観測で同じときだけ。Finder のコピー中の印があれば通さない")
    func fileSettling() {
        let now = Date()
        #expect(AutoRename.isSettled(fileObservation(size: 1, modifiedAgo: 10, at: now), previous: nil))
        #expect(!AutoRename.isSettled(fileObservation(size: 1, modifiedAgo: 10, at: now, busy: true), previous: nil))
        let modified = now.addingTimeInterval(-0.2)
        let first = AutoRename.Observation(snapshot: .file(.init(size: 5, modified: modified, isBeingCopiedByFinder: false)), at: now)
        #expect(!AutoRename.isSettled(first, previous: nil))
        let later = AutoRename.Observation(snapshot: first.snapshot, at: now.addingTimeInterval(0.6))
        #expect(AutoRename.isSettled(later, previous: first))
        let grown = AutoRename.Observation(
            snapshot: .file(.init(size: 9, modified: modified, isBeingCopiedByFinder: false)), at: now.addingTimeInterval(0.6)
        )
        #expect(!AutoRename.isSettled(grown, previous: first))
    }

    @Test("フォルダ: 配下の更新時刻が全部古ければ通す。新しい項目があれば配下全部が 2 回の観測で同じときだけ")
    func folderSettling() {
        let now = Date()
        let old = CollectionAutoFolderScan.Snapshot(size: 10, modified: now.addingTimeInterval(-60))
        let fresh = CollectionAutoFolderScan.Snapshot(size: 10, modified: now.addingTimeInterval(-0.1))
        func folder(_ entries: [String: CollectionAutoFolderScan.Snapshot], busy: Bool = false, truncated: Bool = false, at: Date)
            -> AutoRename.Observation {
            .init(snapshot: .folder(.init(entries: entries, containsItemBeingCopiedByFinder: busy, isTruncated: truncated)), at: at)
        }
        #expect(AutoRename.isSettled(folder(["": old, "a.jpg": old], at: now), previous: nil))
        #expect(!AutoRename.isSettled(folder(["": old, "a.jpg": old], busy: true, at: now), previous: nil))
        // フォルダ自身が古くても、中で大きなファイルを書いていれば通さない(§9.2)。
        let writing = folder(["": old, "big.bin": fresh], at: now)
        #expect(!AutoRename.isSettled(writing, previous: nil))
        #expect(AutoRename.isSettled(folder(["": old, "big.bin": fresh], at: now.addingTimeInterval(0.6)), previous: writing))
        let grew = folder(["": old, "big.bin": .init(size: 99, modified: fresh.modified)], at: now.addingTimeInterval(0.6))
        #expect(!AutoRename.isSettled(grew, previous: writing))
        let truncated = folder(["": old, "big.bin": fresh], truncated: true, at: now)
        #expect(!AutoRename.isSettled(folder(["": old, "big.bin": fresh], truncated: true, at: now.addingTimeInterval(1)), previous: truncated))
    }

    @Test("Finder のコピー中の印(brok/MACS)を読み、フォルダの様子は配下全部を持つ")
    func snapshotsReadFinderMarkerAndWholeTree() throws {
        let temporary = try TemporaryDirectory("auto-rename-snapshot")
        let folder = try temporary.directory("book")
        let file = folder.appendingPathComponent("page.jpg")
        try Data([1, 2, 3]).write(to: file)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data([4]).write(to: folder.appendingPathComponent("sub/inner.jpg"))

        guard case .folder(let before)? = AutoRenameFileSystem.snapshot(of: folder, isDirectory: true) else {
            Issue.record("フォルダの様子を読めなかった")
            return
        }
        #expect(Set(before.entries.keys) == ["", "page.jpg", "sub", "sub/inner.jpg"])
        #expect(!before.containsItemBeingCopiedByFinder)

        var info = [UInt8](repeating: 0, count: 32)
        info.replaceSubrange(0..<8, with: AutoRenameFileSystem.finderCopyMarker)
        #expect(setxattr(folder.appendingPathComponent("sub/inner.jpg").path, "com.apple.FinderInfo", info, info.count, 0, 0) == 0)
        guard case .folder(let during)? = AutoRenameFileSystem.snapshot(of: folder, isDirectory: true),
              case .file(let inner)? = AutoRenameFileSystem.snapshot(of: folder.appendingPathComponent("sub/inner.jpg"), isDirectory: false)
        else {
            Issue.record("様子を読めなかった")
            return
        }
        #expect(during.containsItemBeingCopiedByFinder)
        #expect(inner.isBeingCopiedByFinder)
        #expect(AutoRenameFileSystem.snapshot(of: temporary.url.appendingPathComponent("missing"), isDirectory: false) == nil)
    }
}

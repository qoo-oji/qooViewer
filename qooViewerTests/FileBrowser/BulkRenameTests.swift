import Foundation
import Testing

@testable import qooViewer

/// 一括リネームの名前の決め方(Models/BulkRename.swift)。
///
/// 期待値は**この機(macOS 26.6、日本語)の Finder で実際に名前を変えた結果**(2026-09-14、使い捨てボリュームに合成名のファイル)。
/// 登録済みの拡張子はインストールされたアプリで変わるので、固定の表(`registered`)を渡す。
struct BulkRenameTests {
    /// 実測に出てきた拡張子のうち、この機で登録済みだったもの。
    /// `BulkRename.plan` の引数は nonisolated な関数型なので、既定のメインアクター隔離を外す。
    private nonisolated static let registered: Set<String> = [
        "txt", "jpg", "jpeg", "png", "pdf", "epub", "zip", "cbz", "rar", "cbr", "tar", "gz", "bz2", "tgz", "mkv", "aa", "app",
    ]

    private nonisolated static func isRegistered(_ ext: String) -> Bool {
        registered.contains(ext.lowercased())
    }

    private static let japanese = Locale(identifier: "ja")

    /// 2026-09-14 のこの機の時刻(Finder と同じく、名前に入るのはローカルの時刻)。
    private static func localDate(hour: Int, minute: Int, second: Int) throws -> Date {
        let components = DateComponents(year: 2026, month: 9, day: 14, hour: hour, minute: minute, second: second)
        return try #require(Calendar(identifier: .gregorian).date(from: components))
    }

    private func newNames(
        _ names: [String], existing: [String] = [], _ mode: BulkRename.Mode, date: Date = Date(), locale: Locale = japanese
    ) -> [String] {
        BulkRename.plan(
            names: names, existingNames: Set(names + existing), mode: mode, date: date, locale: locale,
            isRegisteredExtension: Self.isRegistered
        ).map(\.newName)
    }

    private func counter(_ custom: String, start: Int = 1) -> BulkRename.Mode {
        .format(style: .nameAndCounter, customFormat: custom, placement: .afterName, startNumber: start)
    }

    // MARK: - 拡張子

    @Test("拡張子は後ろから続く登録済みの拡張子全部。フォルダも同じ")
    func extensionsAreTrailingRegisteredOnes() {
        let names = [
            "1.2.3", "a.verylongextension", "arc.tar.bz2", "b.tgz", "c.zip.cbz", "d.tar.gz", "name.", "p.q.txt", "v1.2.jpg", "x.JPG",
        ]
        #expect(newNames(names, counter("File ")) == [
            "File 00001", "File 00002", "File 00003.tar.bz2", "File 00004.tgz", "File 00005.zip.cbz", "File 00006.tar.gz",
            "File 00007", "File 00008.txt", "File 00009.jpg", "File 00010.JPG",
        ])
        let more = [
            "a.txt.jpg", "e.epub.pdf", "g.png.txt.jpg", "h.foo.tar.gz", "k.gz", "o.1", "s.cbr.rar", "t.mkv", "w.jpg.jpg", "x.zip.q",
            "y.q.zip", "z.tar.q", "h.x y",
        ]
        #expect(newNames(more, counter("F")) == [
            "F00001.txt.jpg", "F00002.epub.pdf", "F00003.png.txt.jpg", "F00004.tar.gz", "F00005.gz", "F00006", "F00007.cbr.rar",
            "F00008.mkv", "F00009.jpg.jpg", "F00010", "F00011.zip", "F00012", "F00013",
        ])
    }

    @Test("基部が空になるところまでは剥がさない")
    func extensionSplitKeepsAStem() {
        let split = { (name: String) -> [String] in
            let parts = BulkRename.splitExtension(name, isRegistered: Self.isRegistered)
            return [parts.stem, parts.ext]
        }
        #expect(split(".txt") == [".txt", ""])
        #expect(split("jpg.jpg") == ["jpg", "jpg"])
        #expect(split("a..jpg") == ["a.", "jpg"])
    }

    // MARK: - 方式

    @Test("テキストを追加: 空白を入れず、名前の後は拡張子の前へ")
    func addText() {
        #expect(newNames(["c.zip.cbz", "f.txt", "g.app.zip", "o.1", "p.q.txt"], .addText("_x", placement: .afterName))
            == ["c_x.zip.cbz", "f_x.txt", "g_x.app.zip", "o.1_x", "p.q_x.txt"])
        #expect(newNames(["d.e"], .addText("_x", placement: .beforeName)) == ["_xd.e"])
    }

    @Test("テキストを置き換える: 大文字小文字を区別せず全部。最後の拡張子が登録済みでなくなれば元の拡張子を付け直す")
    func replaceText() {
        #expect(newNames(["aAa.txt", "banana.aa", "x.txt"], .replaceText(find: "a", replaceWith: "Z"))
            == ["ZZZ.txt", "bZnZnZ.ZZ.aa", "x.txt"])
        #expect(newNames(["a.txt", "txt.q"], .replaceText(find: "txt", replaceWith: "jpg")) == ["a.jpg", "jpg.q"])
        #expect(newNames(["c.txt", "zz"], .replaceText(find: "txt", replaceWith: "qq")) == ["c.qq.txt", "zz"])
        #expect(newNames(["d.txt", "zz"], .replaceText(find: ".txt", replaceWith: "")) == ["d.txt", "zz"])
        #expect(newNames(["b.jpeg", "zz"], .replaceText(find: "jpeg", replaceWith: "jpg")) == ["b.jpg", "zz"])
        #expect(newNames(["c.zip.cbz", "zz"], .replaceText(find: "cbz", replaceWith: "qq")) == ["c.zip.qq.cbz", "zz"])
        #expect(newNames(["c.zip.cbz", "e.zip"], .replaceText(find: "zip", replaceWith: "qq")) == ["c.qq.cbz", "e.qq.zip"])
        #expect(newNames(["x.txt", "xx.txt"], .replaceText(find: "x", replaceWith: "xx")) == ["xx.txxt.txt", "xxxx.txxt.txt"])
    }

    @Test("フォーマット: カスタムフォーマットがあれば間に何も挟まず、空なら元の名前と空白 1 つ")
    func formatJoiners() {
        let index = { (custom: String, placement: BulkRename.Placement) in
            BulkRename.Mode.format(style: .nameAndIndex, customFormat: custom, placement: placement, startNumber: 1)
        }
        #expect(newNames(["d.e", "a.txt", "f", "g.tar.gz", "h.x y"], index("ファイル ", .afterName))
            == ["ファイル 1", "ファイル 2.txt", "ファイル 3", "ファイル 4.tar.gz", "ファイル 5"])
        #expect(newNames(["d.e"], index("ファイル ", .beforeName)) == ["1ファイル "])
        #expect(newNames(["a.txt", "b.txt"], index("", .afterName)) == ["a 1.txt", "b 2.txt"])
        #expect(newNames(["a.txt"], index("", .beforeName)) == ["1 a.txt"])
        #expect(newNames(["a.txt"], .format(style: .nameAndCounter, customFormat: "", placement: .beforeName, startNumber: 1))
            == ["00001 a.txt"])
    }

    @Test("日付は Finder の書式(日本語は at なし・午前午後、英語は at 入り)。暦はグレゴリオ暦")
    func dateFormat() throws {
        let date = try Self.localDate(hour: 10, minute: 24, second: 33)
        #expect(BulkRename.dateString(date, locale: Self.japanese) == "2026-09-14 10.24.33 午前")
        #expect(BulkRename.dateString(date, locale: Locale(identifier: "en")) == "2026-09-14 at 10.24.33 AM")
        #expect(BulkRename.dateString(date, locale: Locale(identifier: "ja_JP@calendar=japanese")) == "2026-09-14 10.24.33 午前")
        let mode = BulkRename.Mode.format(style: .nameAndDate, customFormat: "", placement: .afterName, startNumber: 1)
        #expect(newNames(["a.txt"], mode, date: date) == ["a 2026-09-14 10.24.33 午前.txt"])
    }

    // MARK: - 衝突

    @Test("インデックス・カウンタは、元の名前(選んだ項目・対象外・この操作で空く名前)とぶつかると番号を進める")
    func numbersSkipTakenNames() {
        let index = { (custom: String, placement: BulkRename.Placement, start: Int) in
            BulkRename.Mode.format(style: .nameAndIndex, customFormat: custom, placement: placement, startNumber: start)
        }
        #expect(newNames(["F 1.txt", "F 2.txt", "F 3.txt"], index("F ", .afterName, 2)) == ["F 4.txt", "F 5.txt", "F 6.txt"])
        #expect(newNames(["a.txt", "b.txt", "c.txt"], existing: ["keep 2.txt"], index("keep ", .afterName, 1))
            == ["keep 1.txt", "keep 3.txt", "keep 4.txt"])
        #expect(newNames(["2keep.txt", "a.txt", "b.txt", "c.txt"], index("keep", .beforeName, 1))
            == ["1keep.txt", "3keep.txt", "4keep.txt", "5keep.txt"])
        #expect(newNames(["a.txt", "c.txt", "F00002.txt"], counter("F")) == ["F00001.txt", "F00003.txt", "F00004.txt"])
        // 自分自身の元の名前とは、ぶつからない。
        #expect(newNames(["F00001.txt", "b.txt"], counter("F")) == ["F00001.txt", "F00002.txt"])
    }

    @Test("それ以外の方式は name 2.ext で避ける(拡張子は登録済みの規則)")
    func otherModesAppendNumbers() throws {
        #expect(newNames(["a.txt", "b.txt"], existing: ["keep.txt"], .replaceText(find: "a", replaceWith: "keep")) == ["keep 2.txt", "b.txt"])
        #expect(newNames(["xa.txt", "xaa.txt", "xaaa.txt"], .replaceText(find: "a", replaceWith: "")) == ["x.txt", "x 2.txt", "x 3.txt"])
        #expect(newNames(["x.txt", "xa.txt"], .replaceText(find: "a", replaceWith: "")) == ["x.txt", "x 2.txt"])
        #expect(newNames(["ab.txt", "ba.txt"], .replaceText(find: "ab", replaceWith: "ba")) == ["ba 2.txt", "ba.txt"])
        #expect(newNames(["a.txt", "aa.txt"], .addText("a", placement: .beforeName)) == ["aa 2.txt", "aaa.txt"])
        #expect(newNames(["c.zip.cbz", "d.zip.cbz"], .replaceText(find: "d", replaceWith: "c")) == ["c.zip.cbz", "c 2.zip.cbz"])

        let date = try Self.localDate(hour: 10, minute: 32, second: 18)
        let mode = BulkRename.Mode.format(style: .nameAndDate, customFormat: "D", placement: .afterName, startNumber: 1)
        #expect(newNames(["a.txt", "b.txt", "c.txt"], mode, date: date)
            == ["D2026-09-14 10.32.18 午前.txt", "D2026-09-14 10.32.18 午前 2.txt", "D2026-09-14 10.32.18 午前 3.txt"])
        #expect(newNames(["e.zip.cbz", "f.zip.cbz"], mode, date: date)
            == ["D2026-09-14 10.32.18 午前.zip.cbz", "D2026-09-14 10.32.18 午前 2.zip.cbz"])
    }

    @Test("衝突は大文字小文字と正規化を畳んで見る")
    func collisionsFoldCaseAndNormalization() {
        #expect(newNames(["a.txt"], existing: ["KEEP.TXT"], .replaceText(find: "a", replaceWith: "keep")) == ["keep 2.txt"])
        #expect(newNames(["a.txt"], existing: ["\u{30AB}\u{3099}.txt"], .replaceText(find: "a", replaceWith: "\u{30AC}")) == ["\u{30AC} 2.txt"])
        // 大文字小文字だけを変えるのは、自分自身なので衝突ではない。
        #expect(newNames(["a.txt"], .replaceText(find: "a", replaceWith: "A")) == ["A.txt"])
    }

    // MARK: - 使えない名前・押せる条件

    @Test("先頭がドット・空・/ を含む名前は問題として印を付ける。変わらない行は問題にしない")
    func problems() {
        let plan = { (names: [String], mode: BulkRename.Mode) in
            BulkRename.plan(names: names, existingNames: Set(names), mode: mode, isRegisteredExtension: Self.isRegistered)
        }
        #expect(plan(["a.aa", "ba.txt"], .replaceText(find: "a", replaceWith: "")).map(\.problem) == [.leadingDot, nil])
        #expect(plan(["a", "b"], .replaceText(find: "a", replaceWith: "")).map(\.problem) == [.invalid(.empty), nil])
        #expect(plan(["a.txt"], .addText("x/y", placement: .afterName)).first?.problem == .invalid(.forbiddenCharacter("/")))
        #expect(BulkRename.firstProblem(in: plan(["b.txt", "a.aa"], .replaceText(find: "a", replaceWith: "")))?.originalName == "a.aa")
    }

    @Test("「名前を変更」を押せないのは、検索文字列・追加するテキストが空のときだけ")
    func canApply() {
        #expect(!BulkRename.canApply(.replaceText(find: "", replaceWith: "x")))
        #expect(BulkRename.canApply(.replaceText(find: "a", replaceWith: "")))
        #expect(!BulkRename.canApply(.addText("", placement: .afterName)))
        #expect(BulkRename.canApply(.format(style: .nameAndIndex, customFormat: "", placement: .afterName, startNumber: 1)))
    }

    @Test("先頭だけ決めても、全件で決めたときの先頭と同じ(シートの例の行)")
    func limitMatchesFullPlan() {
        let names = ["F 1.txt", "F 2.txt", "a.txt"]
        let mode = BulkRename.Mode.format(style: .nameAndIndex, customFormat: "F ", placement: .afterName, startNumber: 1)
        let full = BulkRename.plan(names: names, existingNames: Set(names), mode: mode, isRegisteredExtension: Self.isRegistered)
        let first = BulkRename.plan(names: names, existingNames: Set(names), mode: mode, limit: 1, isRegisteredExtension: Self.isRegistered)
        #expect(first == [full[0]])
    }

    @Test("開始番号の欄は数字以外を捨て、空なら 1")
    func startNumberText() {
        var settings = BulkRenameSettings()
        for (text, number) in [("0", 0), ("-3", 3), ("abc", 1), ("1.5", 15), ("007", 7), ("", 1)] {
            settings.startNumberText = text
            #expect(settings.startNumber == number, "\(text)")
        }
    }

    @Test("登録済みの判定は UTType を使う(この機で動的な型にならないもの)")
    func registeredExtensionUsesUTType() {
        #expect(BulkRename.isRegisteredExtension("txt"))
        #expect(BulkRename.isRegisteredExtension("JPG"))
        #expect(!BulkRename.isRegisteredExtension("q"))
        #expect(!BulkRename.isRegisteredExtension("x y"))
    }

    // MARK: - 件数が多いとき(2 回目の監査 16)

    @Test("同じ候補が大量に並んでも、番号の続きから探すので 2 乗にならない。自分の元の名前が前の番号に当たるときはそれを使う")
    func manyCollisionsStayLinear() throws {
        // 以前は項目ごとに 2 から数え直し、5000 件で 4.6 秒メインを止めた(2 万件なら 1 分を超える)。
        let date = try Self.localDate(hour: 9, minute: 5, second: 7)
        let mode = BulkRename.Mode.format(style: .nameAndDate, customFormat: "b ", placement: .afterName, startNumber: 1)
        let names = (0..<20_000).map { "f\($0).txt" }
        let started = ContinuousClock.now
        let renamed = newNames(names, mode, date: date)
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(Set(renamed.map(FileNameValidation.foldedForComparison)).count == names.count)

        // 自分の元の名前の例外: 2 件目の元の名前「b D 2.txt」は、1 件目が 3 まで進めた後でも 2 件目自身には空いている。
        let text = BulkRename.dateString(date, locale: Self.japanese)
        let base = "b \(text)"
        #expect(newNames(["p.txt", "\(base) 2.txt", "q.txt"], existing: ["\(base).txt"], mode, date: date) == [
            "\(base) 3.txt", "\(base) 2.txt", "\(base) 4.txt",
        ])
    }
}

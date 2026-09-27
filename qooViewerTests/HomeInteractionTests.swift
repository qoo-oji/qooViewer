import AppKit
import Foundation
import SwiftUI
import Testing

@testable import qooViewer

/// ホームの操作の統一(2026-09-27。docs/plans/home-interaction-design.md)のうち、画面を出さずに確かめられるもの。
///
/// - クリック・キーの読み方(HomeGridInteraction)―― 本棚の 2 画面とスマートライブラリが同じ規則で読む
/// - 頭文字で選ぶ(HomeTypeSelect)
/// - 識別子の型を引数にした選択(GridSelection)
/// - 落としたものの下調べ(DroppedBooks)―― 開けないものを開きに行かない・複数の本を並びにする
@MainActor
struct HomeInteractionTests {
    // MARK: - クリック

    @Test("ふつうはクリックで選び、ダブルクリックで開く。⌘ で足す/外す、⇧ で範囲")
    func clicksSelectAndDoubleClicksOpen() {
        typealias I = HomeGridInteraction
        #expect(I.clickAction(clickCount: 1, modifiers: [], opensWithSingleClick: false) == .select(.plain))
        #expect(I.clickAction(clickCount: 2, modifiers: [], opensWithSingleClick: false) == .open)
        #expect(I.clickAction(clickCount: 1, modifiers: .command, opensWithSingleClick: false) == .select(.toggle))
        #expect(I.clickAction(clickCount: 1, modifiers: .shift, opensWithSingleClick: false) == .select(.extend))
    }

    @Test("「クリック 1 回で開く」ではクリックで開き、⌘ / ⇧ で選ぶ。ダブルクリックの 2 回目は捨てる(入った先の本を開かない)")
    func singleClickOpens() {
        typealias I = HomeGridInteraction
        #expect(I.clickAction(clickCount: 1, modifiers: [], opensWithSingleClick: true) == .open)
        #expect(I.clickAction(clickCount: 2, modifiers: [], opensWithSingleClick: true) == .ignore)
        #expect(I.clickAction(clickCount: 1, modifiers: .command, opensWithSingleClick: true) == .select(.toggle))
        #expect(I.clickAction(clickCount: 1, modifiers: .shift, opensWithSingleClick: true) == .select(.extend))
    }

    // MARK: - キー

    @Test("Return・Enter・⌘↓ で開き、⌘↑・Esc で出る。矢印・Home/End・Page は動く。⌥・⌃ 付きと ⌘ のほかのキーはメニューへ")
    func keys() {
        typealias I = HomeGridInteraction
        #expect(I.keyCommand(key: .return, characters: "\r", modifiers: []) == .open)
        #expect(I.keyCommand(key: KeyEquivalent("\u{03}"), characters: "\u{03}", modifiers: []) == .open)
        #expect(I.keyCommand(key: .downArrow, characters: "", modifiers: .command) == .open)
        #expect(I.keyCommand(key: .upArrow, characters: "", modifiers: .command) == .leave)
        #expect(I.keyCommand(key: .escape, characters: "\u{1B}", modifiers: []) == .leave)
        #expect(I.keyCommand(key: .leftArrow, characters: "", modifiers: []) == .move(.left, extending: false))
        #expect(I.keyCommand(key: .downArrow, characters: "", modifiers: .shift) == .move(.down, extending: true))
        #expect(I.keyCommand(key: .home, characters: "", modifiers: []) == .jump(.first, extending: false))
        #expect(I.keyCommand(key: .pageDown, characters: "", modifiers: .shift) == .jump(.pageDown, extending: true))
        #expect(I.keyCommand(key: KeyEquivalent("a"), characters: "a", modifiers: []) == .typeSelect("a"))
        #expect(I.keyCommand(key: KeyEquivalent("a"), characters: "a", modifiers: .command) == nil)
        #expect(I.keyCommand(key: .leftArrow, characters: "", modifiers: .option) == nil)
        #expect(I.keyCommand(key: .return, characters: "\r", modifiers: .command) == nil)
    }

    // MARK: - 頭文字

    @Test("頭文字: 1 文字は今の位置の次から一巡、2 文字以上は先頭から。間が空いたら打ち直し。大小・全角半角は区別しない")
    func typeSelect() {
        var select = HomeTypeSelect()
        let names = ["Alpha", "beta", "Bravo", "ｃｈａｒｌｉｅ"]
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(select.match("b", names: names, current: nil, now: start) == 1)
        #expect(select.match("b", names: names, current: 1, now: start.addingTimeInterval(0.1)) == 2)
        // 間が空いたので打ち直し(先頭から 2 文字)。
        #expect(select.match("b", names: names, current: nil, now: start.addingTimeInterval(5)) == 1)
        #expect(select.match("r", names: names, current: 1, now: start.addingTimeInterval(5.1)) == 2)
        #expect(select.match("CH", names: names, current: nil, now: start.addingTimeInterval(10)) == 3)
        #expect(select.match("z", names: names, current: nil, now: start.addingTimeInterval(20)) == nil)
    }

    // MARK: - 選択

    @Test("UUID の選択もスマートライブラリと同じ規則(⇧ で起点からの範囲、全選択、並びから消えたものを外す)")
    func uuidSelection() {
        let ids = (0..<5).map { _ in UUID() }
        var selection = GridSelection<UUID>()
        selection.click(ids[1], .plain, order: ids)
        selection.click(ids[3], .extend, order: ids)
        #expect(selection.ids == Set(ids[1...3]))
        let moved = selection.move(.right, extending: true, order: ids, columns: 5)
        #expect(moved == ids[4])
        #expect(selection.ids == Set(ids[1...4]))
        selection.prune(to: Array(ids[0...2]))
        #expect(selection.ids == Set(ids[1...2]))
        selection.selectAll(order: ids)
        #expect(selection.ids == Set(ids))
    }

    // MARK: - 落としたものの下調べ

    private func makeArchive(_ url: URL, number: UInt8) throws {
        var builder = ZipFixtureBuilder()
        builder.add("001.png", PageImageFactory.png(number: number))
        try builder.write(to: url)
    }

    @Test("1 件: 本・画像・棚・中間フォルダは開きに行き、空のフォルダ・対応しないファイルは開かない")
    func singleDroppedItem() throws {
        let temporary = try TemporaryDirectory("dropped-single")
        let book = temporary.file("01.cbz")
        try makeArchive(book, number: 1)
        let image = temporary.file("page.png")
        try PageImageFactory.png(number: 2).write(to: image)
        let note = temporary.file("readme.txt")
        try Data("memo".utf8).write(to: note)
        let empty = try temporary.directory("empty")
        let imageFolder = try temporary.directory("pictures")
        try PageImageFactory.png(number: 3).write(to: imageFolder.appendingPathComponent("001.png"))
        let shelf = try temporary.directory("shelf")
        try makeArchive(shelf.appendingPathComponent("a.cbz"), number: 4)
        let middle = try temporary.directory("middle/inner")
        try makeArchive(middle.appendingPathComponent("b.cbz"), number: 5)

        let order = SiblingBookOrder.byName
        #expect(DroppedBooks.single(book, order: order) == .open)
        #expect(DroppedBooks.single(image, order: order) == .open)
        #expect(DroppedBooks.single(imageFolder, order: order) == .open)
        #expect(DroppedBooks.single(shelf, order: order) == .open)
        #expect(DroppedBooks.single(temporary.file("middle"), order: order) == .open)
        #expect(DroppedBooks.single(note, order: order) == .nothing)
        #expect(DroppedBooks.single(empty, order: order) == .nothing)
    }

    @Test("複数: 本だけを自然順に並べ、棚は中の本に展開する。本でないもの(画像 1 枚・空のフォルダ・対応しないファイル)は数える")
    func multipleDroppedItems() throws {
        let temporary = try TemporaryDirectory("dropped-multiple")
        let book10 = temporary.file("10.cbz")
        let book2 = temporary.file("2.cbz")
        try makeArchive(book10, number: 1)
        try makeArchive(book2, number: 2)
        let shelf = try temporary.directory("3 shelf")
        let shelfA = shelf.appendingPathComponent("a.cbz")
        let shelfB = shelf.appendingPathComponent("b.cbz")
        try makeArchive(shelfB, number: 3)
        try makeArchive(shelfA, number: 4)
        let note = temporary.file("readme.txt")
        try Data("memo".utf8).write(to: note)
        let image = temporary.file("page.png")
        try PageImageFactory.png(number: 5).write(to: image)
        let empty = try temporary.directory("empty")

        let found = DroppedBooks.multiple([book10, note, shelf, empty, book2, image, book2], order: .byName)
        #expect(found.books.map(\.lastPathComponent) == ["2.cbz", "a.cbz", "b.cbz", "10.cbz"])
        #expect(found.skipped == 3)
    }

    @Test("Dock・Finder から渡されたもの: 本は並びにして先頭を開き、本でないものは数える。全部が画像なら 1 冊、本が無ければ開かない")
    func externalOpenPreparation() throws {
        let temporary = try TemporaryDirectory("external-open")
        let book1 = temporary.file("1.cbz")
        let book2 = temporary.file("2.cbz")
        try makeArchive(book1, number: 1)
        try makeArchive(book2, number: 2)
        let note = temporary.file("readme.txt")
        try Data("memo".utf8).write(to: note)
        let image1 = temporary.file("a.png")
        let image2 = temporary.file("b.png")
        try PageImageFactory.png(number: 3).write(to: image1)
        try PageImageFactory.png(number: 4).write(to: image2)

        // LaunchServices が種類ごとに分けて届けた回をまとめたもの(テキストが先に来る)。
        let mixed = ExternalOpenPreparation.prepare([note, book2, book1], order: .byName)
        #expect(mixed.request?.urls == [book1])
        #expect(mixed.request?.sequence?.entries.map(\.path) == [book1.path, book2.path])
        #expect(mixed.skipped == 1)

        let noteOnly = ExternalOpenPreparation.prepare([note], order: .byName)
        #expect(noteOnly.request == nil)
        #expect(noteOnly.skipped == 1)

        let images = ExternalOpenPreparation.prepare([image2, image1], order: .byName)
        #expect(images.request?.urls == [image1, image2])
        #expect(images.skipped == 0)

        let single = ExternalOpenPreparation.prepare([book2], order: .byName)
        #expect(single.request?.urls == [book2])
        #expect(single.request?.sequence == nil)
    }
}

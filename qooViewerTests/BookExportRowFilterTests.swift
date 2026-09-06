import Foundation
import Testing

@testable import qooViewer

/// 書き出しウインドウの一覧の絞り込み(Models/BookExportRowFilter.swift)。
///
/// 判定に使えるのは行が持っている `bookID`(拡張子つきのフルパス)と、保存データ 3 種類の有無だけ。
/// 2 つの軸で組み合わせ方が違う ―― 保存データはチェックボックスの AND、ファイル形式は
/// ドロップダウンの単一選択 ―― のが仕様なので、そこを取り違えないように固定する。
@MainActor
struct BookExportRowFilterTests {
    // MARK: - ファイル形式

    @Test("同じ中身で拡張子だけ違うものは 1 つの選択肢にまとまっている")
    func aFormatCoversItsAlternateExtension() {
        #expect(BookExportSourceFormat.zip.matches(bookID: "/books/a.zip"))
        #expect(BookExportSourceFormat.zip.matches(bookID: "/books/a.cbz"))
        #expect(BookExportSourceFormat.rar.matches(bookID: "/books/a.rar"))
        #expect(BookExportSourceFormat.rar.matches(bookID: "/books/a.cbr"))
        #expect(BookExportSourceFormat.sevenZip.matches(bookID: "/books/a.7z"))
        #expect(BookExportSourceFormat.sevenZip.matches(bookID: "/books/a.cb7"))
        #expect(BookExportSourceFormat.pdf.matches(bookID: "/books/a.pdf"))
        #expect(BookExportSourceFormat.epub.matches(bookID: "/books/a.epub"))
    }

    @Test("拡張子の大小文字は問わない")
    func theExtensionComparisonIsCaseInsensitive() {
        #expect(BookExportSourceFormat.zip.matches(bookID: "/books/A.CBZ"))
        #expect(BookExportSourceFormat.pdf.matches(bookID: "/books/A.Pdf"))
        #expect(BookExportSourceFormat.sevenZip.matches(bookID: "/books/A.Cb7"))
    }

    @Test("フォルダは「拡張子が無い」で判定する")
    func aFolderIsIdentifiedByHavingNoExtension() {
        #expect(BookExportSourceFormat.folder.matches(bookID: "/books/シリーズ 第1巻"))
        #expect(!BookExportSourceFormat.folder.matches(bookID: "/books/a.zip"))
        // ドットを含む「フォルダ名」は拡張子ありと見なされる ―― 一覧の行が持つのはパスだけで、
        // FormatBadgeView のバッジも同じ拡張子から出しているので、見た目とは食い違わない。
        #expect(!BookExportSourceFormat.folder.matches(bookID: "/books/vol.1"))
    }

    @Test("「すべて」はフォルダを含めて必ず通す",
          arguments: ["/books/a.zip", "/books/a.pdf", "/books/a.epub", "/books/folder", "/books/a.unknown"])
    func theAllOptionMatchesEverything(bookID: String) {
        #expect(BookExportSourceFormat.all.matches(bookID: bookID))
    }

    @Test("1 冊は必ず 1 形式(どの選択肢もお互いに排他)")
    func eachBookMatchesExactlyOneFormat() {
        let ids = ["/books/a.zip", "/books/a.cbr", "/books/a.7z", "/books/a.pdf", "/books/a.epub", "/books/folder"]
        let options = BookExportSourceFormat.allCases.filter { $0 != .all }
        for id in ids {
            let matching = options.filter { $0.matches(bookID: id) }
            #expect(matching.count == 1, "\(id) に当てはまる形式: \(matching.map(\.rawValue))")
        }
    }

    @Test("一覧に載らない拡張子は「すべて」以外どれにも当てはまらない")
    func anUnknownExtensionMatchesNothingButAll() {
        let options = BookExportSourceFormat.allCases.filter { $0 != .all }
        #expect(options.allSatisfy { !$0.matches(bookID: "/books/a.txt") })
    }

    @Test("rawValue は選択肢の識別子(id と一致する)")
    func theIdentifierIsTheRawValue() {
        #expect(BookExportSourceFormat.allCases.map(\.id) == BookExportSourceFormat.allCases.map(\.rawValue))
        #expect(BookExportSourceFormat.allCases.count == 7)
    }

    // MARK: - 絞り込み全体

    @Test("条件が 1 つも無ければ絞り込みは無効")
    func anEmptyFilterIsInactive() {
        #expect(!BookExportRowFilter().isActive)
        #expect(BookExportRowFilter(requiresLayout: true).isActive)
        #expect(BookExportRowFilter(requiresBookmarks: true).isActive)
        #expect(BookExportRowFilter(requiresMetadata: true).isActive)
        #expect(BookExportRowFilter(format: .folder).isActive)
        #expect(!BookExportRowFilter(format: .all).isActive)
    }

    @Test("条件なしの絞り込みはすべての行を通す")
    func anEmptyFilterKeepsEveryRow() {
        let filter = BookExportRowFilter()
        #expect(filter.matches(bookID: "/books/a.zip", hasLayout: false, hasBookmarks: false, hasMetadata: false))
        #expect(filter.matches(bookID: "/books/folder", hasLayout: true, hasBookmarks: true, hasMetadata: true))
    }

    @Test("チェックの無い種類は条件にしない(有無を問わない)")
    func anUncheckedKindIsNotAConstraint() {
        var filter = BookExportRowFilter()
        filter.requiresLayout = true
        // レイアウトさえあれば、ブックマークとメタデータの有無は問わない。
        #expect(filter.matches(bookID: "/books/a.zip", hasLayout: true, hasBookmarks: false, hasMetadata: false))
        #expect(filter.matches(bookID: "/books/a.zip", hasLayout: true, hasBookmarks: true, hasMetadata: true))
        #expect(!filter.matches(bookID: "/books/a.zip", hasLayout: false, hasBookmarks: true, hasMetadata: true))
    }

    @Test("保存データの 3 つは AND(1 つでも欠けたら落ちる)")
    func theThreeCheckboxesAreCombinedWithAnd() {
        let filter = BookExportRowFilter(requiresLayout: true, requiresBookmarks: true, requiresMetadata: true)
        #expect(filter.matches(bookID: "/books/a.zip", hasLayout: true, hasBookmarks: true, hasMetadata: true))
        #expect(!filter.matches(bookID: "/books/a.zip", hasLayout: false, hasBookmarks: true, hasMetadata: true))
        #expect(!filter.matches(bookID: "/books/a.zip", hasLayout: true, hasBookmarks: false, hasMetadata: true))
        #expect(!filter.matches(bookID: "/books/a.zip", hasLayout: true, hasBookmarks: true, hasMetadata: false))
    }

    @Test("形式の条件も AND で効く(保存データを満たしていても形式が違えば落ちる)")
    func theFormatIsAndedWithTheCheckboxes() {
        let filter = BookExportRowFilter(requiresBookmarks: true, format: .epub)
        #expect(filter.matches(bookID: "/books/a.epub", hasLayout: false, hasBookmarks: true, hasMetadata: false))
        #expect(!filter.matches(bookID: "/books/a.zip", hasLayout: false, hasBookmarks: true, hasMetadata: false))
        #expect(!filter.matches(bookID: "/books/a.epub", hasLayout: false, hasBookmarks: false, hasMetadata: false))
    }
}

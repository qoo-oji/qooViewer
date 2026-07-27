import Foundation
import SwiftData

/// 本の特定のページに付けるブックマーク。SwiftDataで永続化する。
/// bookID には MangaBook.id (フォルダ/アーカイブファイルのパス) を使う。
@Model
final class Bookmark {
    @Attribute(.unique) var id: UUID
    var bookID: String
    var pageIndex: Int
    var name: String
    var createdAt: Date

    init(bookID: String, pageIndex: Int, name: String) {
        self.id = UUID()
        self.bookID = bookID
        self.pageIndex = pageIndex
        self.name = name
        self.createdAt = Date()
    }
}

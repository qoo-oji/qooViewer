import Foundation
import SwiftData

@testable import qooViewer

/// **1.54のスキーマの写し**(保存される属性とリレーションだけ)。
///
/// 使い捨てのストアを「1.54が書いたストア」として作り、いまのアプリで開いたときに何が残り、
/// 何が書けるかを確かめるためのもの(StorePersistenceTests)。1.54の実物を動かして作らないのは、
/// **テストホストはアプリそのもので、起動した瞬間に利用者の本物のストアを開く**から ――
/// 古いアプリを走らせると、それ自体が今回の事故(古いアプリが新しいストアの列を消す)になる。
///
/// 写しが正しいことは、指紋で担保する: ここから計算したスキーマの指紋が、1.54時代の実物の
/// ストア(2026-09-11のバックアップ)のメタデータから計算した指紋と一致すること
/// (`StorePersistenceTests.snapshotMatchesTheReleasedSchema`)。属性を1つでも書き写し損ねると
/// 一致しない。
///
/// クラス名はエンティティ名そのものなので、いまのモデルと同じ名前を**名前空間の中で**使う。
/// 既定値の式は保存される内容に影響しない(版の指紋に入らない)が、写し間違いの疑いを減らす
/// ために1.54と同じ式にしてある。
enum SchemaSnapshot_1_54 {
    static let types: [any PersistentModel.Type] = [
        BookReadingState.self, Bookmark.self, FavoriteFolder.self, FavoriteBook.self,
        BookLayoutSettings.self, PageLayoutOverride.self, BookMetadata.self,
        BookLibrary.self, BookCollection.self, CollectionItem.self,
    ]

    @Model final class BookReadingState {
        var bookID: String
        var lastPageIndex: Int
        var lastPageKey: String?
        var displayModeRaw: String
        var readingDirectionRaw: String
        var scalingModeRaw: String = "fitToScreen"
        var updatedAt: Date
        var recordedPageCount: Int?
        var recordedSourceModificationDate: Date?
        var recordedSourceFileSize: Int64?

        init(bookID: String) {
            self.bookID = bookID
            lastPageIndex = 0
            displayModeRaw = ""
            readingDirectionRaw = ""
            updatedAt = Date()
        }
    }

    @Model final class Bookmark {
        var id: UUID
        var bookID: String
        var pageIndex: Int
        var pageKey: String?
        var name: String
        var createdAt: Date
        var bookmarkData: Data?
        var updatedAt: Date = Date()
        var isEpubDerived: Bool = false
        var inodeNumber: Int64?
        var volumeDeviceNumber: Int64?
        var volumeUUID: String?

        init(bookID: String) {
            id = UUID()
            self.bookID = bookID
            pageIndex = 0
            name = ""
            createdAt = Date()
        }
    }

    @Model final class FavoriteFolder {
        var id: UUID
        var name: String
        var sortOrder: Int
        var createdAt: Date
        var updatedAt: Date = Date()
        var parent: FavoriteFolder?
        @Relationship(deleteRule: .cascade, inverse: \FavoriteFolder.parent)
        var children: [FavoriteFolder] = []
        @Relationship(deleteRule: .cascade, inverse: \FavoriteBook.folder)
        var books: [FavoriteBook] = []

        init(name: String) {
            id = UUID()
            self.name = name
            sortOrder = 0
            createdAt = Date()
        }
    }

    @Model final class FavoriteBook {
        var id: UUID
        var bookID: String
        var bookmarkData: Data
        var title: String
        var sortOrder: Int
        var addedAt: Date
        var updatedAt: Date = Date()
        var folder: FavoriteFolder?
        var inodeNumber: Int64?
        var volumeDeviceNumber: Int64?
        var volumeUUID: String?

        init(bookID: String) {
            id = UUID()
            self.bookID = bookID
            bookmarkData = Data()
            title = ""
            sortOrder = 0
            addedAt = Date()
        }
    }

    @Model final class BookLayoutSettings {
        var bookID: String
        var readingDirectionOverrideRaw: String?
        var forcedDisplayModeRaw: String?
        var pageOrderOverrideJSON: String?
        var hasEpubLayoutLock: Bool = false
        var didImportSourceLayout: Bool = false
        var recordedPageCount: Int?
        var recordedSourceModificationDate: Date?
        var recordedSourceFileSize: Int64?
        var bookmarkData: Data?
        var coverPageKey: String?
        var coverPageDisplayName: String?
        var externalCoverBookmarkData: Data?
        var externalCoverFileName: String?
        var coverCropAnchorRaw: String?
        var contrastCorrectionEnabled: Bool = false
        var updatedAt: Date = Date()
        var inodeNumber: Int64?
        var volumeDeviceNumber: Int64?
        var volumeUUID: String?

        init(bookID: String) {
            self.bookID = bookID
            updatedAt = Date()
        }
    }

    @Model final class PageLayoutOverride {
        var compositeKey: String
        var bookID: String
        var pageKey: String
        var stateRaw: String
        var updatedAt: Date = Date()

        init(bookID: String, pageKey: String, stateRaw: String) {
            compositeKey = bookID + "\u{0}" + pageKey
            self.bookID = bookID
            self.pageKey = pageKey
            self.stateRaw = stateRaw
        }
    }

    @Model final class BookMetadata {
        var bookID: String
        var author: String = ""
        var title: String = ""
        var series: String = ""
        var seriesIndex: String = ""
        var bookmarkData: Data?
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var inodeNumber: Int64?
        var volumeDeviceNumber: Int64?
        var volumeUUID: String?

        init(bookID: String) {
            self.bookID = bookID
        }
    }

    @Model final class BookLibrary {
        var id: UUID
        var name: String
        var sortOrder: Int
        var createdAt: Date
        var usesDefaultName: Bool = false
        var coverAspectRatioRaw: String = "portrait"
        var coverCropAnchorRaw: String = "center"
        var pinnedFirstCollectionID: UUID?
        var pinnedLastCollectionID: UUID?
        var coverBackgroundColorRaw: String?
        @Relationship(deleteRule: .cascade, inverse: \BookCollection.library)
        var collections: [BookCollection] = []

        init(name: String) {
            id = UUID()
            self.name = name
            sortOrder = 0
            createdAt = Date()
        }
    }

    @Model final class BookCollection {
        var id: UUID
        var name: String
        var createdAt: Date
        var updatedAt: Date
        var library: BookLibrary?
        @Relationship(deleteRule: .cascade, inverse: \CollectionItem.collection)
        var items: [CollectionItem] = []
        var autoFolderPath: String?

        init(name: String, library: BookLibrary?) {
            id = UUID()
            self.name = name
            createdAt = Date()
            updatedAt = Date()
            self.library = library
        }
    }

    @Model final class CollectionItem {
        var id: UUID
        var bookID: String
        var bookmarkData: Data
        var title: String
        var addedAt: Date
        var sortOrder: Int
        var coverStatus: Int = 0
        var coverAspect: Double = 0
        var collection: BookCollection?
        var inodeNumber: Int64?
        var volumeDeviceNumber: Int64?
        var volumeUUID: String?

        init(bookID: String, collection: BookCollection?) {
            id = UUID()
            self.bookID = bookID
            bookmarkData = Data()
            title = ""
            addedAt = Date()
            sortOrder = 0
            self.collection = collection
        }
    }
}

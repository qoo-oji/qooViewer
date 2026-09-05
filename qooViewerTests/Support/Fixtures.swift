import Foundation

@testable import qooViewer

/// `Bundle(for:)` にはクラスが要る。テストバンドル(qooViewerTests.xctest)を引くための錨。
final class FixtureAnchor {}

/// コミット済みのフィクスチャ(qooViewerTests/Fixtures/)とその台帳(manifest.json)。
///
/// `Fixtures/` は pbxproj で `explicitFolders`(フォルダ参照)にしてあるため、バンドルの
/// `Resources/Fixtures/` の下へサブフォルダごとそのまま入る。台帳の形と増やし方は
/// docs/02-project-and-build.md の「テストのフィクスチャ」。
///
/// nonisolated: `@Test(arguments: Fixtures.bookPaths)` の引数は Swift Testing がメインアクター外で
/// 評価するため。
nonisolated enum Fixtures {
    static let directory: URL = {
        guard let url = Bundle(for: FixtureAnchor.self).resourceURL?
            .appendingPathComponent("Fixtures", isDirectory: true)
        else {
            preconditionFailure("テストバンドルに Fixtures/ が無い")
        }
        return url
    }()

    static func url(_ relativePath: String) -> URL {
        directory.appendingPathComponent(relativePath)
    }

    static let manifest: FixtureManifest = {
        do {
            let data = try Data(contentsOf: url("manifest.json"))
            return try JSONDecoder().decode(FixtureManifest.self, from: data)
        } catch {
            preconditionFailure("manifest.json を読めない: \(error)")
        }
    }()

    /// 台帳に `book`(本として開いたときの期待)を持つフィクスチャの相対パス。台帳順。
    static var bookPaths: [String] {
        manifest.fixtures.filter { $0.value.book != nil }.keys.sorted()
    }
}

/// manifest.json の形。sha256 と bytes は scripts/fixtures/update-manifest.py が書き、
/// 照合は scripts/ci/check-fixtures.sh が行う。テストが見るのは `book` だけ。
nonisolated struct FixtureManifest: Decodable, Sendable {
    struct Fixture: Decodable, Sendable {
        let bytes: Int
        let sha256: String
        let howMade: String
        let purpose: String
        let book: BookExpectation?
    }

    /// 本として開いたときの期待。`sortKeys` / `pageCount` / `error` のどれか 1 つは必ずある。
    struct BookExpectation: Decodable, Sendable {
        /// `BookLoader.load` の結果の `PageRef.sortKey` の列(読み込み時の並び順そのもの)。
        let sortKeys: [String]?
        /// 既知の限界などで並びを固定しないとき、ページ数だけを見る。
        let pageCount: Int?
        /// 開けないことが正しいとき。`noPages`(BookLoaderError.noPages)か `unreadable`(それ以外の throw)。
        let error: String?
        /// `document` なら `.document`、無ければ `.fileName`。
        let pageOrderSource: String?
        /// `MangaBook.sourceLayoutHint`。無い/null なら nil を期待する。
        let layoutHint: LayoutHint?
        let note: String?
    }

    struct LayoutHint: Decodable, Sendable {
        /// `rightToLeft` / `leftToRight` / null
        let direction: String?
        /// `spread` / `single` / null
        let displayMode: String?
    }

    let schemaVersion: Int
    let fixtures: [String: Fixture]
}

/// テストから本を開く入口。**共有の構造キャッシュに触れない**(`cachesPageList: false`)ことを
/// ここで固定する ―― TEST_HOST は実物のアプリなので、手元では自分の履歴・キャッシュと同じ
/// コンテナで走る。テスト本文から `BookLoader.load` を直接呼ばないこと。
nonisolated enum FixtureBook {
    static func load(_ url: URL) async throws -> MangaBook {
        try await BookLoader.load(from: url, cachesPageList: false)
    }

    static func load(fixture relativePath: String) async throws -> MangaBook {
        try await load(Fixtures.url(relativePath))
    }
}

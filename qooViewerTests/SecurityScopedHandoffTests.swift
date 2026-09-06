import Foundation
import Testing

@testable import qooViewer

/// 別のウインドウ/タブへ渡すあいだだけスコープを開けておく橋渡し
/// (Services/SecurityScopedHandoff.swift)。
///
/// 要は**収支** ―― 開けたものは必ず閉じ、開けなかったものには手を出さない。開きっぱなしは
/// 「カーネルリソースを漏らし、使い果たすとサンドボックスへ場所を追加する能力そのものを失う」と
/// Apple が明記しているもので、この型はその取りこぼしを直したときに作られている。
///
/// 猶予(既定 10 秒)は引数で差し替え、解放の Task を `await` する。**時間で待たない**
/// (docs/13 の段階 2)。
@MainActor
struct SecurityScopedHandoffTests {
    /// 作業フォルダと、その中の「スコープを開ける URL」。
    ///
    /// **開けるかどうかは環境で変わる。** 手元(署名あり = サンドボックスの中)では素の file URL は
    /// `startAccessingSecurityScopedResource()` が false を返し、スコープ付きブックマークを解決した
    /// URL だけが true を返す。ところが**サンドボックスの外(CI は署名無し)では素の file URL でも
    /// true が返る** ―― 消費するサンドボックスが無いため(2026-09-06 に CI で実測)。
    /// そのため期待値は決め打ちにせず、`opensScope` でその環境の答えを聞いてから組む。
    private struct Environment {
        let temp: TemporaryDirectory
        /// スコープを開ける URL(この環境で作れなければ空)。
        let scoped: [URL]
        /// スコープを開けない、ただの file URL。
        let plain: [URL]

        init(scopedCount: Int, plainCount: Int) throws {
            // 先にローカルへ作る ―― self のプロパティを初期化し終える前にクロージャへ
            // 渡すと「初期化前に捕まえた」とコンパイラに止められる。
            let temp = try TemporaryDirectory("handoff")
            var scoped: [URL] = []
            for index in 0..<scopedCount {
                let url = temp.file("scoped-\(index).txt")
                try Data("x".utf8).write(to: url)
                guard let resolved = Environment.resolvingSecurityScope(url) else { break }
                scoped.append(resolved)
            }
            var plain: [URL] = []
            for index in 0..<plainCount {
                let url = temp.file("plain-\(index).txt")
                try Data("x".utf8).write(to: url)
                plain.append(url)
            }
            self.temp = temp
            // 一部しか作れなかったときは「作れない環境」として扱う(中途半端な数で見ない)。
            self.scoped = scoped.count == scopedCount ? scoped : []
            self.plain = plain
        }

        /// セキュリティスコープ付きブックマークを作って解決し直した URL。作れなければ nil。
        private static func resolvingSecurityScope(_ url: URL) -> URL? {
            guard
                let data = try? url.bookmarkData(
                    options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
                )
            else { return nil }
            var isStale = false
            guard
                let resolved = try? URL(
                    resolvingBookmarkData: data, options: [.withSecurityScope],
                    relativeTo: nil, bookmarkDataIsStale: &isStale
                ),
                Environment.opensScope(resolved)
            else { return nil }
            return resolved
        }

        /// スコープを開けるか(開けたらその場で閉じる)。
        static func opensScope(_ url: URL) -> Bool {
            let opened = url.startAccessingSecurityScopedResource()
            if opened { url.stopAccessingSecurityScopedResource() }
            return opened
        }
    }

    @Test("渡す URL が無ければ、解放の Task も作らない")
    func anEmptyHandoffDoesNothing() {
        #expect(SecurityScopedHandoff.begin([], releaseAfter: .zero) == nil)
    }

    @Test("スコープを開けない URL しか無ければ、解放の Task は作らない")
    func plainURLsNeverStartATask() throws {
        let environment = try Environment(scopedCount: 0, plainCount: 3)
        // 素の file URL でもスコープが開ける環境(サンドボックスの外。CI がそう)では
        // 前提そのものが無いので何も見ない。
        guard environment.plain.allSatisfy({ !Environment.opensScope($0) }) else { return }

        #expect(SecurityScopedHandoff.begin(environment.plain, releaseAfter: .zero) == nil)
    }

    @Test("開けた URL は、猶予のあとに 1 本の Task がまとめて閉じる")
    func everyOpenedURLIsReleasedByASingleTask() async throws {
        let environment = try Environment(scopedCount: 3, plainCount: 2)
        guard !environment.scoped.isEmpty else { return }
        let handedOver = environment.scoped + environment.plain
        // 閉じられるはずのものは「この環境で開ける URL」―― サンドボックスの中なら
        // スコープ付きの 3 つだけ、外なら素の 2 つも含めた 5 つ。
        let expected = handedOver.filter { Environment.opensScope($0) }

        // **1 件ずつ begin(_:) を呼ぶ実装に戻したら、Task は URL の数だけ生まれる。**
        // ここで見るのは「1 本の Task が、開けたものを全部閉じる」こと。
        let task = try #require(SecurityScopedHandoff.begin(handedOver, releaseAfter: .zero))
        let released = await task.value

        #expect(released.map(\.path) == expected.map(\.path))
        #expect(!released.isEmpty)
    }

    @Test("URL 1 つの形も、同じ解放の経路を通る")
    func theSingleURLFormTakesTheSamePath() async throws {
        let environment = try Environment(scopedCount: 1, plainCount: 0)
        guard let url = environment.scoped.first else { return }

        let task = try #require(SecurityScopedHandoff.begin(url, releaseAfter: .zero))
        #expect(await task.value.map(\.path) == [url.path])
    }

    @Test("既定の猶予は、ウインドウの出現を待つポーリングよりずっと長い")
    func theDefaultDelayOutlastsTheWindowPolling() {
        // 受け取り側のウインドウが現れるのを待つ各所のポーリングは 25ms × 20 回 = 0.5 秒。
        // その間つながっていれば足りるので、猶予はそれより桁で長く取ってある。
        #expect(SecurityScopedHandoff.releaseDelay >= .seconds(5))
    }
}

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
    /// 素の file URL は `startAccessingSecurityScopedResource()` が false を返す(手元で実測)。
    /// true を返す URL はセキュリティスコープ付きブックマークを解決して作る ―― ただし手元
    /// (署名あり = サンドボックスの中)で作れることは確かめてあるが、CI は署名無しで
    /// サンドボックスの外のため作れるとは限らない。作れなければ `scoped` が空になり、
    /// それを使うテストは何もしない(素の URL 側のテストは両方で意味を持つ)。
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
        // 素の file URL でもスコープが開ける環境なら、この前提が崩れるので何も見ない。
        guard environment.plain.allSatisfy({ !Environment.opensScope($0) }) else { return }

        #expect(SecurityScopedHandoff.begin(environment.plain, releaseAfter: .zero) == nil)
    }

    @Test("開けた URL は、猶予のあとに 1 本の Task がまとめて閉じる")
    func everyOpenedURLIsReleasedByASingleTask() async throws {
        let environment = try Environment(scopedCount: 3, plainCount: 2)
        guard !environment.scoped.isEmpty else { return }

        // **1 件ずつ begin(_:) を呼ぶ実装に戻したら、Task は URL の数だけ生まれる。**
        // ここで見るのは「1 本の Task が、開けた 3 つを全部閉じる」こと。
        let task = try #require(
            SecurityScopedHandoff.begin(environment.scoped + environment.plain, releaseAfter: .zero)
        )
        let released = await task.value

        // 開けなかった素の URL は最初から対象に入らない(閉じもしない)。
        #expect(released.map(\.path) == environment.scoped.map(\.path))
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

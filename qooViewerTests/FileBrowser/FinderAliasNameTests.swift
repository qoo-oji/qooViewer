import Foundation
import Testing

@testable import qooViewer

/// 「エイリアスを作成」の名前(Models/FinderAliasName.swift)。期待値は **macOS 27・日本語の Finder に作らせた名前**(2026-10-01、
/// 使い捨ての APFS ボリュームで実測。型コメント)。英語の言葉は Finder の `N3_V1`。
struct FinderAliasNameTests {
    private static func available(_ displayName: String, localization: String = "ja", taken: Set<String> = []) -> String {
        let base = FinderAliasName.baseName(displayName: displayName, localization: localization)
        return FinderAliasName.firstAvailable(base: base) { taken.contains($0) }
    }

    @Test("見えている名前の後ろに言葉を付ける(拡張子の後ろ)。見えている名前の / はディスクの :")
    func appendsTheWordingToTheShownName() {
        #expect(Self.available("photo.jpg") == "photo.jpgのエイリアス")
        #expect(Self.available("plain") == "plainのエイリアス")
        #expect(Self.available("a.b.c.txt") == "a.b.c.txtのエイリアス")
        #expect(Self.available(".dotfile") == ".dotfileのエイリアス")
        #expect(Self.available("trail.") == "trail.のエイリアス")
        // 拡張子を隠した項目・アプリは、見えている名前(拡張子無し)が基になる(呼ぶ側が localizedName を渡す)。
        #expect(Self.available("Sample") == "Sampleのエイリアス")
        #expect(Self.available("a/b") == "a:bのエイリアス")
        #expect(Self.available("photo.jpg", localization: "en") == "photo.jpg alias")
        #expect(Self.available("photo.jpg", localization: "zh_CN") == "photo.jpg的替身")
        #expect(Self.available("photo.jpg", localization: "pt_BR") == "atalho de photo.jpg")
    }

    @Test("塞がっていれば 2 から数えて最初に空いた番号を末尾に付ける。基が空いていれば番号は付けない")
    func numbersAtTheEndFromTwo() {
        #expect(Self.available("photo.jpg", taken: ["photo.jpgのエイリアス"]) == "photo.jpgのエイリアス 2")
        #expect(Self.available("photo.jpg", taken: ["photo.jpgのエイリアス", "photo.jpgのエイリアス 2"]) == "photo.jpgのエイリアス 3")
        #expect(Self.available("x", taken: ["xのエイリアス 3"]) == "xのエイリアス")
        #expect(Self.available("x", taken: ["xのエイリアス", "xのエイリアス 3"]) == "xのエイリアス 2")
        #expect(Self.available("x", taken: ["xのエイリアス", "xのエイリアス 10"]) == "xのエイリアス 2")
    }

    @Test("UTF-16 で 255 まで。基を削って言葉は残し、番号は言葉を足した名前の末尾を削って足す。文字の途中では切らない")
    func truncatesLikeFinder() {
        func name(_ count: Int) -> String { String(repeating: "b", count: count - 4) + ".txt" }
        // 249 文字 + のエイリアス = 255 はそのまま。
        #expect(Self.available(name(249)) == name(249) + "のエイリアス")
        // 250 文字なら基の末尾が削れる(.tx)。
        let long = Self.available(name(250))
        #expect(long.utf16.count == 255 && long.hasSuffix(".txのエイリアス"))
        // 番号付きは「…のエイリ 2」。
        let numbered = Self.available(name(249), taken: [name(249) + "のエイリアス"])
        #expect(numbered.utf16.count == 255 && numbered.hasSuffix(".txtのエイリ 2"))
        // 絵文字(UTF-16 で 2)を半分にしない: 127 個 → 124 個 + のエイリアス = 254。
        let emoji = Self.available(String(repeating: "😀", count: 127))
        #expect(emoji == String(repeating: "😀", count: 124) + "のエイリアス")
    }

    @Test("言葉の言語は OS の言語の並びから Finder の持つ言語を選ぶ(このアプリの表示言語ではない)")
    func picksFinderLocalization() {
        #expect(FinderAliasName.finderLocalization(preferredLanguages: ["ja-JP"]) == "ja")
        #expect(FinderAliasName.finderLocalization(preferredLanguages: ["en-JP"]) == "en")
        #expect(FinderAliasName.finderLocalization(preferredLanguages: ["zh-Hans-CN"]) == "zh_CN")
        #expect(FinderAliasName.finderLocalization(preferredLanguages: ["es-MX"]) == "es_419")
        #expect(FinderAliasName.finderLocalization(preferredLanguages: ["eo", "ja-JP"]) == "ja")
        #expect(FinderAliasName.finderLocalization(preferredLanguages: []) == "en")
        // サンドボックスの中からも OS の言語の並びが読める(テストホストで確かめる)。
        #expect(!FinderAliasName.systemPreferredLanguages().isEmpty)
    }
}

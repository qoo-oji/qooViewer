import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import qooViewer

/// Finder と同じ形の問い合わせの行(Views/FileBrowser/FileOperationPromptWindow.swift)と、報告の出し分け(`FileBrowserProblem`)。
/// ウインドウは出さない(行のビューだけを組んで寸法を見る)。寸法と折り返しは 2026-10-24 に Finder の画像と画素で突き合わせた値。
@MainActor
struct FileOperationPromptTests {
    @Test("漢字かカタカナを含む語の中では折り返さない(Finder の折り返しと同じ所で割れる)")
    func wordsWithKanjiOrKatakanaStayTogether() {
        let joined = PromptRowView.keepingWordsTogether("この場所にあります。現在コピー中の項目")
        #expect(joined.contains("現\u{2060}在"))
        #expect(joined.contains("コ\u{2060}ピ\u{2060}ー"))
        #expect(joined.contains("項\u{2060}目"))
        // 語の間・かなだけの語には挟まない。
        #expect(!joined.contains("在\u{2060}コ"))
        #expect(!joined.contains("あ\u{2060}り"))
        #expect(joined.replacingOccurrences(of: "\u{2060}", with: "") == "この場所にあります。現在コピー中の項目")
        #expect(PromptRowView.keepingWordsTogether("plain English text") == "plain English text")
    }

    @Test("名前の括り: ダイアログの行は “…”、トーストは「」(日本語だけ。英語は “…” のまま)")
    func quotesFollowTheDialogRule() {
        let ja = Locale(identifier: "ja")
        let en = Locale(identifier: "en")
        #expect("「a.zip」の移動".quotedForDialog(locale: ja) == "“a.zip”の移動")
        #expect("“a”が見つかりません。".quotedForToast(locale: ja) == "「a」が見つかりません。")
        #expect("“a” can’t be found.".quotedForToast(locale: en) == "“a” can’t be found.")
        #expect("Move of “a”".quotedForDialog(locale: en) == "Move of “a”")
        // 名前そのものの括弧は変えない(外側の 1 組だけ)。
        #expect("「「作品」第1巻.zip」の移動".quotedForDialog(locale: ja) == "“「作品」第1巻.zip”の移動")
        #expect("““作品”第1巻”が見つかりません。".quotedForToast(locale: ja) == "「“作品”第1巻」が見つかりません。")
    }

    @Test("macOS が必要とするフォルダは、Finder と同じ名前を表示言語で出す")
    func protectedLocationNamesAreLocalized() {
        let ja = Locale(identifier: "ja")
        #expect(FileOperationError.protectedLocationName(URL(fileURLWithPath: "/Applications"), locale: ja) == "アプリケーション")
        #expect(FileOperationError.protectedLocationName(URL(fileURLWithPath: "/Users/someone/Movies"), locale: ja) == "ムービー")
        #expect(FileOperationError.protectedLocationName(URL(fileURLWithPath: "/Users/someone"), locale: ja) == "someone")
    }

    @Test("失敗の一覧は、理由の文が名前を言っていれば頭に名前を重ねない")
    func failureListingDoesNotRepeatTheName() {
        let url = URL(fileURLWithPath: "/tmp/x/読めない.zip")
        let named = FailedItem(url: url, reason: "“読めない.zip”の操作を完了できませんでした。アクセス権がありません。")
        let plain = FailedItem(url: url, reason: "アクセス権がありません。")
        #expect(FileBrowserProblem.listing([named]) == "“読めない.zip”の操作を完了できませんでした。アクセス権がありません。")
        #expect(FileBrowserProblem.listing([plain]) == "読めない.zip: アクセス権がありません。")
    }

    @Test("行の寸法は Finder の実測どおり: 本文の下 10pt にボタン、ボタンは右寄せで 6pt 間隔、すべてに適用があれば 1pt 下がる")
    func rowLayoutMatchesFinder() {
        func row(_ checkbox: String?) -> PromptRowView {
            let view = PromptRowView(prompt: FileOperationPrompt(
                icon: NSWorkspace.shared.icon(for: .plainText),
                message: "“same.txt”という名前の新しい項目がすでにこの場所にあります。現在コピー中の古い項目で置き換えますか?",
                buttons: ["両方とも残す", "中止", "置き換える"], checkboxTitle: checkbox, answerWhenOwnerCloses: 1, windowTitle: "コピー"
            ), owner: nil) { _ in }
            view.layOut(width: FileOperationPromptWindow.width)
            return view
        }
        let plain = row(nil)
        #expect(abs(plain.frame.height - 62) < 0.001, "2 行の本文(30pt)+ 10pt + ボタン 22pt: \(plain.frame.height)")
        let buttons = plain.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.map(\.frame.minX) == [118, 212, 306], "Finder のボタンの枠は 117・211・305 から 88pt、地は 1pt 内側")
        #expect(buttons.allSatisfy { $0.frame.width == 86 && $0.keyEquivalent.isEmpty }, "既定のボタンも Esc も無い")
        #expect(abs(row("すべてに適用").frame.height - plain.frame.height - 1) < 0.001)
    }

    @Test("持ち主のウインドウが閉じたら、閉じたときの答えで片付く(OK だけの報告は残る)")
    func rowsAnswerWhenTheirOwnerCloses() async {
        let center = FileOperationPromptCenter(showsWindow: false)
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
        owner.isReleasedWhenClosed = false
        let prompt = FileOperationPrompt(
            icon: NSImage(), message: "m", buttons: ["中止", "置き換える"], checkboxTitle: nil, answerWhenOwnerCloses: 0, windowTitle: "t"
        )
        let asked = Task { await center.ask(prompt, owner: owner) }
        center.report(FileOperationPrompt(icon: NSImage(), message: "r", buttons: ["OK"], checkboxTitle: nil, answerWhenOwnerCloses: nil, windowTitle: "t"), owner: owner)
        // 待ち: 周回(メインの順番で決まる。時間では決まらない)
        await Task.yield()
        #expect(center.pendingCount == 2)
        owner.close()
        let answer = await asked.value
        #expect(answer == FileOperationPromptAnswer(button: 0, checkboxIsOn: false))
        #expect(center.pendingCount == 1)
    }

    @Test("走らせた操作の失敗は行で、理由の文だけ。空き不足は Finder の文、それ自身へのペーストはアラート")
    func failurePresentation() {
        let item = URL(filePath: "/tmp/qoo-prompt-test/big.bin")
        let folder = URL(filePath: "/tmp/qoo-prompt-test/F", directoryHint: .isDirectory)
        let space = FileBrowserProblem.failure(
            FileOperationError.insufficientFreeSpace(required: 2, available: 1, destination: folder), operationName: "op", items: [item]
        )
        #expect(space.presentation == .row(item: item))
        #expect(space.title.contains("big.bin") && space.message.isEmpty)
        let inside = FileBrowserProblem.failure(
            FileOperationError.destinationInsideSource(source: folder, destination: folder.appendingPathComponent("x")), operationName: "op", items: [folder]
        )
        #expect(inside.presentation == .finderDialog, "Finder と同じ独立したダイアログ")
        let path = FileBrowserProblem.failure(
            FileOperationError.pathTooLong(item: item, resultingBytes: 1100, limitBytes: 1023), operationName: "op", items: [item, folder]
        )
        #expect(path.presentation == .row(item: item))
        #expect(path.message.isEmpty)
    }
}

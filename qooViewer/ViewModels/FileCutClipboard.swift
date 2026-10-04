import AppKit
import Combine

/// ⌘X で覚えた項目(カットの記憶)。**アプリで 1 つ**(`shared`。2026-09-19 の監査の M2・L2。docs/plans/fs-ui-consistency-audit.md)。
///
/// 以前は `FileBrowserState`(ウインドウごと)が持っていたので、ウインドウ A でカットして B でペーストすると、B の記憶は空で
/// **移動のつもりがコピーになり**、A の一覧はカットの淡色のまま残った。ペーストボードはアプリで 1 つなので、記憶も 1 つにする。
/// 各ウインドウの状態はここを写して淡く描く(`FileBrowserState.cutPaths`)。
///
/// 記憶は、**カットしたときのペーストボードの中身がそのまま残っている間だけ**有効(`changeCount`)。ほかのアプリやこのアプリの
/// ⌘C でペーストボードが替わったら、`validate` で記憶ごと下ろす(以前は淡色だけが残った)。移動かコピーかの判定そのものは、
/// 今までどおりペーストの時点の中身との一致で決める(`FileBrowserOperations.paste`)。
@MainActor
final class FileCutClipboard: ObservableObject {
    static let shared = FileCutClipboard()

    /// カットした項目のパス(`FileBrowserOperations.paths(of:)` の規則)。
    @Published private(set) var paths: Set<String> = []
    /// カットを書いた直後のペーストボードの `changeCount`。
    private var changeCount: Int?

    init() {}

    /// 状態ごとの既定。テストの中で走るアプリでは、状態ごとに別のもの(`FileSystemChangeCenter.defaultForState` と同じ理由)。
    static func defaultForState() -> FileCutClipboard {
        RuntimeEnvironment.isRunningTests ? FileCutClipboard() : shared
    }

    /// ⌘X(`paths` が空なら ⌘C: 記憶を下ろす)。ペーストボードへ書いた**後で**呼ぶ。
    func set(_ paths: Set<String>, on pasteboard: NSPasteboard) {
        changeCount = paths.isEmpty ? nil : pasteboard.changeCount
        if self.paths != paths { self.paths = paths }
    }

    func clear() {
        changeCount = nil
        if !paths.isEmpty { paths = [] }
    }

    /// 記憶がまだ `expected` のままなら下ろす(ペーストの移動を実際に始める時点。`FileBrowserOperations.paste` のコメント)。
    /// 確認を待っている間に別の項目をカットし直していたら、その新しい記憶は残す。
    func clear(ifHolding expected: Set<String>) {
        guard !expected.isEmpty, paths == expected else { return }
        clear()
    }

    /// ペーストボードがカットの後で書き換えられていたら、記憶を下ろす(アクティブ化・ペーストの前に呼ぶ)。
    func validate(against pasteboard: NSPasteboard) {
        guard let changeCount, pasteboard.changeCount != changeCount else { return }
        clear()
    }

    /// アプリ自身が動かした・消した項目があれば、記憶ごと下ろす(`FileSystemChange`)。
    ///
    /// **一部だけでも外れたら全体を下ろす**(2026-10-04 の監査 FBA-4)。以前は外れた項目だけを記憶から除き、残りを淡色(カット済み)の
    /// ままにしていた。ところがペーストボードには外れた項目の古いパスも残っているので、⌘V の「移動か」の判定(ペーストボードの中身と
    /// 記憶の一致。`FileBrowserOperations.paste`)は外れてコピーになり、そのうえ古いパスが無いことで事前の検査が全体を断った ――
    /// 淡色は「移動する」と言うのに、残りも運ばれず「見つかりません」になった。下ろせば淡色も消え、⌘V は「ペーストボードの中身の
    /// コピー」として古いパスで断る(Finder と同じ)。ペーストボードを書き直す案は、アプリが勝手に利用者のペーストボードを変えるので採らない。
    ///
    /// 記憶のパスは `standardizedFileURL` の書き方(カットした時点で実在するので、頭の `/private` が外れて `/var/…`)、知らせのパスは
    /// 一覧が返す実体の書き方(`/private/var/…`)なので、`/private` の付いた形でも比べる(サンドボックス無しの CI で、一時フォルダの
    /// 中のリネームが記憶を下ろさなかった。2026-10-04)。
    func forget(displacedBy change: FileSystemChange) {
        guard !paths.isEmpty, paths.contains(where: { path in Self.spellings(of: path).contains { change.displaces($0) } }) else { return }
        clear()
    }

    /// `path` と、それが `/private` へのリンクの下(`/var`・`/tmp`・`/etc`)なら `/private` を付けた形。
    private static func spellings(of path: String) -> [String] {
        let isUnderPrivateLink = ["/var", "/tmp", "/etc"].contains { MountTable.path(path, isAtOrUnder: $0) }
        return isUnderPrivateLink ? [path, "/private" + path] : [path]
    }
}

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

    /// ペーストボードがカットの後で書き換えられていたら、記憶を下ろす(アクティブ化・ペーストの前に呼ぶ)。
    func validate(against pasteboard: NSPasteboard) {
        guard let changeCount, pasteboard.changeCount != changeCount else { return }
        clear()
    }

    /// アプリ自身が動かした・消した項目を記憶から外す(`FileSystemChange`)。
    func forget(displacedBy change: FileSystemChange) {
        guard !paths.isEmpty else { return }
        let kept = paths.filter { !change.displaces($0) }
        if kept.count != paths.count { paths = kept }
        if kept.isEmpty { changeCount = nil }
    }
}

import Foundation

/// 本を表示するウインドウ("book"/"private"/"normal"の`WindowGroup`)へ、開いた瞬間に何を
/// 見せるかを渡す値(改善要望7 段階3、2026-09-13)。
///
/// 以前はこの提示値が`BookOpenRequest`(本)だけで、**フォルダを新しいタブ/ウインドウの
/// ファイルブラウザで開く**ことが原理的にできなかった(`WindowGroup(for:)`は1つの型しか取れない)。
///
/// ■ `browse`だけが毎回変わる値を持つ
/// `openWindow(id:value:)`は「同じ id + 等値の value のウインドウが既にあれば、それを前面に出す」。
/// 本ではそれが二重に開かない最後の砦になっている(BookOpenRequestの型コメント)。一方、
/// **同じフォルダを2枚のウインドウで見るのは普通のこと**なので、`browse`には開くたびに作る`nonce`を
/// 入れて等値にならないようにしてある。状態復元は4つの WindowGroup とも無効なので、値が
/// 積み上がって残ることは無い。
///
/// nonisolated: `WindowGroup(for:)`の要求(Sendableな値型)を満たすため
/// (BookOpenRequestと同じ事情)。
nonisolated enum WindowContentRequest: Codable, Hashable, Sendable {
    /// この本を開く。
    case book(BookOpenRequest)
    /// ウェルカム画面をファイルブラウザにして、このフォルダを表示する。
    case browse(folder: URL, nonce: UUID)

    /// フォルダを表示する要求を作る(`nonce`を毎回新しくする)。
    static func browse(_ folder: URL) -> WindowContentRequest {
        .browse(folder: folder, nonce: UUID())
    }

    /// 本の要求なら、その中身。
    var bookRequest: BookOpenRequest? {
        guard case .book(let request) = self else { return nil }
        return request
    }

    /// フォルダを表示する要求なら、そのフォルダ。
    var browsedFolder: URL? {
        guard case .browse(let folder, _) = self else { return nil }
        return folder
    }
}

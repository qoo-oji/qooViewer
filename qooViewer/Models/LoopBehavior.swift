import SwiftUI

/// 最初/最後のページを超えてページ送りしようとしたときの挙動
/// rawValueはケース名(永続化用の安定した識別子)、titleKeyが画面表示用のローカライズされた名前。
enum LoopBehavior: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 同じ本の最初/最後のページへループする
    case loop
    /// 次(前)の本を開き、最初のページから読む
    case nextBookFirstPage
    /// 次(前)の本を開く(その本の続きから、記憶がなければ最初のページから)
    case nextBook
    /// 何もしない(最初/最後のページで止まる)
    case none

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .loop: return "Loop"
        case .nextBookFirstPage: return "Go to Next Book's First Page"
        case .nextBook: return "Next Book"
        case .none: return "Do Nothing"
        }
    }
}

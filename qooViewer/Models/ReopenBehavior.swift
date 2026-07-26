import SwiftUI

/// 以前開いたことのある本を再度開いたときの挙動。
/// rawValueはケース名(永続化用の安定した識別子)、titleKeyが画面表示用のローカライズされた名前。
enum ReopenBehavior: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 前回表示していたページからそのまま再開する(これまでの既定の挙動)
    case resume
    /// 前回どこまで読んでいたかに関わらず、常に最初のページから表示する
    case alwaysFromStart
    /// 前回、本の最後のページを表示していた場合だけ、最初のページから表示する
    /// (最後まで読み終えた本を開き直すと、また最初から読める)
    case fromStartIfFinishedLastTime
    /// そのつど「前回表示したページから再開しますか?」と尋ねる
    case ask

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .resume: return "Resume from Last Page"
        case .alwaysFromStart: return "Always Start from the Beginning"
        case .fromStartIfFinishedLastTime: return "Start from the Beginning if Last Page Was Reached"
        case .ask: return "Ask Each Time"
        }
    }
}

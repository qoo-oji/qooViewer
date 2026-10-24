import Foundation
import StackNestViewerKit

/// StackNestViewerKit の既定の文言(英日)を、qooViewer の表示言語とアプリの名前で出す。
///
/// 部品の `message()` の既定は `Bundle.main` の言語と表示名で、qooViewer のアプリの中の言語設定(AppLanguage)とは食い違い
/// うる(「システムに従う」以外を選んだ直後など)。表示名も Debug ビルドでは「qooViewer Debug」になる。文言を出す所は
/// すべてここを通す。
nonisolated enum StackNestText {
    /// 文言に入れるアプリの名前。
    static let appName = "qooViewer"

    /// `locale` の言語(日本語なら日本語、ほかは英語)で、部品の既定の文言を返す。
    static func message(for error: StackNestViewerError, locale: Locale) -> String {
        error.message(language: StackNestLanguage(locale: locale), appName: appName)
    }
}

/// 参照ファイルの本を開けなかった理由。AppState.open はエラーの `errorDescription` をアラートに出すので、部品のエラーを
/// そのまま投げると qooViewer の表示言語ではない文言になりうる。BookLoader は部品のエラーをこの形にして投げる。
nonisolated struct StackNestOpenError: LocalizedError, Equatable, Sendable {
    let error: StackNestViewerError
    /// 待ち切れずに失敗した(`.cannotConnect` が待ちの上限まで待ってから返った)。部品は「つながらない」と「応答しない」を同じ
    /// `.cannotConnect` で返し、文言は「StackNest が起動していないか、読書位置の同期の設定がオフです」になる。StackNest が動いていて
    /// 答えないだけのときにそれを出すと理由が違う(2026-10-24 の実機確認: 応答しない作り物で約 22 秒後にこの文が出た)ので、
    /// 待った時間で見分けて qooViewer の文言にする(`BookLoader.stackNestReferenceBook`)。
    var notResponding = false

    var errorDescription: String? {
        if notResponding {
            return String(localized: "StackNest isn’t responding. Open the book from StackNest again.", language: AppLanguage.currentLocale)
        }
        return StackNestText.message(for: error, locale: AppLanguage.currentLocale)
    }
}

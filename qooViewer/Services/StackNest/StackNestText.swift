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

    var errorDescription: String? { StackNestText.message(for: error, locale: AppLanguage.currentLocale) }
}

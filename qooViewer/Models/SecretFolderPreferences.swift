import SwiftUI

/// 環境設定「シークレットフォルダ」の「シークレットウインドウで開くとき」(2026-10-03、利用者の要望)。シークレットフォルダの本を
/// ノーマルの窓から開いたとき、シークレットウインドウのどこで開くか(`AppPreferences.secretFolderBooksOpenPrivately` が ON のとき)。
enum SecretFolderPrivatePlacement: String, CaseIterable, Identifiable, Hashable, SettingsOption {
    /// いちばん手前のシークレットウインドウのタブとして開く。シークレットウインドウが無ければ新しいシークレットウインドウ(既定。
    /// シークレットフォルダの本を続けて開いても窓が増えていかない)。
    case tabInPrivateWindow
    /// いちばん手前のシークレットウインドウで、表示中の本(またはホーム)と入れ替えて開く。シークレットウインドウが無ければ新しい
    /// シークレットウインドウ(2026-10-03、利用者の要望)。
    case replaceInPrivateWindow
    /// 毎回、新しいシークレットウインドウで開く。
    case newPrivateWindow

    var id: String { rawValue }

    var shortTitleKey: LocalizedStringKey {
        switch self {
        case .tabInPrivateWindow: "As a Tab in a Private Window"
        case .replaceInPrivateWindow: "In Place of the Book in a Private Window"
        case .newPrivateWindow: "In a New Private Window"
        }
    }
}

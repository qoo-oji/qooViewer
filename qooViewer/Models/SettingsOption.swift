import SwiftUI

/// 環境設定ウインドウのポップアップ(Picker)で選ばせる列挙型の共通インターフェース。
///
/// これまで各enumは `titleKey` 1本だけを持っていたが、それがそのまま
/// 「ポップアップを閉じた状態に出る文字列」でもあったため、意味を正確に伝えようとするほど
/// 文字列が長くなり、閉じた状態では省略され(「前回表示したページから…」)、
/// 逆に何が選ばれているのか分からなくなる、という板挟みになっていた。
///
/// そこで表示用の文字列を2つに分ける:
/// - `shortTitleKey`: ポップアップの各行と閉じた状態に出る**短い名前**(名詞句。省略されない長さ)
/// - `detailKey`:     いま選ばれている項目の**補足説明**(コントロールの下に小さく1行で出す)
///
/// これにより「一覧としての見やすさ」と「意味の正確さ」を両立させる。
/// 補足が不要なほど自明な選択肢(色名・言語名など)は `detailKey` を実装しなくてよい。
protocol SettingsOption: CaseIterable, Identifiable, Hashable {
    /// ポップアップの行および閉じた状態に表示する短い名前。
    var shortTitleKey: LocalizedStringKey { get }
    /// 選択中にコントロールの下へ表示する補足説明。不要な場合は nil。
    var detailKey: LocalizedStringKey? { get }
}

extension SettingsOption {
    var detailKey: LocalizedStringKey? { nil }
}

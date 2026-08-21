import SwiftUI

/// 環境設定ウインドウのサイドバーに並ぶ1項目(=右側に表示される1画面)。
///
/// ■ この型が単一の情報源であること
/// 環境設定は当初 `TabView` の1タブ = 1画面で、タブの並び・ラベル・アイコン・中身が
/// すべて `SettingsView` の `body` に直書きされていた。項目が8つまで増えた時点で
/// macOSの横一列のタブバーが限界を迎え、システム設定と同じ2ペイン構成へ移した
/// (経緯は `SettingsView` のコメント参照)。
///
/// その移行にあたり、画面の一覧を **この列挙型1つに集約** してある。
/// サイドバーの行も、右ペインの中身も、ウインドウのタイトルも、すべてここから導出されるため、
/// 画面を1つ増やすときに触るのは「このファイルにcaseを1つ足す」だけでよい。
/// `titleKey` / `systemImage` / `tint` / `group` / `destination` はいずれも
/// `switch self` の網羅性チェックを受けるので、**足し忘れはコンパイルエラーになる**
/// (`default:` を書かないのはそのため。安易に `default:` を足さないこと)。
///
/// ■ rawValue は永続化に使っている
/// 前回開いていた画面を次回も開くため、`SettingsView` が `@AppStorage` で
/// `rawValue` を保存している。既存のcaseの綴りを変えると保存済みの選択が読めなくなり、
/// 「一般」に戻るだけ(実害はない)。ただし意味なく変えないこと。
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    /// アプリ全体に関わる基本設定(表示言語・起動時の挙動・ウインドウ/タブ・履歴・サイドパネル)。
    case general
    /// 本を開くときの挙動(再開時の開始ページ・Finder/お気に入りからの開き先)。
    case opening
    /// 画像そのものの見え方(拡大率・補間品質・背景色・ルーペ・見開き判定・先読み)。
    case rendering
    /// 閲覧中の動作(ページ送り・スクロール・スライドショー・ポインタの自動非表示)。
    case reading
    /// 表示モードに依存しない、基本のキー割り当て。
    case keyboard
    /// 表示モードに依存しない、基本のマウス割り当て。
    case mouse
    /// 表示モードごとに上書きするキー/マウス割り当て。
    case modeInput
    /// サンドボックス下でのフォルダアクセス許可の管理。
    case access
    /// お気に入り・ブックマーク・読書履歴の全削除(取り消し不可)。
    case reset

    var id: Self { self }

    // MARK: - 表示

    /// サイドバーの行とウインドウタイトルに出す名前。
    ///
    /// `TabView` だった頃は「入力」「入力2」「アクセス権」のように **1語** に切り詰めてあった。
    /// これはmacOSのタブが内容幅で並ぶため、1つだけ長いラベルがあるとタブバーが不格好に
    /// なるという、レイアウト上の制約への対処だった(ユーザーからの指摘)。
    /// サイドバーは全行が同じ幅の縦並びなので、その制約はもう無い。
    /// 「入力2」のような、開いてみるまで中身が分からない番号付きの名前をやめ、
    /// **その画面に何があるかが名前だけで分かる長さ** に戻してある。
    var titleKey: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .opening: "Opening Books"
        case .rendering: "Image Display"
        case .reading: "While Reading"
        case .keyboard: "Keyboard"
        case .mouse: "Mouse"
        case .modeInput: "Per Display Mode"
        case .access: "Folder Access"
        case .reset: "Reset"
        }
    }

    /// アイコンタイルに描くSF Symbol。
    ///
    /// 塗りつぶし版(`.fill`)を選んでいるのは、色付きタイルの上に白抜きで載せるため
    /// (`SettingsPaneIcon` 参照)。線画のシンボルは11ptまで縮めると線が飛ぶ。
    /// `keyboard` だけは塗りつぶし版がキーの区切りまで潰れて読めなくなるので線画のまま。
    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        // 「閉じた本を開く」=これから開く本の設定。ページ(=閲覧中)の `reading` と対にしてある。
        case .opening: "book.closed.fill"
        case .rendering: "photo.fill"
        case .reading: "book.pages.fill"
        case .keyboard: "keyboard"
        case .mouse: "computermouse.fill"
        case .modeInput: "rectangle.split.2x1.fill"
        case .access: "lock.shield.fill"
        case .reset: "exclamationmark.triangle.fill"
        }
    }

    /// アイコンタイルの地の色。
    ///
    /// ■ 色はグループごとの系統で揃える
    /// 目的は装飾ではなく **走査の速さ**。ユーザーは名前を読む前に色で行を見分ける。
    /// 最初は8項目すべてに無関係な色を割り当てていたが、それだと色から分かるのは
    /// 「どの行か」だけで、**「どのグループの行か」が読み取れない**(ユーザーからの指摘)。
    /// グループごとに1系統を割り当て、系統内では明度・色相をずらして区別する形にした。
    /// これなら色を見た瞬間に、まずグループへ、次に項目へと絞り込める。
    ///
    ///   本   … ブルー系  (青 → シアン → インディゴ)
    ///   操作 … イエロー系(オレンジ → イエロー → ブラウン)
    ///   詳細 … レッド系  (ピンク寄りの赤 → 赤)
    ///
    /// 「操作」が3項目になった(「キーとマウス」を「キーボード」と「マウス」に分けた)ため、
    /// 同系統の3段目としてブラウンを足してある。オレンジ・イエローと地続きの暖色で、
    /// レッド系(詳細)ともブルー系(本)とも取り違えにくい。
    ///
    /// 「一般」はどのグループにも属さない単独の項目なので、どの系統とも重ならない無彩色にする。
    ///
    /// ■ 「リセット」の赤について
    /// 以前は赤を「リセット」専用の警告色として使い、他のどの項目とも共有していなかった。
    /// 「詳細」グループをレッド系にしたことでその独占は崩れるが、
    /// **系統内でいちばん彩度の高い純粋な赤を「リセット」に残し**、「フォルダのアクセス権」は
    /// 一段落ち着いたピンク寄りの赤にしてある。同じ系統の中に置いても、
    /// 「リセットだけ明らかに強い」という関係は保たれる(ユーザーとの相談のうえで決定)。
    /// 警告としてはこれに加えて、赤の警告三角のシンボルが担う。
    var tint: Color {
        switch self {
        case .general: .gray
        case .opening: .blue
        case .rendering: .cyan
        case .reading: .indigo
        case .keyboard: .orange
        case .mouse: .yellow
        case .modeInput: .brown
        case .access: .pink
        case .reset: .red
        }
    }

    /// この項目が属するサイドバーのグループ。
    var group: SettingsPaneGroup {
        switch self {
        case .general: .top
        case .opening, .rendering, .reading: .books
        case .keyboard, .mouse, .modeInput: .controls
        case .access, .reset: .advanced
        }
    }

    // MARK: - 中身

    /// 右ペインに表示する画面。
    ///
    /// 各画面は `SettingsPaneContainer`(= `Form` + `.formStyle(.grouped)`)で包まれた
    /// 自己完結なViewなので、ここでは余白もスクロールも指定しない。
    /// 2ペイン化にあたって8画面のどれも中身を書き換えずに済んだのは、この分離のおかげ。
    @ViewBuilder
    var destination: some View {
        switch self {
        case .general: GeneralSettingsView()
        case .opening: OpeningSettingsView()
        case .rendering: RenderingSettingsView()
        case .reading: ReadingSettingsView()
        case .keyboard: KeyBindingSettingsView()
        case .mouse: MouseBindingSettingsView()
        case .modeInput: ModeInputSettingsView()
        case .access: AccessPermissionsSettingsView()
        case .reset: ResetDataSettingsView()
        }
    }
}

// MARK: - グループ

/// サイドバーの区切り。macOSのシステム設定と同じく、性質の違う項目のあいだに
/// 見出し付きの区切りを入れて、8項目を一息に読ませないようにする。
///
/// 先頭の `.top` だけは見出しを持たない。「一般」1項目のためだけに見出しを立てると、
/// 見出しと項目が同じことを二度言うことになるため(ここは他の設定画面のSectionヘッダと
/// 同じ方針。`SettingsControls.swift` 参照)。
enum SettingsPaneGroup: Int, CaseIterable, Identifiable, Hashable {
    /// 見出しのない先頭のグループ。
    case top
    /// 本の見え方・開き方。
    case books
    /// キーとマウスの割り当て。
    case controls
    /// 普段は触らない、影響範囲の大きい設定。
    case advanced

    var id: Self { self }

    var titleKey: LocalizedStringKey? {
        switch self {
        case .top: nil
        case .books: "Books"
        case .controls: "Controls"
        case .advanced: "Advanced"
        }
    }

    /// このグループに属する項目を、`SettingsPane.allCases` の宣言順のまま返す。
    ///
    /// 並び順を別の配列で二重に持たないための実装。`SettingsPane` にcaseを足せば、
    /// その宣言位置がそのままサイドバーでの位置になる。
    var panes: [SettingsPane] {
        SettingsPane.allCases.filter { $0.group == self }
    }

    /// 実際に項目を持つグループだけを、宣言順に返す(サイドバーが空のSectionを描かないように)。
    static var populated: [SettingsPaneGroup] {
        allCases.filter { !$0.panes.isEmpty }
    }
}

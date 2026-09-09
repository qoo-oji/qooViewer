import SwiftUI

/// ページ一覧(サムネイルグリッド)で、サムネイルの下に何を書くか(ユーザー要望)。
///
/// 従来はページ番号を出す一択だった。ファイル名で管理している本では番号より
/// ファイル名のほうが手掛かりになる一方、サムネイルを小さくして一覧性を上げたい場合は
/// 文字そのものが邪魔になるため、3択にしてある。
///
/// rawValueはケース名(永続化用の安定した識別子)。
enum ThumbnailCaptionStyle: String, CaseIterable, Identifiable, Codable, Hashable {
    /// ページ番号(1始まり)。従来の唯一の表示で、既定値でもある。
    case pageNumber
    /// そのページの元のファイル名(PageRef.displayName)。
    case fileName
    /// 何も書かない。サムネイルだけが縦横に詰まって並ぶ。
    case none

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .pageNumber: return "Page Number"
        case .fileName: return "File Name"
        case .none: return "Nothing"
        }
    }
}

/// プログレスバーのフィルムストリップで、サムネイルに添える文字として何を出すか(ユーザー要望)。
///
/// 上の`ThumbnailCaptionStyle`(ページ一覧)と考え方は同じだが、**選択肢が1つ多い** ――
/// フィルムストリップは従来からファイル名とページ番号の2行を出しており、その「両方」を
/// 既定として残す必要があるため。あちらの列挙に`.both`を足して共用する案は採らなかった:
/// ページ一覧は1行しか出さない作りなので、選んでも何も起きない選択肢が画面に並ぶことになる。
///
/// **カーソル位置のページ番号(「5 / 120」)だけは、この設定に関わらず常に表示する。**
/// プログレスバーにカーソルを合わせる目的そのものが「いまどのページを指しているか」の確認で、
/// そこを消すとフィルムストリップを出す意味が無くなるため(プレビューをOFFにしたときに
/// 残るのがまさにこの表示であることからも、これが最後まで残すべき情報だと分かる)。
///
/// rawValueはケース名(永続化用の安定した識別子)。
enum FilmstripCaptionStyle: String, CaseIterable, Identifiable, Codable, Hashable {
    /// ファイル名とページ番号の2行。従来の唯一の表示で、既定値でもある。
    case fileNameAndPageNumber
    /// ページ番号(1始まり)だけ。
    case pageNumber
    /// そのページの元のファイル名だけ。
    case fileName
    /// 何も書かない(カーソル位置のページ番号を除く。上のコメント参照)。
    case none

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .fileNameAndPageNumber: return "File Name and Page Number"
        case .pageNumber: return "Page Number"
        case .fileName: return "File Name"
        case .none: return "Nothing"
        }
    }

    /// ファイル名の行を出すか。
    ///
    /// 書庫の中のフォルダ・入れ子の書庫にある画像でサムネイルの**上**に出る「本の中での場所」の
    /// 行も、これに従う ―― ファイル名を出さないのに場所だけ出しても、どのページかを
    /// 突き止める手掛かりにはならないため(あの行はファイル名を補うためのもの。
    /// ProgressBarView.filmstripCellのコメント参照)。
    var showsFileName: Bool {
        self == .fileNameAndPageNumber || self == .fileName
    }

    /// カーソル位置**以外**のセルにページ番号を出すか(カーソル位置のセルは常に出す)。
    var showsPageNumber: Bool {
        self == .fileNameAndPageNumber || self == .pageNumber
    }
}

/// コレクションの中(ウェルカム画面)で、本のカバーの下に何を書くか(ユーザー要望 2026-09-09)。
///
/// 上の2つ(ページ一覧・フィルムストリップ)と考え方は同じで、**選択肢だけが違う** ――
/// ページではなく本を並べる場所なので「ページ番号」に意味が無く、代わりに「タイトル」が要る。
/// 既存の`ThumbnailCaptionStyle`を使い回す案は採らなかった:選んでも何も起きない選択肢が
/// 画面に並ぶことになる(FilmstripCaptionStyleを別に立てたときと同じ判断)。
///
/// **既定は`.none`(表示しない)。** コレクションはカバーそのものが見出しで、名前を添えると
/// 1冊あたりの高さが増えて一覧性が落ちる ―― 従来の見え方をそのまま既定に残す
/// (CollectionDetailViewの型コメント参照)。
///
/// これは**アプリ全体で1つの設定**(環境設定「外観」→「ウェルカム画面」)。コレクションごとの
/// 設定として持たせる案もあったが、棚ごとに下の文字が変わると一覧としての見え方が揃わないため、
/// アプリの外観の設定にした(ユーザーの判断 2026-09-09)。
///
/// rawValueはケース名(永続化用の安定した識別子)。
enum CollectionCoverCaptionStyle: String, CaseIterable, Identifiable, Codable, Hashable {
    /// 何も書かない。カバーだけが並ぶ従来どおりの見え方で、既定値。
    case none
    /// 登録した時点のファイル名/フォルダ名(CollectionItem.title)。
    case fileName
    /// 書誌メタデータのタイトル。登録済みならその値、未登録ならファイル名から推測した値
    /// (「メタデータの編集」が候補として出すものと同じ。CollectionDetailView.caption(for:)参照)。
    case title

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .none: return "Nothing"
        case .fileName: return "File Name"
        case .title: return "Title"
        }
    }
}

/// 「表示中のページを示す枠」の色(ユーザー要望: 自由に設定できるようにしてほしい)。
///
/// 背景色(`BackgroundColorOption`)とまったく同じ作りにしてある ―― よく使う色は
/// プリセットから選び、それ以外は`.custom`で指定し、実際のRGB値は
/// `AppPreferences.thumbnailGridCurrentPageBorderCustomColor`が別に持つ。
///
/// `.accent`だけは他と性質が違い、**固定の色を持たない**。macOSのシステム設定
/// 「強調表示の色」に追従する動的な色で、これが従来の(そして今も)既定値である。
enum PageBorderColorOption: String, CaseIterable, Identifiable, Codable, Hashable {
    /// システムのアクセントカラー(従来からの既定)。
    case accent
    case red
    case yellow
    case green
    case white
    case black
    case custom

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .accent: return "Accent Color"
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .white: return "White"
        case .black: return "Black"
        case .custom: return "Custom"
        }
    }

    /// プリセットが表す色。`.accent`(システム追従のため固定値を持たない)と
    /// `.custom`(実際のRGB値はAppPreferences側にある)だけはnilを返す。
    ///
    /// `BackgroundColorOption.presetColor`と同じく、呼び出し側がうっかり適当な色へ
    /// フォールバックしてしまわないようOptionalにしてある。実際に枠を描くときは、
    /// 3つとも解決済みの`AppPreferences.effectiveCurrentPageBorderColor`を使うこと。
    var presetColor: Color? {
        switch self {
        case .accent, .custom: return nil
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .white: return .white
        case .black: return .black
        }
    }
}

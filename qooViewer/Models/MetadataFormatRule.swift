import Foundation

/// 「メタデータの編集」ウインドウが、ファイル名から著者・タイトル・シリーズ・巻数を機械的に
/// 推測するために使う3種類のルール定義。いずれもアプリ全体で1組(本ごとではない)の設定で、
/// MetadataFormatStoreがUserDefaultsへ保存する。
///
/// 推測の流れ(BookMetadataDeriver参照):
///   1. 拡張子を除いたファイル名から、MetadataExclusionRule に一致する部分を削る(ノイズ除去)
///   2. 残った文字列を MetadataFilenameFormat と上から順に照合し、著者とタイトルを取り出す
///   3. タイトルの末尾を VolumeFormatRule と照合し、シリーズ名と巻数に分離する
///
/// nonisolated: BookMetadataDeriver(メインアクター外で大量の行を処理しうる)から参照するため、
/// Xcode 26既定のMainActor自動分離の対象外にしている(ArchiveReading.swift冒頭のコメント参照)。

// MARK: - ファイル名フォーマット

/// ファイル名から著者名とタイトルを取り出すためのフォーマット1件。
///
/// patternには`@author`(著者名)・`@title`(タイトル)・`@ignore`(任意の文字列。メタデータとして
/// 扱わない)という3つの予約語と、丸括弧・角括弧・空白などのリテラルを組み合わせて書く。
/// 例: `(@ignore) [@author] @title (@ignore)`
///
/// 照合は「ファイル名全体との完全一致」で行い、フォーマット中の空白は「0文字以上の空白」
/// として扱う(除外文字列を削った跡に余分な空白が残っても照合できるようにするため。
/// MetadataFormatCompiler参照)。複数のフォーマットに一致しうる場合は、このリストの
/// 上にあるものが優先される(ユーザーは編集ダイアログ上でドラッグして優先順位を変えられる)。
nonisolated struct MetadataFilenameFormat: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var pattern: String

    init(id: UUID = UUID(), pattern: String) {
        self.id = id
        self.pattern = pattern
    }

    /// ユーザー要望で指定された既定のフォーマット12種。丸括弧トークンの有無、著者名の後ろの
    /// 補足トークンの有無、末尾トークンの有無の組み合わせを、具体的なものから順に並べてある
    /// (上から順に照合し、最初に一致したものを採用するため、この並び順自体が意味を持つ)。
    static let defaults: [MetadataFilenameFormat] = [
        "(@ignore) [@author (@ignore)] @title (@ignore) [@ignore]",
        "(@ignore) [@author (@ignore)] @title (@ignore)",
        "(@ignore) [@author (@ignore)] @title",
        "(@ignore) [@author] @title (@ignore) [@ignore]",
        "(@ignore) [@author] @title (@ignore)",
        "(@ignore) [@author] @title",
        "[@author (@ignore)] @title (@ignore) [@ignore]",
        "[@author (@ignore)] @title (@ignore)",
        "[@author (@ignore)] @title",
        "[@author] @title (@ignore) [@ignore]",
        "[@author] @title (@ignore)",
        "[@author] @title"
    ].map { MetadataFilenameFormat(pattern: $0) }
}

// MARK: - 巻数フォーマット

/// 巻数フォーマット1件の役割。
nonisolated enum VolumeFormatRuleKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// 巻数の番号を取り出す(キャプチャグループの中身を巻数として使う)。
    case volumeNumber
    /// 巻数の番号は取り出さず、シリーズ名を分離するためだけに使う
    /// (「上巻」「総集編3」など、巻数欄に入れる番号としては扱わないもの。ユーザーの意向により、
    /// このルールにキャプチャグループが書かれていても巻数欄は空欄のままにする)。
    case seriesSeparatorOnly
}

/// タイトル文字列をシリーズ名と巻数に分離するためのルール1件。patternは正規表現で、
/// 「タイトルの末尾に一致するか」だけを見る(タイトルはシリーズ名の次に巻数が並ぶ、という
/// ユーザー要望の前提に従う)。末尾に一致するルールが1件も無ければ、シリーズ欄・巻数欄は
/// どちらも空欄になる。
///
/// 複数のルールが末尾に一致しうる場合は、このリストの上にあるものが優先される
/// (例: `第3巻`は`第([0-9０-９]+)巻`と`([0-9０-９]+)巻`の両方に一致しうるが、前者を先に
/// 置くことで「第」がシリーズ名に残らないようにしている)。
nonisolated struct VolumeFormatRule: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var pattern: String
    var kind: VolumeFormatRuleKind

    init(id: UUID = UUID(), pattern: String, kind: VolumeFormatRuleKind) {
        self.id = id
        self.pattern = pattern
        self.kind = kind
    }

    /// ユーザー要望で指定された既定のルール。いただいた案をそのまま使うと取りこぼしが出る
    /// 箇所だけ、意図を変えない範囲で補正してある(「必要に応じて修正すること」という指示に従う):
    ///
    /// - `(?:vol|v|VOL|V)([0-9]+)`は`Vol`(先頭のみ大文字)を拾えず、また下の
    ///   `(?:vol|VOL|volume|Volume)\.?\s*([0-9]+)`と守備範囲が重複していた。両者を
    ///   「vol/volume系」と「v単独」の2本に整理し、大文字・小文字の綴りを網羅した。
    /// - `v`単独のルールは`vol`系より後ろに置く(`Vol3`を`v`単独のルールが先に食わないようにする。
    ///   末尾一致という性質上この例では実害は出ないが、優先順位を明示しておく)。
    /// - 巻数の番号を取る側の`[0-9]+`は、日本語の巻数表記に合わせて全角数字も拾えるよう
    ///   `[0-9０-９]+`へ統一した(取り出した番号はDeriverが半角へ正規化する)。
    /// - ユーザー要望: 「フルカラー総集編」も「総集編」と同様に扱う。`総集編`のままだと、
    ///   末尾一致の起点が「総」になるためシリーズ名の側に「フルカラー」が残ってしまう。
    ///   `(?:フルカラー)?`を前置し、NSRegularExpressionが最も左の一致を採ること
    ///   (=「フ」から一致する)を利用して、接頭辞ごとシリーズ名から切り離す。
    static let defaults: [VolumeFormatRule] = [
        VolumeFormatRule(pattern: #"第([0-9０-９]+)巻"#, kind: .volumeNumber),
        VolumeFormatRule(pattern: #"([0-9０-９]+)巻"#, kind: .volumeNumber),
        VolumeFormatRule(pattern: #"[\s_-]+[vV]([0-9０-９]+)"#, kind: .volumeNumber),
        VolumeFormatRule(pattern: #"(?:vol|Vol|VOL|volume|Volume|VOLUME)\.?\s*([0-9０-９]+)"#, kind: .volumeNumber),
        VolumeFormatRule(pattern: #"[vV]\.?\s*([0-9０-９]+)"#, kind: .volumeNumber),
        VolumeFormatRule(pattern: #"(?:フルカラー)?総集編([0-9０-９]+)"#, kind: .seriesSeparatorOnly),
        VolumeFormatRule(pattern: #"(上巻|下巻|前編|中編|後編|完結編|(?:フルカラー)?総集編)"#, kind: .seriesSeparatorOnly)
    ]
}

// MARK: - 除外文字列

/// ファイル名からノイズとして削る文字列1件(正規表現)。ファイル名フォーマットとの照合より
/// 前に適用する。
nonisolated struct MetadataExclusionRule: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var pattern: String

    init(id: UUID = UUID(), pattern: String) {
        self.id = id
        self.pattern = pattern
    }

    /// ユーザー要望で指定された既定のルール。括弧の中の1900〜2099の4桁の数字は年号であり
    /// ノイズと見なす、という意図をそのまま2本の正規表現で表している
    /// (`(19xx)`と`(20xx)`。2100年以降は対象外)。
    ///
    /// 完結を示す括弧書きは、いただいた`(結|完結|完全版)`に、追加のご指示による`(完)`・`(終)`を
    /// 足して1本にまとめてある。正規表現の選択肢は左から順に試されるため、長い綴りを先に
    /// 置いて`完結`が`完`だけ食われないようにしている。
    static let defaults: [MetadataExclusionRule] = [
        #"\((19[0-9]{2})\)"#,
        #"\((20[0-9]{2})\)"#,
        #"\((完結|完全版|結|完|終)\)"#
    ].map { MetadataExclusionRule(pattern: $0) }
}

import SwiftUI
import AppKit

// MARK: - 共通部品

/// 同じ行に並べるボタンの幅を揃えるための、ラベル文字列からの幅の見積もり
/// (ユーザー要望: 「ボタンの幅は３つとも揃えること」「ボタン幅は初期化ボタンと揃えること」)。
///
/// 前者の「3つとも揃えること」はメタデータ編集ウインドウ上部に並べていた3つのボタンへの要望
/// だったが、そのボタン群はツールバーの1つのプルダウンへ畳んだため、今の利用箇所は
/// 下記のダイアログのフッター(初期化/閉じる)だけになっている。
///
/// `.frame(maxWidth: .infinity)`で揃える方法もあるが、それだと親の幅いっぱいまで
/// 引き伸ばされてしまい、ウインドウ幅によってボタンが不自然に間延びする。
/// ExportColumnWidthEstimatorと同じくNSStringの実測を使い、「一番長いラベルが
/// 収まる幅」を求めて全ボタンへ同じ値を指定する。
enum MetadataButtonWidthEstimator {
    /// ボタンのラベル以外に必要な左右の余白(macOSの標準ボタンのパディング相当)。
    static let chrome: CGFloat = 34
    /// `.controlSize(.small)`のボタン用の余白。標準サイズよりベゼルの左右が詰まる
    /// (実機のスクリーンショットを実測して合わせた値)。
    static let smallChrome: CGFloat = 16

    /// フォントと余白を差し替えられるようにしてあるのは、小さいサイズのボタン
    /// (メタデータ編集ウインドウの登録/削除ボタン)の列幅も同じ見積もりで求めるため。
    static func equalWidth(
        for labels: [String],
        minWidth: CGFloat = 120,
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        chrome: CGFloat = MetadataButtonWidthEstimator.chrome
    ) -> CGFloat {
        let widest = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return max(minWidth, (widest + chrome).rounded(.up))
    }
}

/// 3つの編集ダイアログに共通する下部のボタン列(左下「初期化」・右下「閉じる」、幅は揃える)。
private struct MetadataDialogFooter: View {
    let onReset: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    /// 初期化の確認。登録内容を既定値へ戻す操作は取り消せないため、一段挟む。
    @State private var isConfirmingReset = false

    var body: some View {
        let buttonWidth = MetadataButtonWidthEstimator.equalWidth(
            for: [
                String(localized: "Reset", locale: locale),
                String(localized: "Close", locale: locale)
            ],
            minWidth: 90
        )
        return HStack {
            Button("Reset") { isConfirmingReset = true }
                .frame(width: buttonWidth)
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .frame(width: buttonWidth)
        }
        .padding(12)
        .confirmationDialog(
            "Reset to the default entries?", isPresented: $isConfirmingReset, titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { onReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything you've added or edited here will be replaced with the defaults. This can't be undone.")
        }
    }
}

/// 3つの編集ダイアログに共通する「1行1パターンのリスト + 追加/削除 + 並べ替え」の中身。
///
/// 3種類のルールは型が違うだけで編集操作は同じのため、パターン文字列へのキーパスと
/// 新規要素の作り方、妥当性の判定だけを渡してもらう形で共通化している。
private struct MetadataRuleListEditor<Item: Identifiable & Hashable>: View {
    @Binding var items: [Item]
    /// 各要素のパターン文字列(編集対象)へのキーパス。
    let patternKeyPath: WritableKeyPath<Item, String>
    /// 「追加」ボタンで作る空の要素。
    let makeNewItem: () -> Item
    /// パターンが有効かどうか(無効なものには警告アイコンを出す)。
    let isValid: (String) -> Bool
    /// 入力欄が空のときに薄く表示する見本。
    let placeholder: String
    /// リストの上に出す短い見出し(このリストが何のためのものかを一目で分かる長さにする)。
    let title: LocalizedStringKey
    /// 見出しの右の情報アイコンにマウスを重ねたときだけ吹き出しで出す、詳しい説明。
    let explanation: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ユーザー要望: 説明文が常時2〜3行で表示されていると読みづらい。見出しは
            // 「何のためのリストか」だけを短く示し、細かい規則(キャプチャグループの扱い、
            // 照合の順序など)は情報アイコンの吹き出しへ送る。
            HStack(spacing: 4) {
                Text(title)
                    .fontWeight(.semibold)
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(explanation)
            }

            List {
                // Bindingの@dynamicMemberLookup(標準で用意されているキーパス版のsubscript)を
                // 使い、要素のパターン文字列を直接編集できるBindingを取り出す。
                ForEach($items) { $item in
                    HStack(spacing: 6) {
                        // 並べ替えのつまみ。上にあるものほど優先されることが見た目でも
                        // 分かるよう、行頭に置く。
                        Image(systemName: "line.3.horizontal")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        TextField(placeholder, text: $item[dynamicMember: patternKeyPath])
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))

                        if !isValid(item[keyPath: patternKeyPath]) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("This entry isn't valid, so it will be ignored.")
                        }

                        Button {
                            items.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
                .onMove { source, destination in
                    items.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            Button {
                items.append(makeNewItem())
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }
}

// MARK: - ファイル名フォーマットの編集

/// ユーザー要望: ファイル名からタイトルと著者名を抽出するためのファイル名フォーマットを
/// 追加・削除・編集できる専用ダイアログ。
struct FilenameFormatEditorSheet: View {
    @EnvironmentObject private var formatStore: MetadataFormatStore

    var body: some View {
        VStack(spacing: 0) {
            MetadataRuleListEditor(
                items: $formatStore.filenameFormats,
                patternKeyPath: \MetadataFilenameFormat.pattern,
                makeNewItem: { MetadataFilenameFormat(pattern: "[@author] @title") },
                isValid: MetadataFormatCompiler.isValidFilenameFormat,
                placeholder: "[@author] @title",
                title: "Formats for Extracting the Author and Title",
                explanation: """
                    Use @author for the author, @title for the title, and @ignore for text to skip. \
                    Formats are matched against the file name without its extension, from top to bottom, \
                    and the first one that matches wins — drag to reorder. \
                    Excluded text is removed before matching.
                    """
            )
            .padding(12)

            Divider()
            MetadataDialogFooter { formatStore.resetFilenameFormats() }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

// MARK: - 巻数フォーマットの編集

/// ユーザー要望: タイトル文字列をシリーズ名と巻数に分離し、巻数の番号を抽出するための
/// フォーマットを追加・削除・編集できる専用ダイアログ。巻数を取り出すものと、シリーズ名の
/// 分離だけを行うものの2種類を、別々のセクションとして扱う。
struct VolumeFormatEditorSheet: View {
    @EnvironmentObject private var formatStore: MetadataFormatStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                MetadataRuleListEditor(
                    items: binding(for: .volumeNumber),
                    patternKeyPath: \VolumeFormatRule.pattern,
                    makeNewItem: { VolumeFormatRule(pattern: "", kind: .volumeNumber) },
                    isValid: MetadataFormatCompiler.isValidRegularExpression,
                    placeholder: #"第([0-9０-９]+)巻"#,
                    title: "Regular Expressions for Volume Numbers",
                    explanation: """
                        Regular expressions that match the volume marker at the end of the title. \
                        The first capture group becomes the volume number (full-width digits are \
                        converted to half-width). The text before the match becomes the series name.
                        """
                )

                MetadataRuleListEditor(
                    items: binding(for: .seriesSeparatorOnly),
                    patternKeyPath: \VolumeFormatRule.pattern,
                    makeNewItem: { VolumeFormatRule(pattern: "", kind: .seriesSeparatorOnly) },
                    isValid: MetadataFormatCompiler.isValidRegularExpression,
                    placeholder: #"(上巻|下巻|前編|後編)"#,
                    title: "Regular Expressions for Series Names",
                    explanation: """
                        These only separate the series name — the volume field is left empty even if \
                        the expression contains a capture group. They are tried after the entries above.
                        """
                )
            }
            .padding(12)

            Divider()
            MetadataDialogFooter { formatStore.resetVolumeRules() }
        }
        .frame(minWidth: 560, minHeight: 560)
    }

    /// 1本の配列(formatStore.volumeRules)を、種類ごとの2つのリストとして見せるためのBinding。
    ///
    /// 配列は常に「巻数を取り出すもの → シリーズ名の分離だけのもの」という順に並べ直して
    /// 書き戻す。BookMetadataDeriverは配列の順にルールを試すため、この並びがそのまま
    /// 「巻数付きの表記を優先して照合する」という優先順位になる(既定値の並びと同じ)。
    private func binding(for kind: VolumeFormatRuleKind) -> Binding<[VolumeFormatRule]> {
        Binding(
            get: { formatStore.volumeRules.filter { $0.kind == kind } },
            set: { updated in
                let others = formatStore.volumeRules.filter { $0.kind != kind }
                formatStore.volumeRules = kind == .volumeNumber ? updated + others : others + updated
            }
        )
    }
}

// MARK: - 除外文字列の編集

/// ユーザー要望: ノイズを除外するための除外文字列を追加・削除・編集できる専用ダイアログ。
struct ExclusionRuleEditorSheet: View {
    @EnvironmentObject private var formatStore: MetadataFormatStore

    var body: some View {
        VStack(spacing: 0) {
            MetadataRuleListEditor(
                items: $formatStore.exclusionRules,
                patternKeyPath: \MetadataExclusionRule.pattern,
                makeNewItem: { MetadataExclusionRule(pattern: "") },
                isValid: MetadataFormatCompiler.isValidRegularExpression,
                placeholder: #"\((19[0-9]{2})\)"#,
                title: "Regular Expressions for Excluded Text",
                explanation: """
                    Regular expressions for text to remove from the file name before matching it \
                    against the file name formats — for example a year in parentheses, or a \
                    completion marker.
                    """
            )
            .padding(12)

            Divider()
            MetadataDialogFooter { formatStore.resetExclusionRules() }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

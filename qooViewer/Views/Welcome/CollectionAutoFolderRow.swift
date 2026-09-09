import AppKit
import SwiftUI

/// 自動登録フォルダを1つ選ぶための行(ユーザー要望 2026-09-09)。
///
/// コレクションを作るときの名前入力シート(CollectionNameSheet)と、コレクションの中の
/// 歯車(CollectionSettingsPopover)の両方が同じ部品を使う ―― 選び方・解除の仕方・
/// アクセス権の求め方が入り口によって違うと、同じ設定に見えなくなるため。
///
/// ■ パスは直接打てる(ユーザー要望 2026-09-09)
/// 最初はパネルとドロップでしか選べない読み取り専用の欄にしていた ―― 手で打ったパスには
/// アクセス権が伴わないので「打てば動くように見えて動かない」と考えたため。**これは撤回した。**
/// 権限が無い状態は元から起こりうる(落とされたファイルの親フォルダ)ので、そのための
/// 「アクセスを許可」は既にこの行にある。打った場合も同じ道を通るだけで、新しい行き止まりは
/// 生まれない。欄を空にすれば自動登録なしに戻るので、**「クリア」のボタンも要らなくなった**。
///
/// `~` は展開しない。サンドボックスの中では `~` がコンテナを指すので、展開すると打った人の
/// 意図と違う場所(`~/Library/Containers/…`)になる。絶対パスで打つか、パネル/ドロップで選ぶ。
///
/// ■ アクセス権
/// 選んだフォルダは必ずFolderAccessStoreへ足す。サンドボックスでフォルダを列挙する権限は
/// あそこが一手に持っており(FolderAccessStore.accessedURLsByPathのコメント参照)、
/// 走査する側もisPathCoveredにだけ訊く(CollectionAutoFolderScanner)。
///
/// **落とされたファイルの入っていたフォルダにも、打ったパスにも権限は付いてこない。**
/// その場合は「アクセスを許可」を出して、既存の導線
/// (AppState.ensureAccess(toFolder:message:)と同じ形のNSOpenPanel)で許可してもらう。
/// 許可されるまで自動登録は静かに何もしない。
///
/// シート/ポップオーバーの中身はmacOSが不透明に描くので、すりガラス面の輪郭は要らない
/// (CLAUDE.md)。
struct CollectionAutoFolderRow: View {
    @Binding var folder: URL?

    @EnvironmentObject private var folderAccess: FolderAccessStore
    @Environment(\.locale) private var locale
    @State private var isDropTargeted = false
    /// 欄に見えている文字列。**打っている途中の状態を持つのはこちら**で、`folder`へは
    /// 前後の空白を除いたものを書き戻す(空なら自動登録なし = nil)。
    @State private var pathText = ""

    /// この行が出す注意書き。上から順に見て、最初に当てはまったものだけを1行出す。
    private enum Advice {
        /// そこにフォルダが無い(打ち間違い、消された、別の端末のパス)。
        case notFound
        /// フォルダはあるが、列挙する権限が無い(落とされたファイルの親・打ったパス)。
        case needsAccess
    }

    private var advice: Advice? {
        guard let folder else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return .notFound }
        return folderAccess.isPathCovered(folder) ? nil : .needsAccess
    }

    /// 注意書きの文言。**`advice`がnilのときも出す**(見えないだけ。高さを予約するため)。
    private var adviceKey: LocalizedStringKey {
        advice == .notFound
            ? "That folder could not be found."
            : "qooViewer needs permission to read this folder."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                pathField
                Button("Choose…") { choose() }
                    .fixedSize()
            }

            // 注意書きは「何が起きていないか」を1行で。ここだけは文章を置く ―― 設定は
            // 入っているのに何も起きない状態を、画面から読めるようにするためで、飾りの説明
            // ではない。
            //
            // **高さは常に予約しておく**(名前欄の検証メッセージと同じ扱い)。パスを打っている
            // 最中は「見つかりません」が1文字ごとに出たり消えたりするので、そのたびに面の高さが
            // 跳ねると読めない。`reservesSpace`で2行ぶん取るのは、訳の長さや文字サイズで
            // 1行に収まるかどうかが変わるため ―― 収まる/収まらないでも跳ねさせない。
            HStack(spacing: 8) {
                Label(adviceKey, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                // 「アクセスを許可」は**フォルダが実在するときだけ**押せる。無い場所への
                // 許可を求めるパネルは開いても意味が無い。場所は空けたまま隠す(上と同じ理由)。
                Button("Grant Access") { if let folder { grantAccess(to: folder) } }
                    .font(.caption)
                    .fixedSize()
                    .disabled(advice != .needsAccess)
                    .opacity(advice == .needsAccess ? 1 : 0)
                Spacer(minLength: 0)
            }
            .opacity(advice == nil ? 0 : 1)
        }
        .onAppear { pathText = folder?.path ?? "" }
        // 外(パネル・ドロップ・別のウインドウ)から変わったときに欄を追従させる。
        //
        // **打っている最中の文字列を横から書き換えないこと。** 素朴に「`folder`のパスと欄の
        // 文字列が違えば揃える」と書くと、`URL(fileURLWithPath:)`が末尾の`/`を落とすせいで、
        // 「/Users/」まで打った瞬間に打った`/`が消える。欄の文字列を同じ経路に通した結果と
        // 比べれば、自分の入力が返ってきただけのときは何もしない。
        .onChange(of: folder?.path ?? "") { _, newValue in
            guard newValue != derivedPath(from: pathText) else { return }
            pathText = newValue
        }
        .onChange(of: pathText) { _, newValue in
            let derived = derivedPath(from: newValue)
            // 空にすれば自動登録なしへ戻る(「クリア」のボタンを置かない理由)。
            folder = derived.isEmpty ? nil : URL(fileURLWithPath: derived, isDirectory: true)
        }
        .fileURLDropTarget(isTargeted: $isDropTargeted) { urls in
            adoptDroppedFolder(urls)
        }
    }

    /// パスの欄。**直接打てる**(型コメント参照)。空にすれば自動登録なし。
    ///
    /// `.textFieldStyle(.plain)`にして地と枠を自前で描くのは、標準のベゼルがフォーカスリング用の
    /// 余白を内側に取るぶん見た目が痩せるため(BulkRenameBookmarksSheetの同種のコメント参照)。
    /// ここではドロップ中の枠を自分で太らせたい、という事情も重なる。
    private var pathField: some View {
        TextField(
            String(localized: "None (no auto-add)", language: locale), text: $pathText
        )
        .textFieldStyle(.plain)
        .lineLimit(1)
        .autocorrectionDisabled()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    lineWidth: isDropTargeted ? 2 : 1
                )
        )
        .help(folder?.path ?? "")
    }

    /// 欄の文字列を`folder`へ入れるときに通る正規化(前後の空白を落とし、URLを一度通す)。
    /// 書き戻しの判定を同じ経路で行うために切り出してある(上のonChangeのコメント参照)。
    private func derivedPath(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : URL(fileURLWithPath: trimmed, isDirectory: true).path
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Choose", language: locale)
        panel.message = String(
            localized: "Choose a folder. Books added to it are added to this collection automatically.",
            language: locale
        )
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        // パネルで選んだ時点で権限は付いているので、そのままFolderAccessStoreへ預ける
        // (自前でstartAccessing…しないこと。FolderAccessStore参照)。
        folderAccess.add(url: chosen)
        folder = chosen
    }

    /// 落とされたものからフォルダを1つだけ採る(ファイルは無視する ―― ここが受けるのは
    /// 「どのフォルダを見張るか」であって、本ではない)。
    private func adoptDroppedFolder(_ urls: [URL]) {
        var isDirectory: ObjCBool = false
        guard let dropped = urls.first(where: {
            FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }) else { return }
        folderAccess.add(url: dropped)
        folder = dropped
    }

    /// 権限の付いていないフォルダ(落とされたファイルの親など)への許可を求める。
    /// AppState.ensureAccess(toFolder:message:)と同じ形・同じ保存先。
    private func grantAccess(to folder: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Grant Access", language: locale)
        panel.message = String(
            localized: "Grant access to this folder so books added to it can be added to the collection automatically.",
            language: locale
        )
        guard panel.runModal() == .OK, let granted = panel.url else { return }
        folderAccess.add(url: granted)
    }
}

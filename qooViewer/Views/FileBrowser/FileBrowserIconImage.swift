import AppKit
import SwiftUI

/// アイコン表示のセルの絵(改善要望7 段階 7a、2026-09-14)。本・画像・画像フォルダは中の絵、アプリケーションはそのアプリの
/// アイコン、それ以外と絵ができるまでは種類のアイコン(FileBrowserIconProvider)。
///
/// ■ 見せ方
/// - 本・画像 → 枠(アイコンの大きさの正方形)に収めて置く。白いページがすりガラス面の明るい地に溶けないよう、薄い影を付ける
///   (絵なので輪郭は掛けない。CLAUDE.md の表)
/// - フォルダ → **フォルダのアイコンの上に絵を小さく重ねる**。絵だけにすると画像ファイルと見分けがつかない
///
/// ■ 読み直し
/// 大きさの段(FileBrowserThumbnailProvider.pixelTier)が上がったときと、項目の中身(更新日時・サイズ)・絵の出どころ
/// (`revision`)が変わったときに頼み直す。**持っている絵は新しい絵が届くまで手放さない**(大きさを変えるたびに種類の
/// アイコンへ戻って点滅しないように。CollectionCoverThumbnail と同じ)。小さくする方向では読み直さない。
/// 種類(`kind`)が変わったときも頼み直す ―― 環境設定「動画のサムネイルを生成」を OFF にすると動画の `kind` が nil になるが、
/// 鍵に種類を入れていなかった間は `.task` が走らず、持っている絵がそのまま残った(段階 7b の実機検証で発見、2026-09-14)。
struct FileBrowserIconImage: View {
    let entry: FileBrowserEntry
    /// 絵を作れる種類(nil なら種類のアイコンだけ)。
    let kind: BookThumbnailer.Kind?
    let iconSize: CGFloat
    let provider: FileBrowserThumbnailProvider
    let revision: UInt64
    /// 作った絵をディスクキャッシュへ書くか。シークレットウインドウでは false(FileBrowserThumbnailProvider の型コメント)。
    let savesToDisk: Bool
    /// 抱えた絵のバイト数を呼び出し側の帳簿(LazyCellImageBudget)へ伝える。
    let onImageRetained: (Int) -> Void

    @State private var image: CGImage?
    @State private var loadedTier: CGFloat = 0
    @State private var loadedContentKey = ""

    /// フォルダに重ねる絵の大きさ(アイコンに対する比)。
    private static let folderImageScale: CGFloat = 0.56

    var body: some View {
        ZStack {
            if let image, let kind, kind != .folder {
                thumbnail(image)
            } else {
                Image(nsImage: FileBrowserIconProvider.icon(for: entry))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                if let image, kind == .folder {
                    thumbnail(image)
                        .frame(width: iconSize * Self.folderImageScale, height: iconSize * Self.folderImageScale)
                        // フォルダのアイコンの胴(上の耳を除いた部分)の中ほどへ。
                        .offset(y: iconSize * 0.06)
                }
            }
        }
        .frame(width: iconSize, height: iconSize)
        .task(id: "\(contentKey)|\(tier)|\(kind.map { "\($0)" } ?? "none")") {
            await load()
        }
    }

    private func thumbnail(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            // アプリのアイコンは自前の形と影を持つので、ページ用の影を重ねない。
            .shadow(color: .black.opacity(kind == .application ? 0 : 0.3), radius: 1.5, y: 0.5)
    }

    /// 大きさ以外で絵が変わる要素。
    private var contentKey: String {
        let modified = entry.modificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(entry.id)|\(modified)|\(entry.fileSize ?? -1)|\(revision)"
    }

    private var tier: CGFloat {
        FileBrowserThumbnailProvider.pixelTier(
            forDisplaySize: kind == .folder ? iconSize * Self.folderImageScale : iconSize
        )
    }

    private func load() async {
        guard let kind else {
            if image != nil { image = nil }
            return
        }
        let tier = self.tier
        let key = contentKey
        if image != nil, loadedContentKey == key, tier <= loadedTier { return }
        let buffer = await provider.thumbnail(for: entry, kind: kind, pixelSize: tier, savesToDisk: savesToDisk)
        guard !Task.isCancelled else { return }
        guard let buffer, let made = buffer.makeImage() else {
            // 中身が変わって作れなくなった(画像を消した等)ときだけ種類のアイコンへ戻す。
            if loadedContentKey != key { image = nil }
            return
        }
        onImageRetained(buffer.byteCount)
        image = made
        loadedTier = tier
        loadedContentKey = key
    }
}

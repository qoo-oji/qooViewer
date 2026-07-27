import SwiftUI
import CoreGraphics

/// ページのサムネイル一覧画面(cooViewerの「一覧表示画面」に相当)。
/// クリックでそのページへジャンプする。
struct ThumbnailGridView: View {
    @ObservedObject var viewModel: ViewerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var reversed = false

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 10)]

    private var orderedIndices: [Int] {
        let indices = Array(0..<viewModel.pageCount)
        return reversed ? indices.reversed() : indices
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(orderedIndices, id: \.self) { index in
                        Button {
                            viewModel.jump(toPageIndex: index)
                            dismiss()
                        } label: {
                            ThumbnailCell(viewModel: viewModel, index: index, isCurrent: index == viewModel.currentIndex)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle(Text("Page List (Total ") + Text("\(viewModel.pageCount)") + Text(" pages)"))
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        reversed.toggle()
                    } label: {
                        Label("Reverse Order", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

/// グリッドの1セル。あえて `@ObservedObject` にせず素の参照として `viewModel` を持つ。
/// ページ一覧は数十〜数百セル並ぶことがあり、`@ObservedObject` で ViewerViewModel 全体を
/// 購読してしまうと、どこか1セルのサムネイル読み込みが完了するたびに
/// (@Publishedプロパティの更新経由で)画面内の全セルが再描画対象になってしまう。
/// ここでは各セルが自分専用の `@State` で結果を保持し、`.task(id:)` で1回だけ非同期取得することで、
/// 再描画がそのセル自身に閉じるようにしている。
private struct ThumbnailCell: View {
    let viewModel: ViewerViewModel
    let index: Int
    let isCurrent: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.15))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(2)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 120, height: 120)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            Text("\(index + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .task(id: index) {
            image = await viewModel.loadThumbnail(at: index)
        }
    }
}

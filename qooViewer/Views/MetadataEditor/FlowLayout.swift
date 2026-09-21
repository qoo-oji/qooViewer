import QooMetaKit
import SwiftUI

/// チップを折り返して並べる。
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(indices: Range<Int>, width: CGFloat, height: CGFloat)] {
        var rows: [(indices: Range<Int>, width: CGFloat, height: CGFloat)] = []
        var start = 0, x: CGFloat = 0, height: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if i > start, x + size.width > width {
                rows.append((start..<i, x - spacing, height))
                start = i; x = 0; height = 0
            }
            x += size.width + spacing
            height = max(height, size.height)
        }
        if start < subviews.count { rows.append((start..<subviews.count, x - spacing, height)) }
        return rows
    }
}


extension FormatWord {
    /// ファイル名の色分け(解析の設定の窓の読めぐあい)で、欄ごとに使う色。
    var color: Color {
        switch self {
        case .title: .blue
        case .author: .green
        case .genre: .orange
        case .event: .pink
        case .source: .purple
        case .info: .teal
        case .series, .volume: .indigo
        case .ignore: .gray
        }
    }
}

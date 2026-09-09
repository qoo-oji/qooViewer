import SwiftUI

/// 編集モード中に、コレクションのタイル・本のカバーの**左上**へ重ねる選択の印(改善要望5の追加)。
///
/// 編集モードでは、タイル/カバーをクリックすると「開く」ではなく「選ぶ/選び直す」になる。
/// その状態を示すのがこの印で、選んでいなければ空の丸、選んでいればアクセント地のチェックマーク
/// (写真.appの選択と同じ形)。
///
/// ■ 輪郭(すりガラス面の決まりごと)
/// **`.panelOutlinedContent()`は掛けない。** この印は冊数バッジと同じく**自前の不透明な地**
/// (暗い丸/アクセント色の丸)と白い縁を持っており、面を文字色で塗りつぶしても消えない。
/// 輪郭を足すとカバーの上で二重の縁になって、写真の見分けの邪魔になる。
///
/// 「アクセント色の状態が面の色に溶ける」件(panelOutlinedAccentが要る条件)にも当たらない ――
/// 選択中/非選択中の違いは**チェックマークの有無**でも伝わり、色だけに頼っていないため。
/// 一方、タイル/カバーの縁に出す選択の枠(呼び出し側)は色だけが頼りなので、そちらには
/// `.panelOutlinedAccent(in:)`を掛けてある。
struct SelectionCheckmarkBadge: View {
    let isSelected: Bool
    /// タイル/カバーの一辺の目安(スライダーの値)。印の大きさをこれに比例させ、小さいカバーで
    /// 印が絵を覆い尽くさないようにする(下限16pt・上限28ptで頭打ち)。
    let size: CGFloat

    /// 印の外側の余白。タイル/カバーの角丸から少し内へ入れる。
    static let inset: CGFloat = 6

    private var diameter: CGFloat {
        max(16, min(28, size * 0.16))
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.black.opacity(0.45))
            Circle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: diameter * 0.5, weight: .bold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: diameter, height: diameter)
        .padding(Self.inset)
        // 印そのものは当たり判定を持たない。クリックの受け口はタイル/カバー全体
        // (印だけを狙わせると、小さいカバーでは狙いにくい)。
        .allowsHitTesting(false)
    }
}

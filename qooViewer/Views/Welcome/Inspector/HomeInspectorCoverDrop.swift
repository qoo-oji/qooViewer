import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// インスペクタの表紙へ画像ファイルを落とす受け口(2026-09-30)。
///
/// ■ なぜ表紙そのものに `.onDrop` を付けないのか(実機で測った)
/// インスペクタの縦のスクロール(`ScrollView`)の**内側**に付けた `.onDrop` は、ウインドウ全体の受け口(本を開く。
/// ContentView.applyFileDropTarget)に負けて一度も呼ばれなかった ―― 表紙に落とした画像が本として開いた。表紙の修飾の並び
/// (`.popover`・`.id`・一番外側)、`GeometryReader`・`DropDelegate` への置き換えではどれも変わらず、スクロールを外した中身に付けても
/// 変わらず、**インスペクタの列そのもの(スクロールの外)に付けた受け口は効いた**。同じ入れ子でもコレクションの札の受け口は効く
/// (あちらのスクロールの中身には AppKit のマーキーの面が入っている)ので、原因は突き止めていない。
///
/// そこで、受け口は**インスペクタの列に 1 つだけ**置き(`HomeInspectorDropDelegate`)、表紙は自分の枠と受け取り方を
/// ここへ登録する。列の受け口は、落ちた位置が表紙の枠の中なら表紙へ、外ならウインドウ全体の受け口と同じ扱い
/// (`AppState.openDroppedFiles`)へ回す。
@MainActor @Observable
final class HomeInspectorCoverDrop {
    /// 表紙の枠を測る座標空間の名前(インスペクタの列 = 受け口を付けたビュー)。
    nonisolated static let coordinateSpace = "homeInspector.coverDrop"

    /// いま登録している表紙(1 つだけ ―― インスペクタは本を 1 冊しか出さない)。
    @ObservationIgnored private var ownerID: UUID?
    @ObservationIgnored private var frame: CGRect = .null
    @ObservationIgnored private var receive: ((URL) -> Void)?
    /// ドラッグが表紙の上にある(表紙の強調)。
    private(set) var isTargeted = false

    func register(_ id: UUID, receive: @escaping (URL) -> Void) {
        ownerID = id
        self.receive = receive
    }

    func updateFrame(_ frame: CGRect, for id: UUID) {
        guard ownerID == id else { return }
        self.frame = frame
    }

    func unregister(_ id: UUID) {
        guard ownerID == id else { return }
        ownerID = nil
        receive = nil
        frame = .null
        setTargeted(false)
    }

    func isTargeted(by id: UUID) -> Bool { isTargeted && ownerID == id }

    /// 落ちる位置が表紙の上か(表紙が登録されていれば)。
    func accepts(at location: CGPoint) -> Bool {
        receive != nil && frame.contains(location)
    }

    func setTargeted(_ targeted: Bool) {
        if isTargeted != targeted { isTargeted = targeted }
    }

    func deliver(_ url: URL) {
        receive?(url)
    }
}

extension EnvironmentValues {
    /// インスペクタの表紙の受け口(インスペクタの中だけ。外では nil ―― 表紙は自分で受ける)。
    @Entry var homeInspectorCoverDrop: HomeInspectorCoverDrop?
}

/// インスペクタの列の受け口(`HomeInspectorCoverDrop` の型コメント)。表紙の外に落ちたものは、ウインドウ全体の受け口と同じく
/// 開く(編集モードの本棚なら登録する)。ホームから運び出している本を同じウインドウへ落としたときは受け取らない
/// (ウインドウ全体の受け口と同じ。HomeBookDragTracker)。
/// 表紙の外の上にある間は、ウインドウ全体の受け口と同じ縁の強調を出してもらう(`AppState.isInnerFileDropTargeted`。この列が
/// 受けている間、ウインドウ全体の受け口は反応しないので、出さないと開くのか分からない。2026-10-01 のレビュー)。
/// URL の取り出しは `loadDroppedFileURLs`(BookFileDropTarget.swift)の 1 か所に任せる。
struct HomeInspectorDropDelegate: DropDelegate {
    let coverDrop: HomeInspectorCoverDrop
    let appState: AppState

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL]) && !HomeBookDragTracker.isDragging(from: appState)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let onCover = coverDrop.accepts(at: info.location)
        coverDrop.setTargeted(onCover)
        setWindowTargeted(!onCover)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        coverDrop.setTargeted(false)
        setWindowTargeted(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        let onCover = coverDrop.accepts(at: info.location)
        coverDrop.setTargeted(false)
        setWindowTargeted(false)
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let coverDrop = coverDrop
        let appState = appState
        Task { @MainActor in
            let urls = await loadDroppedFileURLs(from: providers)
            if onCover {
                // 表紙へは画像 1 枚だけ(以前のシートの表紙と同じ)。画像が無ければ何もしない。
                if let image = urls.first(where: { isImageFile($0.lastPathComponent) }) { coverDrop.deliver(image) }
            } else {
                appState.openDroppedFiles(urls)
            }
        }
        return true
    }

    private func setWindowTargeted(_ targeted: Bool) {
        if appState.isInnerFileDropTargeted != targeted { appState.isInnerFileDropTargeted = targeted }
    }
}

extension View {
    /// インスペクタの列に付ける受け口と、表紙の枠を測る座標空間。
    func homeInspectorDropTarget(_ coverDrop: HomeInspectorCoverDrop, appState: AppState) -> some View {
        environment(\.homeInspectorCoverDrop, coverDrop)
            .coordinateSpace(.named(HomeInspectorCoverDrop.coordinateSpace))
            .onDrop(of: [.fileURL], delegate: HomeInspectorDropDelegate(coverDrop: coverDrop, appState: appState))
            // ドラッグの最中に列が消えたら(本を開いた・インスペクタを隠した)、離れた知らせが来ないことがあるので、縁の強調を下ろす。
            .onDisappear { [weak appState] in
                if appState?.isInnerFileDropTargeted == true { appState?.isInnerFileDropTargeted = false }
            }
    }
}

/// 表紙の側: インスペクタの中なら列の受け口へ枠と受け取り方を登録し、外なら自分で受ける(`fileURLDropTarget`)。
struct CoverImageDropModifier: ViewModifier {
    @Binding var isTargeted: Bool
    let onDropImage: (URL) -> Void

    @Environment(\.homeInspectorCoverDrop) private var coverDrop
    @State private var id = UUID()

    func body(content: Content) -> some View {
        if let coverDrop {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(HomeInspectorCoverDrop.coordinateSpace)) } action: {
                    coverDrop.updateFrame($0, for: id)
                }
                .onAppear { coverDrop.register(id, receive: onDropImage) }
                .onDisappear { coverDrop.unregister(id) }
                .onChange(of: coverDrop.isTargeted(by: id)) { _, targeted in isTargeted = targeted }
        } else {
            content.fileURLDropTarget(isTargeted: $isTargeted) { urls in
                guard let imageURL = urls.first(where: { isImageFile($0.lastPathComponent) }) else { return }
                onDropImage(imageURL)
            }
        }
    }
}

import Foundation

/// 本を開いている途中の進み具合(`BookLoader.load(from:...)`が知らせる)。
///
/// 総数を先に確定できない ―― 書庫の中に何本の書庫が入っているかは、その書庫を開いて
/// みるまで分からず、開くには取り出しが要る ―― ため、「見つけた数」と「読み終えた数」の
/// 2つで表す。`discoveredArchiveCount`は走査が進むほど増えていくので、割合の分母として
/// 使うぶんには構わないが、単調に100%へ近づくとは限らない。UI側はそれを前提に、
/// 割合ではなく件数を出すか、伸びうるバーとして扱うこと。
///
/// nonisolated: BookLoaderの読み込みタスク(メインアクター外)が組み立てるため
/// (詳細はArchiveReading.swift冒頭のコメント参照)。
nonisolated struct BookLoadProgress: Equatable, Sendable {
    /// 中身を数え上げるべき書庫として見つけた数(本そのものの書庫を含む)。
    var discoveredArchiveCount: Int = 0
    /// 実際に開いて中身を数え上げ終えた書庫の数。
    var completedArchiveCount: Int = 0
    /// 直近に数え上げ終えた書庫のファイル名。表示用。
    var currentArchiveName: String?
}

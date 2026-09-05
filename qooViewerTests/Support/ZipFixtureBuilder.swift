import Foundation
import ZIPFoundation

/// テストの中で zip(cbz / EPUB のコンテナ)を組み立てる。
///
/// ZIPFoundation で書くので、エントリ名は常に UTF-8 + 汎用フラグ bit 11 になる。UTF-8 フラグ無し・
/// レガシーな文字コードの書庫はここでは作れない ―― それらは scripts/fixtures/make-legacy-zip.py で
/// 作ってコミットしてある(qooViewerTests/Fixtures/zip/)。
nonisolated struct ZipFixtureBuilder {
    struct Entry {
        let path: String
        let data: Data
        let isDirectory: Bool
        /// 無圧縮で入れる(EPUB の mimetype はこれが必須)。
        let stored: Bool
    }

    private(set) var entries: [Entry] = []

    init() {}

    mutating func add(_ path: String, _ data: Data, stored: Bool = false) {
        entries.append(Entry(path: path, data: data, isDirectory: false, stored: stored))
    }

    mutating func add(_ path: String, text: String, stored: Bool = false) {
        add(path, Data(text.utf8), stored: stored)
    }

    mutating func addDirectory(_ path: String) {
        let normalized = path.hasSuffix("/") ? path : path + "/"
        entries.append(Entry(path: normalized, data: Data(), isDirectory: true, stored: true))
    }

    /// `url` に書く(あれば置き換える)。エントリは追加した順に並ぶ。
    func write(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let archive = try Archive(url: url, accessMode: .create)
        for entry in entries {
            if entry.isDirectory {
                // uncompressedSize は UInt32 版(非推奨)と Int64 版があり、リテラルだと曖昧になる。
                try archive.addEntry(
                    with: entry.path, type: .directory, uncompressedSize: Int64(0),
                    compressionMethod: .none, provider: { _, _ in Data() }
                )
                continue
            }
            let data = entry.data
            try archive.addEntry(
                with: entry.path, type: .file, uncompressedSize: Int64(data.count),
                compressionMethod: entry.stored ? .none : .deflate,
                provider: { position, size in
                    let start = Int(position)
                    return data.subdata(in: start..<(start + size))
                }
            )
        }
    }
}

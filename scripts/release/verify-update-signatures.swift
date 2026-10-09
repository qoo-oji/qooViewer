// appcast.xml と更新の書庫の EdDSA 署名を、**アプリに入っている公開鍵で**確かめる(make-appcast.sh が呼ぶ)。
//
//   swift scripts/release/verify-update-signatures.swift appcast.xml qooViewer.zip <SUPublicEDKey の base64>
//
// Sparkle の sign_update --verify はキーチェーン(か鍵ファイル)の鍵で確かめる。ここでは利用者のアプリが実際に
// 使う鍵 ―― 配る .app の Info.plist の SUPublicEDKey ―― で、Sparkle とは別の実装(CryptoKit)で確かめ直す。
// 確かめ方は Sparkle 2.10 と同じ:
// - appcast: 末尾の `<!-- sparkle-signatures:\n … -->` より前のバイト列への署名(SPUExtractSignedFeed.m)と、
//   そこに書かれた length がそのバイト数と一致すること
// - 書庫: enclosure の sparkle:edSignature が書庫のバイト列への署名で、length が書庫の大きさと一致すること
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else { fail("usage: verify-update-signatures.swift appcast.xml archive.zip <public key base64>") }
guard let keyData = Data(base64Encoded: arguments[3]), keyData.count == 32,
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    fail("公開鍵が base64 の 32 バイトではない")
}
guard let appcast = FileManager.default.contents(atPath: arguments[1]) else { fail("appcast を読めない") }
guard let archive = FileManager.default.contents(atPath: arguments[2]) else { fail("書庫を読めない") }

// ── appcast の署名 ──────────────────────────────────────────────────────────────
let prefix = Data("<!-- sparkle-signatures:\n".utf8)
guard let prefixRange = appcast.range(of: prefix, options: .backwards) else { fail("appcast に署名が無い") }
let content = appcast.subdata(in: appcast.startIndex..<prefixRange.lowerBound)
guard let suffixRange = appcast.range(of: Data("-->".utf8), in: prefixRange.upperBound..<appcast.endIndex),
      let block = String(data: appcast.subdata(in: prefixRange.upperBound..<suffixRange.lowerBound), encoding: .utf8) else {
    fail("appcast の署名の欄が読めない")
}
var feedSignature: Data?
var feedLength: Int?
for line in block.split(separator: "\n") {
    if line.hasPrefix("edSignature:") {
        feedSignature = Data(base64Encoded: line.dropFirst("edSignature:".count).trimmingCharacters(in: .whitespaces))
    } else if line.hasPrefix("length:") {
        feedLength = Int(line.dropFirst("length:".count).trimmingCharacters(in: .whitespaces))
    }
}
guard let feedSignature, publicKey.isValidSignature(feedSignature, for: content) else {
    fail("appcast の署名が、アプリの公開鍵で確かめられない")
}
guard feedLength == content.count else { fail("appcast の length(\(feedLength ?? -1))が中身の大きさ(\(content.count))と違う") }
print("ok: appcast の署名はアプリの公開鍵で確かめられた")

// ── 書庫の署名(署名済みの中身の enclosure)───────────────────────────────────────
final class EnclosureReader: NSObject, XMLParserDelegate {
    var enclosures: [[String: String]] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if name == "enclosure" { enclosures.append(attributes) }
    }
}
let reader = EnclosureReader()
let parser = XMLParser(data: content)
parser.delegate = reader
guard parser.parse() else { fail("appcast を XML として読めない") }
guard reader.enclosures.count == 1, let enclosure = reader.enclosures.first else {
    fail("enclosure が \(reader.enclosures.count) 個")
}
guard let archiveSignature = enclosure["sparkle:edSignature"].flatMap({ Data(base64Encoded: $0) }),
      publicKey.isValidSignature(archiveSignature, for: archive) else {
    fail("書庫の署名が、アプリの公開鍵で確かめられない")
}
guard enclosure["length"] == String(archive.count) else {
    fail("enclosure の length(\(enclosure["length"] ?? "なし"))が書庫の大きさ(\(archive.count))と違う")
}
print("ok: 書庫の署名はアプリの公開鍵で確かめられた")

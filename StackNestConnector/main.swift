import Foundation

// StackNest への接続だけを受け持つ XPC サービス(StackNestConnectorWire.swift の冒頭のコメント)。
// 持つ権限は App Sandbox と外への接続だけで、ファイルへのアクセスは持たない(docs/10「StackNest の本と通信」)。
let delegate = StackNestConnectorListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
// 戻らない(dispatch_main)。
listener.resume()

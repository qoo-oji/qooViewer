import Foundation

// LAN の SMB サーバを探し、そのマウントを NetFS に頼むだけの XPC サービス(NetworkVolumeConnectorWire.swift の冒頭のコメント)。
// 持つ権限は App Sandbox と外への接続だけで、ファイルへのアクセスは持たない(docs/10「ネットワークのサーバとボリュームの接続」)。
let delegate = NetworkVolumeConnectorListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
// 戻らない(dispatch_main)。
listener.resume()

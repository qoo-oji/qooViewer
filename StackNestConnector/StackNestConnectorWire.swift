import Foundation

// アプリ(qooViewer)と、StackNest への接続だけを受け持つ XPC サービス(StackNestConnector.xpc)の間の約束。
// このファイルはアプリとサービスの両方に入る(project.pbxproj の StackNestConnector フォルダの例外を参照)。
//
// ■ なぜ XPC サービスに分けるか(docs/10「StackNest の本と通信」)
// アプリ本体はネットワークの entitlement を持たない(持つと、書庫を読む C のコードの不具合を突かれたときに、外へ送り出せて
// しまう)。外への接続(com.apple.security.network.client)を持つのはこのサービスだけで、サービスはファイルへのアクセスを
// 持たず、この Mac の StackNest の本の API への決まった形の要求(StackNestConnectorPolicy)しか出さない。
// アプリの側では StackNestViewerKit をそのまま使い、そのセッションの URLSession に StackNestConnectorURLProtocol を差し込んで、
// 要求をここへ回す(部品の `Configuration.makeURLSessionConfiguration`)。

/// XPC の口。返事(`reply`)はどの要求にも 1 度だけ来る(取り消した要求は `.cancelled` で)。
@objc(QooStackNestConnecting)
nonisolated protocol StackNestConnecting {
    /// 1 件の要求を送る。`request` は `StackNestConnectorRequest` の JSON。返事は、成功なら `response`
    /// (`StackNestConnectorResponse` の JSON)と `body`(本文)、失敗なら `failure`(`StackNestConnectorFailure` の rawValue)。
    func send(_ request: Data, withReply reply: @escaping @Sendable (_ response: Data?, _ body: Data?, _ failure: String?) -> Void)

    /// 送った要求を取り消す(まだ走っていれば)。
    func cancel(_ requestID: String)
}

/// アプリからサービスへ渡す要求。ヘッダは `StackNestConnectorPolicy.forwardedRequestHeaders` のものだけを渡す。
nonisolated struct StackNestConnectorRequest: Codable, Sendable, Equatable {
    var id: String
    var method: String
    var url: String
    var headers: [String: String]
    var body: Data?
}

/// サービスからアプリへ返す応答(本文は別に渡す)。ヘッダは `StackNestConnectorPolicy.returnedResponseHeaders` のものだけ。
nonisolated struct StackNestConnectorResponse: Codable, Sendable, Equatable {
    var statusCode: Int
    var headers: [String: String]
    /// 本文が上限(`StackNestConnectorPolicy.maxResponseBytes`)を超えたので捨てた。アプリの側は、上限を超える
    /// `Content-Length` の応答として部品へ渡す(部品は自分の上限で `.responseTooLarge` にする)。
    var exceededLimit = false
}

/// 要求が応答まで届かなかった理由。
nonisolated enum StackNestConnectorFailure: String, Sendable, Error {
    /// 決まった形でない要求(StackNestConnectorPolicy)。送っていない。
    case refused
    /// つながらない・途中で切れた。
    case cannotConnect
    /// 時間切れ。
    case timedOut
    /// 取り消した。
    case cancelled
    /// サービスに届かない(起動できない・落ちた)。
    case unavailable
}

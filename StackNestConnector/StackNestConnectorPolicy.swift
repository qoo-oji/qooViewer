import Foundation

/// StackNest の本の API への要求として通してよい形(アプリとサービスの両方が同じ判定をする。サービスの判定が最後の砦)。
///
/// 通すのは、この Mac(`127.0.0.1` / `::1`)の平文の HTTP で、StackNest が参照ファイルに書く本の基点
/// (`/api/v1/libraries/<書庫>/books/<番号>` と、リモートの本の中継 `/api/v1/relay/<ID>`)の下の 4 つの要求だけ:
///
/// | 要求 | メソッド |
/// |---|---|
/// | `…/manifest` | GET |
/// | `…/pages/<番号>`(`?maxw=<幅>` だけ付けてよい) | GET |
/// | `…/cover`(同上) | GET |
/// | `…/progress`(JSON の本文。64 KiB まで) | POST |
///
/// 細工した参照ファイルを開いても、この Mac で待ち受けているほかのサービスへ、ほかの形の要求は出ない(StackNestViewerKit は
/// 宛先のホストしか見ず、パスは参照ファイルのとおりに使うため。docs/10)。アプリのプロセスが乗っ取られても、サービスへ頼めるのは
/// この形だけで、外の宛先へは出せない。
nonisolated enum StackNestConnectorPolicy {
    /// 送ってよい要求の本文の上限(読書位置の POST。StackNest は 64 KiB を超える本文を 413 で断る)。
    static let maxRequestBodyBytes = 64 << 10
    /// 受け取る応答の本文の上限。StackNestViewerKit の既定(`maxResponseBytes`)と同じ。
    static let maxResponseBytes = 64 << 20
    /// サービスへ渡すヘッダ(小文字)。鍵(`Authorization`)・名乗り・POST の本文の型だけ。
    static let forwardedRequestHeaders: Set<String> = ["authorization", "x-stacknest-viewer", "content-type"]
    /// アプリへ返すヘッダ。StackNestViewerKit が読むもの。
    static let returnedResponseHeaders = ["Content-Type", "X-Library-Locked", "ETag"]
    /// 名前に使ってよい文字(書庫の UUID・中継の ID)。
    private static let identifierCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    /// 断った理由(ログと試験のため。鍵や URL は含めない)。
    enum Refusal: String, Error, Equatable, Sendable {
        case invalidURL, scheme, host, credentials, fragment, path, query, method, header, body
    }

    /// 要求の形を確かめ、通してよければ送る `URLRequest` を返す(ヘッダは許したものだけ)。
    static func validate(_ request: StackNestConnectorRequest) -> Result<URLRequest, Refusal> {
        guard let url = URL(string: request.url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .failure(.invalidURL) }
        guard components.scheme?.lowercased() == "http" else { return .failure(.scheme) }
        guard let host = url.host(percentEncoded: false)?.lowercased(), host == "127.0.0.1" || host == "::1" else {
            return .failure(.host)
        }
        guard components.user == nil, components.password == nil else { return .failure(.credentials) }
        guard components.fragment == nil else { return .failure(.fragment) }
        if let port = components.port, !(1...65535).contains(port) { return .failure(.invalidURL) }

        guard let endpoint = endpoint(ofPercentEncodedPath: components.percentEncodedPath) else {
            return .failure(.path)
        }
        if let query = components.percentEncodedQuery {
            guard endpoint.acceptsWidth, isWidthQuery(query) else { return .failure(.query) }
        }
        let method = request.method.uppercased()
        guard method == endpoint.method else { return .failure(.method) }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        var sawAuthorization = false
        for (name, value) in request.headers {
            let lowered = name.lowercased()
            guard forwardedRequestHeaders.contains(lowered), isHeaderValue(value) else { return .failure(.header) }
            switch lowered {
            case "authorization":
                guard value.hasPrefix("Bearer "), value.count > 7 else { return .failure(.header) }
                sawAuthorization = true
            case "content-type":
                guard method == "POST", value.lowercased().hasPrefix("application/json") else { return .failure(.header) }
            default:
                break
            }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        guard sawAuthorization else { return .failure(.header) }
        switch (method, request.body) {
        case ("GET", nil):
            break
        case ("GET", let body?) where body.isEmpty:
            break
        case ("POST", let body?) where !body.isEmpty && body.count <= maxRequestBodyBytes:
            urlRequest.httpBody = body
        default:
            return .failure(.body)
        }
        return .success(urlRequest)
    }

    /// 本の基点の下の要求の種類。
    struct Endpoint: Equatable {
        let method: String
        let acceptsWidth: Bool
    }

    /// `/api/v1/libraries/<書庫>/books/<番号>/<要求>` か `/api/v1/relay/<ID>/<要求>` なら、その要求の種類。
    /// パーセント符号化を含むパスは通さない(StackNest の名前は符号化の要らない文字だけでできている。`%2F` などで区切りを
    /// ごまかさせない)。
    static func endpoint(ofPercentEncodedPath path: String) -> Endpoint? {
        guard !path.contains("%") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // 先頭は空(絶対パス)。空の部分(`//`・末尾の `/`)は認めない。
        guard parts.first == "", parts.count >= 2, !parts.dropFirst().contains("") else { return nil }
        var rest = Array(parts.dropFirst())
        guard rest.count >= 2, rest[0] == "api", rest[1] == "v1" else { return nil }
        rest.removeFirst(2)
        if rest.first == "libraries" {
            guard rest.count >= 4, isIdentifier(rest[1]), rest[2] == "books", isDecimal(rest[3]) else { return nil }
            rest.removeFirst(4)
        } else if rest.first == "relay" {
            guard rest.count >= 2, isIdentifier(rest[1]) else { return nil }
            rest.removeFirst(2)
        } else {
            return nil
        }
        switch rest.count {
        case 1 where rest[0] == "manifest": return Endpoint(method: "GET", acceptsWidth: false)
        case 1 where rest[0] == "cover": return Endpoint(method: "GET", acceptsWidth: true)
        case 1 where rest[0] == "progress": return Endpoint(method: "POST", acceptsWidth: false)
        case 2 where rest[0] == "pages" && isDecimal(rest[1]): return Endpoint(method: "GET", acceptsWidth: true)
        default: return nil
        }
    }

    private static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 128 && text != "." && text != ".."
            && text.unicodeScalars.allSatisfy(identifierCharacters.contains)
    }

    private static func isDecimal(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 9 && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// `maxw=<幅>` だけ。
    private static func isWidthQuery(_ query: String) -> Bool {
        guard query.hasPrefix("maxw=") else { return false }
        return isDecimal(String(query.dropFirst(5)))
    }

    /// 印字できる ASCII だけ(改行でヘッダを分けさせない)。
    private static func isHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
    }
}

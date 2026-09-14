import CryptoKit
import Foundation

struct ServiceTokenResult: Sendable, Equatable {
    let serviceToken: String
    let userId: String
}

enum XiaomiSSO {
    static let defaultUserAgent = "MiClaw/1.0"
    static let serviceLoginURL = URL(
        string: "https://account.xiaomi.com/pass/serviceLogin?_locale=zh_CN&_snsNone=true&sid=mimopc&_json=true"
    )!

    /// clientSign = urlencode(base64(SHA1("nonce=" + nonce + "&" + ssecurity)))
    static func clientSign(nonce: String, ssecurity: String) -> String {
        let sigInput = "nonce=\(nonce)&\(ssecurity)"
        let digest = Insecure.SHA1.hash(data: Data(sigInput.utf8))
        let base64 = Data(digest).base64EncodedString()
        return base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? base64
    }

    static func parseExtensionPragma(_ headerValue: String?) -> (nonce: String, ssecurity: String)? {
        guard let headerValue, let data = headerValue.data(using: .utf8) else { return nil }
        struct Pragma: Decodable {
            let nonce: FlexibleString?
            let ssecurity: String?
        }
        guard let parsed = try? JSONDecoder().decode(Pragma.self, from: data),
              let nonce = parsed.nonce?.value, !nonce.isEmpty,
              let ssecurity = parsed.ssecurity, !ssecurity.isEmpty
        else { return nil }
        return (nonce, ssecurity)
    }

    static func parseServiceLoginBody(
        _ data: Data,
        extensionPragma: String? = nil
    ) throws -> (location: String, nonce: String, ssecurity: String, userId: String) {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("&&&START&&&") {
            text = String(text.dropFirst("&&&START&&&".count))
        }
        guard let json = text.data(using: .utf8) else {
            throw UsageError.authExpired
        }

        struct Phase1: Decodable {
            let code: Int
            let location: String?
            let nonce: FlexibleString?
            let ssecurity: String?
            let userId: FlexibleString?
        }

        let body: Phase1
        do {
            body = try JSONDecoder().decode(Phase1.self, from: json)
        } catch {
            throw UsageError.authExpired
        }
        guard body.code == 0,
              let location = body.location, !location.isEmpty
        else {
            throw UsageError.authExpired
        }

        var nonce = body.nonce?.value
        var ssecurity = body.ssecurity
        if nonce == nil || ssecurity == nil || nonce?.isEmpty == true || ssecurity?.isEmpty == true {
            if let fallback = parseExtensionPragma(extensionPragma) {
                nonce = fallback.nonce
                ssecurity = fallback.ssecurity
            }
        }

        if let nonce, let ssecurity, !nonce.isEmpty, !ssecurity.isEmpty {
            return (location, nonce, ssecurity, body.userId?.value ?? "")
        }
        throw UsageError.authExpired
    }

    static func parseServiceToken(from response: HTTPURLResponse) -> String? {
        parseServiceToken(fromHeaderFields: response.allHeaderFields)
    }

    static func parseServiceToken(fromHeaderFields fields: [AnyHashable: Any]) -> String? {
        var candidates: [String] = []
        for (key, value) in fields {
            guard let key = key as? String, key.lowercased() == "set-cookie" else { continue }
            if let value = value as? String {
                candidates.append(value)
            }
        }
        for field in candidates {
            if let token = firstCookieValue(named: "serviceToken", in: field) {
                return token
            }
        }
        return nil
    }

    static func firstCookieValue(named name: String, in field: String) -> String? {
        let prefix = name + "="
        for part in field.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.lowercased().hasPrefix(prefix.lowercased()) {
                let value = String(piece.dropFirst(prefix.count))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Build phase2 URL. Location may already be percent-encoded; append clientSign safely.
    static func phase2URL(location: String, clientSign: String) -> URL? {
        let separator = location.contains("?") ? "&" : "?"
        let joined = location + separator + "clientSign=" + clientSign
        if let url = URL(string: joined) {
            return url
        }
        // Fallback: encode only the sign parameter via URLComponents.
        guard var components = URLComponents(string: location) else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "clientSign", value: clientSign))
        components.queryItems = items
        return components.url
    }
}

struct XiaomiSSOClient: Sendable {
    let http: any HTTPPerforming
    let redirectHTTP: RedirectAwareHTTPClient
    let userAgent: String

    init(
        http: any HTTPPerforming = URLSessionHTTPClient(),
        redirectHTTP: RedirectAwareHTTPClient = RedirectAwareHTTPClient(),
        userAgent: String = XiaomiSSO.defaultUserAgent
    ) {
        self.http = http
        self.redirectHTTP = redirectHTTP
        self.userAgent = userAgent
    }

    func ensureServiceToken(credentials: AccountCredentials) async throws -> ServiceTokenResult {
        // Phase 1
        var request = URLRequest(url: XiaomiSSO.serviceLoginURL)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            JSONHTTP.cookieHeader(from: [
                "passToken": credentials.passToken,
                "userId": credentials.userId,
                "cUserId": credentials.cUserId,
            ]),
            forHTTPHeaderField: "Cookie"
        )

        let phase1Data: Data
        let phase1Response: HTTPURLResponse
        do {
            (phase1Data, phase1Response) = try await http.send(request)
        } catch HTTPError.timeout {
            throw UsageError.timeout
        } catch {
            throw UsageError.network("SSO 第一阶段网络失败")
        }

        guard phase1Response.statusCode == 200 else {
            throw UsageError.authExpired
        }

        let pragma = phase1Response.value(forHTTPHeaderField: "extension-pragma")
        let parsed = try XiaomiSSO.parseServiceLoginBody(phase1Data, extensionPragma: pragma)

        // Phase 2 — follow redirects and capture every Set-Cookie.
        let clientSign = XiaomiSSO.clientSign(nonce: parsed.nonce, ssecurity: parsed.ssecurity)
        guard let phase2URL = XiaomiSSO.phase2URL(location: parsed.location, clientSign: clientSign) else {
            throw UsageError.authExpired
        }

        var phase2Request = URLRequest(url: phase2URL)
        phase2Request.httpMethod = "GET"
        phase2Request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (_, phase2Response, delegate) = try await redirectHTTP.sendCapturingCookies(phase2Request)
            let tokenFromCapture = delegate.cookieValue(named: "serviceToken")
            let tokenFromHeaders = XiaomiSSO.parseServiceToken(from: phase2Response)
            guard let serviceToken = tokenFromCapture ?? tokenFromHeaders else {
                throw UsageError.authExpired
            }
            let userId = parsed.userId.isEmpty ? credentials.userId : parsed.userId
            return ServiceTokenResult(serviceToken: serviceToken, userId: userId)
        } catch let error as UsageError {
            throw error
        } catch HTTPError.timeout {
            throw UsageError.timeout
        } catch {
            throw UsageError.network("SSO 第二阶段网络失败")
        }
    }
}

struct PlatformUsageClient: Sendable {
    let http: any HTTPPerforming
    let apiBaseURL: URL

    init(
        http: any HTTPPerforming = URLSessionHTTPClient(),
        apiBaseURL: URL = PlatformUsageClient.defaultAPIBase()
    ) {
        self.http = http
        self.apiBaseURL = apiBaseURL
    }

    static func defaultAPIBase() -> URL {
        if let override = ProcessInfo.processInfo.environment["MIMO_API_BASE_URL"],
           !override.isEmpty,
           let url = URL(string: override) {
            return url
        }
        if let stored = UserDefaults.standard.string(forKey: "mimoAPIBaseURL"),
           !stored.isEmpty,
           let url = URL(string: stored) {
            return url
        }
        return URL(string: "https://mimo-server-cn.xiaomimimo.com/api")!
    }

    func fetchUsage(serviceToken: String, userId: String) async throws -> RawUsagePayload {
        var components = URLComponents(
            url: apiBaseURL.appendingPathComponent("user/usage"),
            resolvingAgainstBaseURL: false
        )
        // appendingPathComponent can drop trailing slash semantics; force /api/user/usage
        if components?.path.hasSuffix("/user/usage") != true {
            components?.path = (apiBaseURL.path as NSString).appendingPathComponent("user/usage")
        }
        guard let url = components?.url else {
            throw UsageError.network("用量地址无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            JSONHTTP.cookieHeader(from: [
                "serviceToken": serviceToken,
                "userId": userId,
            ]),
            forHTTPHeaderField: "Cookie"
        )

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch HTTPError.timeout {
            throw UsageError.timeout
        } catch HTTPError.transport(let message) {
            throw UsageError.network(message)
        } catch {
            throw UsageError.network("用量请求失败")
        }

        switch response.statusCode {
        case 200:
            break
        case 401:
            throw UsageError.authExpired
        default:
            throw UsageError.network("用量接口返回 HTTP \(response.statusCode)")
        }

        struct Envelope: Decodable {
            let code: Int
            let message: String?
            let data: UsageData?
        }

        struct UsageData: Decodable {
            let percent: Double?
            let remainingPercent: Double?
            let usedPercent: Double?
            let resetDate: String?
            let resetAt: Int?
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw UsageError.noData
        }

        guard envelope.code == 0, let object = envelope.data else {
            throw UsageError.noData
        }

        let remaining = object.percent ?? object.remainingPercent
        if let remaining, !remaining.isFinite || remaining < 0 {
            throw UsageError.invalidPayload
        }

        return RawUsagePayload(
            remainingPercent: remaining,
            usedPercent: object.usedPercent,
            resetDate: object.resetDate,
            resetAtUnix: object.resetAt,
            windows: []
        )
    }
}

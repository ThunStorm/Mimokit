import Foundation

enum BridgeProbeResult: Sendable, Equatable {
    case payload(RawUsagePayload)
    case unsupported
    case unauthorized
    case unavailable(String)
}

/// Channel A: local desktop-api bridge. v1 is probe-only; usage currently 404s.
struct LocalBridgeClient: Sendable {
    let http: any HTTPPerforming
    let configLoader: @Sendable () throws -> DesktopAPIConfig

    init(
        http: any HTTPPerforming = URLSessionHTTPClient(),
        configLoader: @escaping @Sendable () throws -> DesktopAPIConfig = {
            guard let url = ProcessLocator.desktopAPIConfigURL() else {
                throw UsageError.bridgeUnavailable
            }
            return try DesktopAPIConfigParser.load(from: url)
        }
    ) {
        self.http = http
        self.configLoader = configLoader
    }

    func probeUsage() async -> BridgeProbeResult {
        let config: DesktopAPIConfig
        do {
            config = try configLoader()
        } catch {
            return .unavailable("本地桥配置不可用")
        }

        guard let base = config.baseURL else {
            return .unavailable("本地桥地址无效")
        }

        let url = base.appendingPathComponent("v1/user/usage")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await http.send(request)
            switch response.statusCode {
            case 200:
                do {
                    let payload = try parseBridgePayload(data)
                    return .payload(payload)
                } catch {
                    return .unavailable("本地桥用量数据无效")
                }
            case 404:
                return .unsupported
            case 401:
                return .unauthorized
            default:
                return .unavailable("本地桥返回 HTTP \(response.statusCode)")
            }
        } catch HTTPError.timeout {
            return .unavailable("本地桥请求超时")
        } catch {
            return .unavailable("本地桥不可达")
        }
    }

    private func parseBridgePayload(_ data: Data) throws -> RawUsagePayload {
        struct Envelope: Decodable {
            struct DataObject: Decodable {
                let percent: Double?
                let remainingPercent: Double?
                let usedPercent: Double?
                let resetDate: String?
                let resetAt: Int?
            }

            let data: DataObject?
        }

        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let object = envelope.data else {
            throw UsageError.invalidPayload
        }
        return RawUsagePayload(
            remainingPercent: object.percent ?? object.remainingPercent,
            usedPercent: object.usedPercent,
            resetDate: object.resetDate,
            resetAtUnix: object.resetAt,
            windows: []
        )
    }
}

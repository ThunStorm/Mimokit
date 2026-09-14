import Foundation

/// Decodes a JSON string or number into a String (Xiaomi SSO uses both shapes).
struct FlexibleString: Decodable, Sendable, Equatable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
        } else if let number = try? container.decode(Int64.self) {
            value = String(number)
        } else if let number = try? container.decode(Double.self) {
            value = String(number)
        } else {
            throw DecodingError.typeMismatch(
                FlexibleString.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or number")
            )
        }
    }
}

enum UsageWindowKind: String, Sendable, Equatable {
    case fiveHour
    case weekly
    case monthly
    case unknown
}

struct UsageWindow: Sendable, Equatable, Identifiable {
    let id: String
    let kind: UsageWindowKind
    let remainingPercent: Int
    let usedPercent: Double?
    let durationMinutes: Int?
    let resetsAt: Date?
    let receivedAt: Date
}

struct RawWindow: Sendable, Equatable {
    var id: String?
    var kindHint: String?
    var windowDurationMins: Int?
    var remainingPercent: Double?
    var usedPercent: Double?
    var resetsAt: Date?
}

struct RawUsagePayload: Sendable, Equatable {
    var remainingPercent: Double?
    var usedPercent: Double?
    var resetDate: String?
    var resetAtUnix: Int?
    var windows: [RawWindow]
}

enum UsageDisplayState: Sendable, Equatable {
    case loading
    case available(UsageWindow)
    case unavailable(reason: String)
    case stale
}

enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

struct MenuBarDisplayState: Equatable {
    let percentageText: String
    let accessibilityLabel: String
    let tooltip: String
    let remainingPercent: Int?
}

enum UsageError: Error, Equatable {
    case authExpired
    case noData
    case invalidPayload
    case network(String)
    case timeout
    case bridgeUnsupported
    case bridgeUnavailable

    var userMessage: String {
        switch self {
        case .authExpired:
            return "小米登录已过期，请打开 MiMo 重新登录"
        case .noData:
            return "用量接口无数据，请确认已登录小米账号"
        case .invalidPayload:
            return "用量数据格式无效"
        case .network(let message):
            return message
        case .timeout:
            return "请求超时"
        case .bridgeUnsupported, .bridgeUnavailable:
            return "未找到正在运行的 MiMo，且平台接口不可用"
        }
    }
}

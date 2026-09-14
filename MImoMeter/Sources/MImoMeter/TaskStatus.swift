import Foundation

/// Semantic underline status for project agent tasks (not quota-fetch status).
enum UnderlineTaskStatus: String, Sendable, Equatable {
    case idle
    case running
    case recentSuccess
    case needsAttention
    case unknown

    var userLabel: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "运行中"
        case .recentSuccess: return "最近完成"
        case .needsAttention: return "需要处理"
        case .unknown: return "状态未知"
        }
    }
}

/// Terminal/active outcome of one session's latest message.
enum SessionTaskOutcome: Sendable, Equatable {
    case running
    case success(at: Date)
    case needsAttention
    case unknown
    case idle
}

struct ResolvedSessionState: Sendable, Equatable {
    let id: String
    let updated: Date?
    let outcome: SessionTaskOutcome
}

enum TaskStatusResolver {
    /// Green only if success is within this window.
    static let recentSuccessWindow: TimeInterval = 3600
    /// Skip fetching messages for sessions older than this.
    static let sessionLookback: TimeInterval = 7200

    static func shouldInspect(updated: Date?, now: Date) -> Bool {
        guard let updated else { return false }
        return now.timeIntervalSince(updated) <= sessionLookback
    }

    /// Aggregate across sessions: needsAttention > running > recentSuccess > unknown > idle.
    static func resolve(sessions: [ResolvedSessionState], now: Date) -> UnderlineTaskStatus {
        guard !sessions.isEmpty else { return .idle }

        var hasRunning = false
        var hasSuccess = false
        var hasUnknown = false

        for session in sessions {
            switch session.outcome {
            case .needsAttention:
                return .needsAttention
            case .running:
                hasRunning = true
            case .success(let at):
                if now.timeIntervalSince(at) <= recentSuccessWindow {
                    hasSuccess = true
                }
            case .unknown:
                hasUnknown = true
            case .idle:
                break
            }
        }

        if hasRunning { return .running }
        if hasSuccess { return .recentSuccess }
        if hasUnknown { return .unknown }
        return .idle
    }

    static func outcome(fromMessages messages: [BridgeMessage], now: Date) -> SessionTaskOutcome {
        guard let last = messages.last else { return .idle }
        let info = last.info
        let parts = last.parts ?? []
        let tools = parts.filter { $0.type == "tool" }

        if tools.contains(where: { $0.state?.status == "pending" }) {
            return .needsAttention
        }
        // Permission dialog: tool stays "running" with a raw buffer and no metadata.
        if tools.contains(where: { $0.state?.status == "running" && $0.state?.hasMetadata == false }) {
            return .needsAttention
        }

        let completedMs = info?.time?.completed
        let hasRunningTool = tools.contains { $0.state?.status == "running" }
        let role = info?.role

        if role == "assistant", completedMs == nil {
            return .running
        }

        if role == "user" {
            // User sent; agent has not produced a reply yet.
            return .running
        }

        if role == "assistant", let completedMs {
            let completedAt = Date(timeIntervalSince1970: Double(completedMs) / 1000)
            let lastPart = parts.last
            let reason = lastPart?.type == "step-finish" ? lastPart?.reason : nil
            let hasErrorTool = tools.contains { $0.state?.status == "error" }

            if hasRunningTool || reason == "tool-calls" {
                return .running
            }
            if reason == "stop" {
                return .success(at: completedAt)
            }
            if hasErrorTool {
                return .needsAttention
            }
            if reason == nil {
                return .unknown
            }
            // Aborted / other terminal reasons.
            return .needsAttention
        }

        return .unknown
    }
}

// MARK: - Bridge wire models

struct BridgeSession: Decodable, Sendable, Equatable {
    let id: String
    let time: BridgeTime?

    struct BridgeTime: Decodable, Sendable, Equatable {
        let created: Int?
        let updated: Int?
    }

    var updatedDate: Date? {
        guard let updated = time?.updated else { return nil }
        return Date(timeIntervalSince1970: Double(updated) / 1000)
    }
}

struct BridgeMessage: Decodable, Sendable, Equatable {
    let info: Info?
    let parts: [Part]?

    struct Info: Decodable, Sendable, Equatable {
        let role: String?
        let time: Time?

        struct Time: Decodable, Sendable, Equatable {
            let created: Int?
            let completed: Int?
        }
    }

    struct Part: Decodable, Sendable, Equatable {
        let type: String?
        let reason: String?
        let state: ToolState?

        struct ToolState: Decodable, Sendable, Equatable {
            let status: String?
            /// Present once the tool has actually started executing (not while waiting on a permission dialog).
            let hasMetadata: Bool
            let hasRaw: Bool

            enum CodingKeys: String, CodingKey {
                case status
                case metadata
                case raw
            }

            init(status: String? = nil, hasMetadata: Bool = false, hasRaw: Bool = false) {
                self.status = status
                self.hasMetadata = hasMetadata
                self.hasRaw = hasRaw
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                status = try container.decodeIfPresent(String.self, forKey: .status)
                hasMetadata = container.contains(.metadata)
                hasRaw = container.contains(.raw)
            }
        }
    }
}

// MARK: - Client

enum TaskStatusFetchResult: Sendable, Equatable {
    case status(UnderlineTaskStatus)
    case bridgeUnavailable
}

struct TaskStatusClient: Sendable {
    let http: any HTTPPerforming
    let configLoader: @Sendable () throws -> DesktopAPIConfig
    let clock: @Sendable () -> Date

    init(
        http: any HTTPPerforming = URLSessionHTTPClient(),
        configLoader: @escaping @Sendable () throws -> DesktopAPIConfig = {
            guard let url = ProcessLocator.desktopAPIConfigURL() else {
                throw UsageError.bridgeUnavailable
            }
            return try DesktopAPIConfigParser.load(from: url)
        },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http
        self.configLoader = configLoader
        self.clock = clock
    }

    func fetchStatus() async -> TaskStatusFetchResult {
        let config: DesktopAPIConfig
        do {
            config = try configLoader()
        } catch {
            return .bridgeUnavailable
        }
        guard let base = config.baseURL else {
            return .bridgeUnavailable
        }

        let now = clock()
        let sessionsResult = await sendJSON(
            [BridgeSession].self,
            base: base,
            path: "v1/sessions",
            query: "limit=20",
            token: config.token
        )
        guard case .success(let sessions) = sessionsResult else {
            return .bridgeUnavailable
        }

        var resolved: [ResolvedSessionState] = []
        for session in sessions {
            let inspect = TaskStatusResolver.shouldInspect(updated: session.updatedDate, now: now)
            let outcome: SessionTaskOutcome
            if inspect {
                let messagesResult = await sendJSON(
                    [BridgeMessage].self,
                    base: base,
                    path: "v1/sessions/\(session.id)/messages",
                    query: nil,
                    token: config.token
                )
                switch messagesResult {
                case .success(let messages):
                    outcome = TaskStatusResolver.outcome(fromMessages: messages, now: now)
                case .failure:
                    outcome = .unknown
                }
            } else {
                outcome = .idle
            }
            resolved.append(ResolvedSessionState(id: session.id, updated: session.updatedDate, outcome: outcome))
        }

        return .status(TaskStatusResolver.resolve(sessions: resolved, now: now))
    }

    private enum DecodeResult<T: Decodable & Sendable>: Sendable {
        case success(T)
        case failure
    }

    private func sendJSON<T: Decodable & Sendable>(
        _ type: T.Type,
        base: URL,
        path: String,
        query: String?,
        token: String
    ) async -> DecodeResult<T> {
        guard let url = Self.makeURL(base: base, path: path, query: query) else {
            return .failure
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await http.send(request)
            guard response.statusCode == 200 else { return .failure }
            let decoded = try JSONDecoder().decode(T.self, from: data)
            return .success(decoded)
        } catch {
            return .failure
        }
    }

    static func makeURL(base: URL, path: String, query: String?) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/" + path
        components.query = query
        return components.url
    }
}

// MARK: - Monitor

@MainActor
final class TaskStatusMonitor {
    private(set) var status: UnderlineTaskStatus = .idle
    var onChange: (() -> Void)?

    private var timer: Timer?
    private let client: TaskStatusClient
    private let pollInterval: TimeInterval

    init(
        client: TaskStatusClient = TaskStatusClient(),
        pollInterval: TimeInterval = 15
    ) {
        self.client = client
        self.pollInterval = pollInterval
    }

    func start() {
        stop()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if status != .idle {
            status = .idle
            onChange?()
        }
    }

    func refresh() {
        Task { await refreshNow() }
    }

    func refreshNow() async {
        let result = await client.fetchStatus()
        let next: UnderlineTaskStatus
        switch result {
        case .status(let status):
            next = status
        case .bridgeUnavailable:
            next = .idle
        }
        if next != status {
            status = next
            onChange?()
        }
    }
}

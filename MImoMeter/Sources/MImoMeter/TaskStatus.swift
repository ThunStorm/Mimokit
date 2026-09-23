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

enum SessionTaskOutcome: Sendable, Equatable {
    case running
    case success(at: Date)
    case needsAttention
    case unknown
    case idle
}

enum TaskStatusResolver {
    /// After task completion, stay green for this long, then fall back to orange idle.
    static let recentSuccessWindow: TimeInterval = 600
    static let sessionLookback: TimeInterval = 7200

    static func shouldInspect(updated: Date?, now: Date) -> Bool {
        guard let updated else { return false }
        return now.timeIntervalSince(updated) <= sessionLookback
    }

    /// needsAttention > running > recentSuccess > unknown > idle
    static func resolve(outcomes: [SessionTaskOutcome], now: Date) -> UnderlineTaskStatus {
        guard !outcomes.isEmpty else { return .idle }

        var hasRunning = false
        var hasSuccess = false
        var hasUnknown = false

        for outcome in outcomes {
            switch outcome {
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

    /// Tools that normally carry `metadata` while executing. A `raw`-only
    /// running state on these is a permission stall; on other tools (task,
    /// actor, …) `raw` is just the ordinary payload and is NOT attention.
    static let permissionProbeTools: Set<String> = [
        "bash", "edit", "write", "read", "multiedit", "notebookedit",
    ]

    /// Startup grace: raw-only probes younger than this are launching, not stalled.
    static let permissionGraceMs: Double = 3_000

    static func isPermissionWait(
        toolName: String?,
        state: BridgeMessage.Part.ToolState?,
        now: Date = Date()
    ) -> Bool {
        guard let state,
              state.status == "running",
              state.hasRaw,
              !state.hasMetadata
        else { return false }
        let name = (toolName ?? "").lowercased()
        guard permissionProbeTools.contains(name) else { return false }
        if let startMs = state.startMs {
            let ageMs = now.timeIntervalSince1970 * 1000 - Double(startMs)
            if ageMs < permissionGraceMs { return false }
        }
        return true
    }

    static func outcome(fromMessages messages: [BridgeMessage], now: Date = Date()) -> SessionTaskOutcome {
        guard let last = messages.last else { return .idle }
        let info = last.info
        let parts = last.parts ?? []
        let tools = parts.filter { $0.type == "tool" }

        if tools.contains(where: { $0.state?.status == "pending" }) {
            return .needsAttention
        }

        // Permission stall only when nothing has started executing and a
        // metadata-capable probe tool has sat raw-only past the grace window.
        // Parallel tools often show raw-only while a sibling already has
        // metadata — that is startup, not a permission dialog.
        let hasMetadataTool = tools.contains { $0.state?.hasMetadata == true }
        if !hasMetadataTool,
           tools.contains(where: {
               isPermissionWait(toolName: $0.tool, state: $0.state, now: now)
           }) {
            return .needsAttention
        }

        let completedMs = info?.time?.completed
        let hasRunningTool = tools.contains { $0.state?.status == "running" }
        let role = info?.role

        if role == "assistant", completedMs == nil {
            return .running
        }
        if role == "user" {
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
            // Only explicit failure-ish endings are red; length/content-filter
            // and other terminal reasons are gray, not "需要处理".
            if let reason, ["aborted", "error", "interrupted"].contains(reason) {
                return .needsAttention
            }
            return .unknown
        }

        return .unknown
    }
}

// MARK: - Bridge wire models

struct BridgeSession: Decodable, Sendable, Equatable {
    let id: String
    let time: Time?

    struct Time: Decodable, Sendable, Equatable {
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
            let completed: Int?
        }
    }

    struct Part: Decodable, Sendable, Equatable {
        let type: String?
        let reason: String?
        let tool: String?
        let state: ToolState?

        init(
            type: String? = nil,
            reason: String? = nil,
            tool: String? = nil,
            state: ToolState? = nil
        ) {
            self.type = type
            self.reason = reason
            self.tool = tool
            self.state = state
        }

        struct ToolState: Decodable, Sendable, Equatable {
            let status: String?
            let hasMetadata: Bool
            let hasRaw: Bool
            let startMs: Int?

            enum CodingKeys: String, CodingKey {
                case status
                case metadata
                case raw
                case time
            }

            struct TimeBox: Decodable, Sendable, Equatable {
                let start: Int?
                let end: Int?
            }

            init(status: String? = nil, hasMetadata: Bool = false, hasRaw: Bool = false, startMs: Int? = nil) {
                self.status = status
                self.hasMetadata = hasMetadata
                self.hasRaw = hasRaw
                self.startMs = startMs
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                status = try container.decodeIfPresent(String.self, forKey: .status)
                hasMetadata = container.contains(.metadata)
                hasRaw = container.contains(.raw)
                startMs = try container.decodeIfPresent(TimeBox.self, forKey: .time)?.start
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

        let now = Date()
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

        var outcomes: [SessionTaskOutcome] = []
        for session in sessions {
            if TaskStatusResolver.shouldInspect(updated: session.updatedDate, now: now) {
                let messagesResult = await sendJSON(
                    [BridgeMessage].self,
                    base: base,
                    path: "v1/sessions/\(session.id)/messages",
                    query: nil,
                    token: config.token
                )
                switch messagesResult {
                case .success(let messages):
                    outcomes.append(TaskStatusResolver.outcome(fromMessages: messages, now: now))
                case .failure:
                    outcomes.append(.unknown)
                }
            } else {
                outcomes.append(.idle)
            }
        }

        return .status(TaskStatusResolver.resolve(outcomes: outcomes, now: now))
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
            return .success(try JSONDecoder().decode(T.self, from: data))
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

    init(client: TaskStatusClient = TaskStatusClient(), pollInterval: TimeInterval = 15) {
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

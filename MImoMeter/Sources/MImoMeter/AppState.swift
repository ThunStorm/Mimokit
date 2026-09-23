import Foundation

/// Orchestrates bridge probe → platform SSO+usage fallback, poll, and display state.
@MainActor
final class AppState {
    struct Dependencies {
        var bridge: LocalBridgeClient
        var credentials: any CredentialReading
        var sso: XiaomiSSOClient
        var platform: PlatformUsageClient
        var clock: @Sendable () -> Date

        static func live() -> Dependencies {
            Dependencies(
                bridge: LocalBridgeClient(),
                credentials: CredentialSource(),
                sso: XiaomiSSOClient(),
                platform: PlatformUsageClient(),
                clock: { Date() }
            )
        }
    }

    private(set) var usage: UsageDisplayState = .loading
    private(set) var quotaWindows: [UsageWindow] = []
    private(set) var connection: ConnectionState = .disconnected
    private(set) var lastUpdatedAt: Date?
    private(set) var lastErrorReason: String?
    private(set) var consecutiveFailures: Int = 0

    /// Cached SSO token — avoid a full Xiaomi login on every 60s poll.
    private var cachedToken: ServiceTokenResult?
    private var cachedTokenAt: Date?
    private let tokenTTL: TimeInterval = 30 * 60

    var onChange: (() -> Void)?
    private var refreshTimer: Timer?
    private var isRefreshing = false
    private let deps: Dependencies

    init(deps: Dependencies = .live()) {
        self.deps = deps
    }

    var showQuotaPeriod: Bool {
        UserDefaults.standard.bool(forKey: "showQuotaPeriod")
    }

    var showWarningColor: Bool {
        UserDefaults.standard.bool(forKey: "showWarningColor")
    }

    var display: MenuBarDisplayState {
        let remaining: Int?
        let percentageText: String

        switch usage {
        case .available(let window):
            remaining = window.remainingPercent
            let prefix = showQuotaPeriod ? periodPrefix(for: window.kind) : ""
            percentageText = "\(prefix)\(window.remainingPercent)%"
        case .loading, .unavailable, .stale:
            remaining = nil
            percentageText = "--%"
        }

        let resetText = displayedWindow?.resetsAt.map { "，\(Self.resetFormatter.string(from: $0)) 重置" } ?? ""
        let reasonText: String
        switch usage {
        case .unavailable(let reason):
            reasonText = "，\(reason)"
        case .stale:
            reasonText = "，数据已过期"
        case .loading:
            reasonText = "，加载中"
        case .available:
            reasonText = ""
        }

        let label = "MiMo，每周额度剩余 \(percentageText)\(resetText)\(reasonText)"
        return MenuBarDisplayState(
            percentageText: percentageText,
            accessibilityLabel: label,
            tooltip: label,
            remainingPercent: remaining
        )
    }

    var displayedWindow: UsageWindow? {
        if case .available(let window) = usage {
            return window
        }
        return nil
    }

    var menuWindows: [UsageWindow] {
        UsageSelector.selectMenuWindows(quotaWindows)
    }

    func start() {
        scheduleRefreshes()
        refresh()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        Task { await refreshNow() }
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        connection = .connecting
        notify()

        await performRefresh()
        isRefreshing = false
    }

    func markStaleIfNeeded(now: Date = Date()) {
        if let lastUpdatedAt, now.timeIntervalSince(lastUpdatedAt) > 300, usage != .stale {
            usage = .stale
            quotaWindows = []
            notify()
        }
    }

    /// Bridge 200 is only trusted when it normalizes into at least one window.
    static func isUsableBridgePayload(
        _ payload: RawUsagePayload,
        receivedAt: Date = Date()
    ) -> Bool {
        !Normalizer.windows(from: payload, receivedAt: receivedAt).isEmpty
    }

    func applySuccessfulPayload(_ payload: RawUsagePayload, receivedAt: Date = Date()) {
        let windows = Normalizer.windows(from: payload, receivedAt: receivedAt)
        quotaWindows = windows
        guard let selected = UsageSelector.selectDisplayedWindow(windows) else {
            usage = .unavailable(reason: UsageError.noData.userMessage)
            connection = .connected
            lastUpdatedAt = receivedAt
            lastErrorReason = UsageError.noData.userMessage
            notify()
            return
        }
        usage = .available(selected)
        connection = .connected
        lastUpdatedAt = receivedAt
        lastErrorReason = nil
        consecutiveFailures = 0
        notify()
    }

    func applyFailure(_ error: UsageError) {
        consecutiveFailures += 1
        lastErrorReason = error.userMessage
        connection = .failed(error.userMessage)
        usage = .unavailable(reason: error.userMessage)
        quotaWindows = []
        // A failed token means force re-SSO next time.
        if case .authExpired = error {
            cachedToken = nil
            cachedTokenAt = nil
        }
        notify()
    }

    private func performRefresh() async {
        markStaleIfNeeded(now: deps.clock())

        let bridgeResult = await deps.bridge.probeUsage()
        switch bridgeResult {
        case .payload(let payload):
            // Bridge 200 with no usable window must fall through to platform,
            // otherwise an empty/malformed bridge body blocks the real source.
            if Self.isUsableBridgePayload(payload, receivedAt: deps.clock()) {
                applySuccessfulPayload(payload, receivedAt: deps.clock())
                return
            }
        case .unsupported, .unauthorized, .unavailable:
            break // silent fallthrough; bridge errors must not surface in v1
        }

        do {
            let payload = try await fetchPlatformUsage(allowSSORetry: true)
            applySuccessfulPayload(payload, receivedAt: deps.clock())
        } catch let error as UsageError {
            applyFailure(error)
        } catch {
            applyFailure(.network(error.localizedDescription))
        }
    }

    private func fetchPlatformUsage(allowSSORetry: Bool) async throws -> RawUsagePayload {
        let credentials = try deps.credentials.loadAccountCredentials()
        var token = try await validServiceToken(credentials: credentials)

        do {
            return try await deps.platform.fetchUsage(
                serviceToken: token.serviceToken,
                userId: token.userId
            )
        } catch UsageError.authExpired where allowSSORetry {
            cachedToken = nil
            cachedTokenAt = nil
            token = try await deps.sso.ensureServiceToken(credentials: credentials)
            cachedToken = token
            cachedTokenAt = deps.clock()
            return try await deps.platform.fetchUsage(
                serviceToken: token.serviceToken,
                userId: token.userId
            )
        }
    }

    private func validServiceToken(credentials: AccountCredentials) async throws -> ServiceTokenResult {
        if let cachedToken, let cachedTokenAt,
           deps.clock().timeIntervalSince(cachedTokenAt) < tokenTTL {
            return cachedToken
        }
        let token = try await deps.sso.ensureServiceToken(credentials: credentials)
        cachedToken = token
        cachedTokenAt = deps.clock()
        return token
    }

    private func scheduleRefreshes() {
        refreshTimer?.invalidate()
        let interval = currentPollInterval()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.markStaleIfNeeded(now: self.deps.clock())
                self.refresh()
                self.scheduleRefreshes()
            }
        }
    }

    private func currentPollInterval() -> TimeInterval {
        let configured = UserDefaults.standard.object(forKey: "refreshIntervalSeconds") as? Double ?? 60
        let base = max(30, configured)
        if consecutiveFailures <= 0 { return base }
        let backoff = min(300, base * pow(2, Double(min(consecutiveFailures, 3))))
        return backoff
    }

    private func periodPrefix(for kind: UsageWindowKind) -> String {
        switch kind {
        case .weekly: return "W "
        case .fiveHour: return "5h "
        case .monthly: return "M "
        case .unknown: return ""
        }
    }

    private func notify() {
        onChange?()
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()
}

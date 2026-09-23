import CryptoKit
import Foundation

/// Lightweight in-process test runner (no XCTest; works with CommandLineTools-only toolchains).
@MainActor
enum SelfTests {
    private static var failures: [String] = []
    private static var passed = 0

    static func run() -> Int32 {
        failures = []
        passed = 0

        runSuite("UsageSelector") {
            expect(UsageSelector.kind(for: 300) == .fiveHour, "duration 300 → fiveHour")
            expect(UsageSelector.kind(for: 10_080) == .weekly, "duration 10080 → weekly")
            expect(UsageSelector.kind(for: 43_200) == .monthly, "duration 43200 → monthly")
            expect(UsageSelector.kind(for: 60) == .unknown, "duration 60 → unknown")
            expect(UsageSelector.kind(fromHint: "weekly") == .weekly, "hint weekly")
            expect(UsageSelector.kind(fromHint: "5h") == .fiveHour, "hint 5h")
            expect(UsageSelector.kind(fromHint: "other") == nil, "hint other nil")

            let weekly = window(kind: .weekly, remaining: 62)
            let five = window(kind: .fiveHour, remaining: 40)
            expect(UsageSelector.selectDisplayedWindow([five, weekly])?.kind == .weekly, "display prefers weekly")
            expect(UsageSelector.selectDisplayedWindow([]) == nil, "display empty nil")
            expect(UsageSelector.selectDisplayedWindow([five])?.kind == .fiveHour, "display fallback fiveHour")
            expect(UsageSelector.selectDisplayedWindow([window(kind: .monthly, remaining: 1)])?.kind == .monthly, "display fallback monthly")

            let menu = UsageSelector.selectMenuWindows([
                window(kind: .unknown, remaining: 5, id: "u1"),
                window(kind: .weekly, remaining: 62, id: "w1"),
                window(kind: .fiveHour, remaining: 40, id: "f1"),
                window(kind: .weekly, remaining: 50, id: "w2"),
            ])
            expect(menu.map(\.kind) == [.fiveHour, .weekly, .unknown], "menu order")
            expect(menu.first { $0.kind == .weekly }?.id == "w1", "menu dedup weekly")

            expect(UsageSelector.remainingPercent(from: 97.6) == 98, "round 97.6 → 98")
            expect(UsageSelector.remainingPercent(from: 150) == 100, "clamp 150 → 100")
            expect(UsageSelector.remainingPercent(from: -1) == nil, "invalid negative")
            expect(UsageSelector.remainingPercent(from: .nan) == nil, "invalid nan")
            expect(UsageSelector.remainingPercent(usedPercent: 16) == 84, "used 16 → remaining 84")
        }

        runSuite("Normalizer") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let top = RawUsagePayload(
                remainingPercent: 97.6,
                usedPercent: nil,
                resetDate: "2026-09-17",
                resetAtUnix: 1_789_650_777,
                windows: []
            )
            let topWindows = Normalizer.windows(from: top, receivedAt: now)
            expect(topWindows.count == 1, "top-level single window")
            expect(topWindows.first?.kind == .weekly, "top-level forced weekly")
            expect(topWindows.first?.remainingPercent == 98, "top-level remaining 98")
            expect(topWindows.first?.resetsAt?.timeIntervalSince1970 == 1_789_650_777, "resetAt preferred")

            let resetDateOnly = RawUsagePayload(
                remainingPercent: 50, usedPercent: nil, resetDate: "2026-09-17", resetAtUnix: nil, windows: []
            )
            expect(Normalizer.windows(from: resetDateOnly, receivedAt: now).first?.resetsAt != nil, "resetDate fallback")

            expect(
                Normalizer.windows(
                    from: RawUsagePayload(remainingPercent: -5, usedPercent: nil, resetDate: nil, resetAtUnix: nil, windows: []),
                    receivedAt: now
                ).isEmpty,
                "negative percent dropped"
            )
            expect(
                Normalizer.windows(
                    from: RawUsagePayload(remainingPercent: nil, usedPercent: nil, resetDate: nil, resetAtUnix: nil, windows: []),
                    receivedAt: now
                ).isEmpty,
                "missing percent dropped"
            )

            let multi = RawUsagePayload(
                remainingPercent: nil, usedPercent: nil, resetDate: nil, resetAtUnix: nil,
                windows: [
                    RawWindow(id: "a", kindHint: nil, windowDurationMins: 300, remainingPercent: 40, usedPercent: nil, resetsAt: nil),
                    RawWindow(id: "b", kindHint: nil, windowDurationMins: 10_080, remainingPercent: 62, usedPercent: nil, resetsAt: nil),
                    RawWindow(id: "c", kindHint: nil, windowDurationMins: 43_200, remainingPercent: 80, usedPercent: nil, resetsAt: nil),
                    RawWindow(id: "d", kindHint: nil, windowDurationMins: 42, remainingPercent: 10, usedPercent: nil, resetsAt: nil),
                ]
            )
            expect(
                Normalizer.windows(from: multi, receivedAt: now).map(\.kind) == [.fiveHour, .weekly, .monthly, .unknown],
                "duration classification"
            )

            let hint = RawUsagePayload(
                remainingPercent: nil, usedPercent: nil, resetDate: nil, resetAtUnix: nil,
                windows: [
                    RawWindow(id: "x", kindHint: "weekly", windowDurationMins: 300, remainingPercent: 10, usedPercent: nil, resetsAt: nil)
                ]
            )
            expect(Normalizer.windows(from: hint, receivedAt: now).first?.kind == .weekly, "hint overrides duration")

            let usedOnly = RawUsagePayload(
                remainingPercent: nil, usedPercent: nil, resetDate: nil, resetAtUnix: nil,
                windows: [
                    RawWindow(id: "u", kindHint: "weekly", windowDurationMins: nil, remainingPercent: nil, usedPercent: 16, resetsAt: nil)
                ]
            )
            expect(Normalizer.windows(from: usedOnly, receivedAt: now).first?.remainingPercent == 84, "usedPercent only")
        }

        runSuite("DesktopAPIConfig") {
            let ok = try DesktopAPIConfigParser.parse(
                data: Data(#"{"api":"http://127.0.0.1:19347","port":19347,"token":"abc","pid":42}"#.utf8)
            )
            expect(ok.port == 19347 && ok.token == "abc" && ok.baseURL?.absoluteString == "http://127.0.0.1:19347", "valid config")
            expectThrows({ _ = try DesktopAPIConfigParser.parse(data: Data(#"{"port":1}"#.utf8)) }, "missing token")
            expectThrows({ _ = try DesktopAPIConfigParser.parse(data: Data(#"{"token":"abc"}"#.utf8)) }, "missing port")
            expectThrows({ _ = try DesktopAPIConfigParser.parse(data: Data("not-json".utf8)) }, "bad json")
            let portOnly = try DesktopAPIConfigParser.parse(data: Data(#"{"port":9000,"token":"t"}"#.utf8))
            expect(portOnly.baseURL?.absoluteString == "http://127.0.0.1:9000", "port fallback URL")
            let apiNumber = try DesktopAPIConfigParser.parse(
                data: Data(#"{"api":1,"port":61873,"token":"tok","pid":4300}"#.utf8)
            )
            expect(apiNumber.baseURL?.absoluteString == "http://127.0.0.1:61873", "api as number uses port")
            expect(apiNumber.token == "tok", "api number token kept")
            let apiURL = try DesktopAPIConfigParser.parse(
                data: Data(#"{"api":"http://127.0.0.1:19347","port":19347,"token":"tok"}"#.utf8)
            )
            expect(apiURL.baseURL?.absoluteString == "http://127.0.0.1:19347", "api as URL string")
        }

        runSuite("SSO") {
            let sign = XiaomiSSO.clientSign(nonce: "abc", ssecurity: "def")
            let expected = Data(Insecure.SHA1.hash(data: Data("nonce=abc&def".utf8)))
                .base64EncodedString()
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            expect(sign == expected, "clientSign formula")
            expect(!sign.contains("+") && !sign.contains("/") && !sign.contains("="), "clientSign encoded")

            let body = Data("&&&START&&&{\"code\":0,\"location\":\"https://example.com/x\",\"nonce\":\"n1\",\"ssecurity\":\"s1\",\"userId\":\"42\"}".utf8)
            let parsed = try XiaomiSSO.parseServiceLoginBody(body)
            expect(parsed.nonce == "n1" && parsed.ssecurity == "s1" && parsed.userId == "42", "phase1 parse")

            expectThrows({ _ = try XiaomiSSO.parseServiceLoginBody(Data("&&&START&&&{\"code\":70016}".utf8)) }, "phase1 non-zero code")

            let response = HTTPURLResponse(
                url: URL(string: "https://mimo-server-cn.xiaomimimo.com")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Set-Cookie": "serviceToken=abc+/=xyz; Domain=mimo-server-cn.xiaomimimo.com; Path=/"]
            )!
            expect(XiaomiSSO.parseServiceToken(from: response) == "abc+/=xyz", "serviceToken parse")
        }

        runSuite("AppState display") {
            let state = AppState(deps: mockDeps { _ in
                (Data(), httpResponse(status: 404))
            })
            state.applySuccessfulPayload(
                RawUsagePayload(remainingPercent: 62, usedPercent: nil, resetDate: nil, resetAtUnix: nil, windows: [])
            )
            expect(state.display.percentageText == "62%", "available 62%")
            expect(state.display.remainingPercent == 62, "remaining 62")
            expect(state.menuWindows.count == 1, "menu one window")

            state.applyFailure(.authExpired)
            expect(state.display.percentageText == "--%", "failure shows --%")
            expect(state.quotaWindows.isEmpty, "failure clears windows")

            state.applySuccessfulPayload(
                RawUsagePayload(remainingPercent: 40, usedPercent: nil, resetDate: nil, resetAtUnix: nil, windows: []),
                receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            state.markStaleIfNeeded(now: Date(timeIntervalSince1970: 1_700_000_000 + 301))
            expect(state.usage == .stale, "stale after 5min")
            expect(state.display.percentageText == "--%", "stale shows --%")
        }

        runSuite("MeterLifecycle") {
            expect(MeterLifecycle.afterLaunch(meterActive: false) == .start, "launch starts idle meter")
            expect(MeterLifecycle.afterLaunch(meterActive: true) == .refresh, "launch refreshes live meter")
            expect(
                MeterLifecycle.afterTerminate(mimoStillRunning: true, meterActive: true) == .refresh,
                "update relaunch keeps meter (refresh)"
            )
            expect(
                MeterLifecycle.afterTerminate(mimoStillRunning: true, meterActive: false) == .start,
                "update relaunch restarts meter"
            )
            expect(
                MeterLifecycle.afterTerminate(mimoStillRunning: false, meterActive: true) == .stop,
                "real quit stops meter"
            )
            expect(MeterLifecycle.reconcile(mimoRunning: true, meterActive: false) == .start, "reconcile start")
            expect(MeterLifecycle.reconcile(mimoRunning: false, meterActive: true) == .stop, "reconcile stop")
            expect(MeterLifecycle.reconcile(mimoRunning: true, meterActive: true) == .none, "reconcile keep")
            expect(MeterLifecycle.reconcile(mimoRunning: false, meterActive: false) == .none, "reconcile idle")
        }

        runSuite("Bridge empty falls through") {
            let empty = RawUsagePayload(
                remainingPercent: nil, usedPercent: nil, resetDate: nil, resetAtUnix: nil, windows: []
            )
            expect(!AppState.isUsableBridgePayload(empty), "empty bridge payload rejected")
            let missingPercent = RawUsagePayload(
                remainingPercent: nil,
                usedPercent: nil,
                resetDate: "2026-09-17",
                resetAtUnix: 1,
                windows: []
            )
            expect(!AppState.isUsableBridgePayload(missingPercent), "missing percent rejected")
            let usable = RawUsagePayload(
                remainingPercent: 42.4, usedPercent: nil, resetDate: nil, resetAtUnix: nil, windows: []
            )
            expect(AppState.isUsableBridgePayload(usable), "percent payload accepted")
        }

        runSuite("TaskStatus") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            expect(TaskStatusResolver.resolve(outcomes: [], now: now) == .idle, "empty outcomes idle")
            expect(TaskStatusResolver.resolve(outcomes: [.idle], now: now) == .idle, "all idle")
            expect(
                TaskStatusResolver.resolve(outcomes: [.success(at: now), .running], now: now) == .running,
                "running beats success"
            )
            expect(
                TaskStatusResolver.resolve(outcomes: [.running, .needsAttention], now: now) == .needsAttention,
                "needsAttention beats running"
            )
            expect(
                TaskStatusResolver.resolve(outcomes: [.success(at: now)], now: now) == .recentSuccess,
                "fresh success green"
            )
            expect(
                TaskStatusResolver.resolve(
                    outcomes: [.success(at: now.addingTimeInterval(-599))],
                    now: now
                ) == .recentSuccess,
                "success within 10min is green"
            )
            expect(
                TaskStatusResolver.resolve(
                    outcomes: [.success(at: now.addingTimeInterval(-601))],
                    now: now
                ) == .idle,
                "success older than 10min is idle"
            )
            expect(TaskStatusResolver.resolve(outcomes: [.unknown], now: now) == .unknown, "unknown stays gray")

            let runningMessages = [
                BridgeMessage(
                    info: .init(role: "assistant", time: .init(completed: nil)),
                    parts: [
                        .init(type: "tool", reason: nil, tool: "bash", state: .init(status: "running", hasMetadata: true))
                    ]
                )
            ]
            expect(
                TaskStatusResolver.outcome(fromMessages: runningMessages) == .running,
                "running tool → running"
            )

            let permissionMessages = [
                BridgeMessage(
                    info: .init(role: "assistant", time: .init(completed: nil)),
                    parts: [
                        .init(
                            type: "tool",
                            reason: nil,
                            tool: "bash",
                            state: .init(status: "running", hasMetadata: false, hasRaw: true, startMs: 1_000)
                        )
                    ]
                )
            ]
            expect(
                TaskStatusResolver.outcome(fromMessages: permissionMessages, now: Date(timeIntervalSince1970: 10)) == .needsAttention,
                "bash raw-only past grace (permission wait) → needsAttention"
            )

            // Parallel tools: sibling already has metadata → startup, not permission.
            let parallelStartup = [
                BridgeMessage(
                    info: .init(role: "assistant", time: .init(completed: nil)),
                    parts: [
                        .init(
                            type: "tool",
                            reason: nil,
                            tool: "bash",
                            state: .init(status: "running", hasMetadata: true, hasRaw: false, startMs: 1_000)
                        ),
                        .init(
                            type: "tool",
                            reason: nil,
                            tool: "task",
                            state: .init(status: "running", hasMetadata: false, hasRaw: true, startMs: 1_002)
                        ),
                    ]
                )
            ]
            expect(
                TaskStatusResolver.outcome(fromMessages: parallelStartup, now: Date(timeIntervalSince1970: 10)) == .running,
                "parallel raw-only sibling is running, not red"
            )

            // task tool raw-only alone is a normal running payload, not permission.
            let taskRawOnly = [
                BridgeMessage(
                    info: .init(role: "assistant", time: .init(completed: nil)),
                    parts: [
                        .init(
                            type: "tool",
                            reason: nil,
                            tool: "task",
                            state: .init(status: "running", hasMetadata: false, hasRaw: true, startMs: 1_000)
                        )
                    ]
                )
            ]
            expect(
                TaskStatusResolver.outcome(fromMessages: taskRawOnly, now: Date(timeIntervalSince1970: 10)) == .running,
                "task raw-only is running, not permission"
            )

            // Fresh raw-only probe inside grace window is still launching.
            let freshProbe = [
                BridgeMessage(
                    info: .init(role: "assistant", time: .init(completed: nil)),
                    parts: [
                        .init(
                            type: "tool",
                            reason: nil,
                            tool: "bash",
                            state: .init(status: "running", hasMetadata: false, hasRaw: true, startMs: 10_000)
                        )
                    ]
                )
            ]
            expect(
                TaskStatusResolver.outcome(fromMessages: freshProbe, now: Date(timeIntervalSince1970: 10.5)) == .running,
                "fresh bash raw-only within grace → running"
            )

            let lengthEnd = [
                BridgeMessage(
                    info: .init(role: "assistant", time: .init(completed: 2_000)),
                    parts: [
                        .init(type: "tool", reason: nil, tool: "bash", state: .init(status: "completed", hasMetadata: true)),
                        .init(type: "step-finish", reason: "length", state: nil),
                    ]
                )
            ]
            expect(
                TaskStatusResolver.outcome(fromMessages: lengthEnd) == .unknown,
                "length ending is gray, not red"
            )

            let successMessages = [
                BridgeMessage(
                    info: .init(role: "assistant", time: .init(completed: 1_700_000_000_000)),
                    parts: [
                        .init(type: "tool", reason: nil, tool: "bash", state: .init(status: "completed", hasMetadata: true)),
                        .init(type: "step-finish", reason: "stop", state: nil),
                    ]
                )
            ]
            expect(
                TaskStatusResolver.outcome(fromMessages: successMessages) == .success(at: now),
                "stop → success"
            )

            let pendingMessages = [
                BridgeMessage(
                    info: .init(role: "assistant", time: .init(completed: nil)),
                    parts: [
                        .init(type: "tool", reason: nil, tool: "bash", state: .init(status: "pending"))
                    ]
                )
            ]
            expect(
                TaskStatusResolver.outcome(fromMessages: pendingMessages) == .needsAttention,
                "pending tool → needsAttention"
            )

            let errorAbortMessages = [
                BridgeMessage(
                    info: .init(role: "assistant", time: .init(completed: 2_000)),
                    parts: [
                        .init(type: "tool", reason: nil, tool: "bash", state: .init(status: "error", hasMetadata: true)),
                        .init(type: "step-finish", reason: "aborted", state: nil),
                    ]
                )
            ]
            expect(
                TaskStatusResolver.outcome(fromMessages: errorAbortMessages) == .needsAttention,
                "error+abort → needsAttention"
            )

            let userLast = [
                BridgeMessage(
                    info: .init(role: "user", time: .init(completed: nil)),
                    parts: [
                        .init(type: "text", reason: nil, state: nil)
                    ]
                )
            ]
            expect(
                TaskStatusResolver.outcome(fromMessages: userLast) == .running,
                "user last → running"
            )

            expect(TaskStatusResolver.shouldInspect(updated: now, now: now), "inspect fresh session")
            expect(
                !TaskStatusResolver.shouldInspect(updated: now.addingTimeInterval(-7201), now: now),
                "skip old session"
            )

            let url = TaskStatusClient.makeURL(
                base: URL(string: "http://127.0.0.1:9")!,
                path: "v1/sessions",
                query: "limit=20"
            )
            expect(url?.absoluteString == "http://127.0.0.1:9/v1/sessions?limit=20", "URL with query")
            let msgURL = TaskStatusClient.makeURL(
                base: URL(string: "http://127.0.0.1:9")!,
                path: "v1/sessions/ses_1/messages",
                query: nil
            )
            expect(msgURL?.absoluteString == "http://127.0.0.1:9/v1/sessions/ses_1/messages", "URL path")
        }

        print("")
        if failures.isEmpty {
            print("SELF-TESTS PASSED (\(passed) checks)")
            return 0
        }
        print("SELF-TESTS FAILED: \(failures.count) failure(s), \(passed) passed")
        for failure in failures {
            print("  ✗ \(failure)")
        }
        return 1
    }

    // MARK: - helpers

    private static func runSuite(_ name: String, _ body: () throws -> Void) {
        print("• \(name)")
        do {
            try body()
        } catch {
            failures.append("\(name) threw \(error)")
        }
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
        } else {
            failures.append(message)
            print("  ✗ \(message)")
        }
    }

    private static func expectThrows(_ body: () throws -> Void, _ message: String) {
        do {
            try body()
            failures.append("\(message) (no error)")
            print("  ✗ \(message) (no error)")
        } catch {
            passed += 1
        }
    }

    private static func window(kind: UsageWindowKind, remaining: Int, id: String? = nil) -> UsageWindow {
        UsageWindow(
            id: id ?? "\(kind.rawValue)-\(remaining)",
            kind: kind,
            remainingPercent: remaining,
            usedPercent: Double(100 - remaining),
            durationMinutes: nil,
            resetsAt: nil,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private nonisolated static func httpResponse(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://127.0.0.1")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private struct ImmediateHTTP: HTTPPerforming {
        let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await handler(request)
        }
    }

    private struct StaticCredentials: CredentialReading {
        func loadAccountCredentials() throws -> AccountCredentials {
            AccountCredentials(passToken: "pt", userId: "1", cUserId: "c")
        }
    }

    private static func mockDeps(
        _ handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) -> AppState.Dependencies {
        AppState.Dependencies(
            bridge: LocalBridgeClient(
                http: ImmediateHTTP(handler: handler),
                configLoader: {
                    DesktopAPIConfig(api: "http://127.0.0.1:1", port: 1, token: "t", pid: 1)
                }
            ),
            credentials: StaticCredentials(),
            sso: XiaomiSSOClient(http: ImmediateHTTP(handler: handler)),
            platform: PlatformUsageClient(
                http: ImmediateHTTP(handler: handler),
                apiBaseURL: URL(string: "https://example.com/api")!
            ),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }
}

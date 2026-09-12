import AppKit
import Foundation

@main
struct MImoMeterApp {
    static func main() {
        if CommandLine.arguments.contains("--run-self-tests") {
            let code = MainActor.assumeIsolated {
                SelfTests.run()
            }
            exit(code)
        }

        if CommandLine.arguments.contains("--fetch-once") {
            let semaphore = DispatchSemaphore(value: 0)
            var code: Int32 = 1
            Task { @MainActor in
                code = await FetchOnce.run()
                semaphore.signal()
            }
            while true {
                let result = semaphore.wait(timeout: .now() + 0.05)
                if result == .success { break }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            exit(code)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
enum FetchOnce {
    static func run() async -> Int32 {
        let state = AppState()
        await state.refreshNow()
        switch state.usage {
        case .available(let window):
            let reset = window.resetsAt.map { "\($0)" } ?? "nil"
            print("AVAILABLE percent=\(window.remainingPercent) kind=\(window.kind.rawValue) reset=\(reset)")
            return 0
        case .unavailable(let reason):
            print("UNAVAILABLE reason=\(reason)")
            return 2
        case .stale:
            print("STALE")
            return 3
        case .loading:
            print("LOADING")
            return 4
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var statusItemController: StatusItemController?
    private var wakeObserver: NSObjectProtocol?
    private var mimoLaunchObserver: NSObjectProtocol?
    private var mimoTerminateObserver: NSObjectProtocol?

    /// Always-on status item so the user can open settings / quit even when MiMo is closed.
    private var idleController: StatusItemController?
    private var idleState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Idle shell: shows --% and waits for MiMo.
        startIdleShell()

        mimoLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Self.isMimo(application) else { return }
            Task { @MainActor in self?.startMeter() }
        }

        mimoTerminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Self.isMimo(application) else { return }
            Task { @MainActor in self?.stopMeter() }
        }

        if Self.isMimoRunning {
            startMeter()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tearDownObservers()
        state?.stop()
        idleState?.stop()
    }

    private nonisolated static let mimoBundleID = "com.xiaomi.mimo.desktop"

    private nonisolated static func isMimo(_ application: NSRunningApplication) -> Bool {
        application.bundleIdentifier == mimoBundleID
            || application.bundleURL?.lastPathComponent == "Xiaomi MiMo.app"
    }

    private nonisolated static var isMimoRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { isMimo($0) }
    }

    private func startIdleShell() {
        guard idleState == nil else { return }
        let idle = AppState(deps: AppState.Dependencies(
            bridge: LocalBridgeClient(
                http: URLSessionHTTPClient(),
                configLoader: { throw UsageError.bridgeUnavailable }
            ),
            credentials: FailCredentials(),
            sso: XiaomiSSOClient(http: FailingHTTP()),
            platform: PlatformUsageClient(http: FailingHTTP()),
            clock: { Date() }
        ))
        idleState = idle
        idleController = StatusItemController(state: idle, mode: .idle)
    }

    private func stopIdleShell() {
        idleState?.stop()
        idleState = nil
        idleController = nil
    }

    private func startMeter() {
        // Tear down idle shell so we don't double status items.
        stopIdleShell()
        guard state == nil else { return }

        let state = AppState()
        self.state = state
        statusItemController = StatusItemController(state: state, mode: .live)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak state] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                state?.refresh()
            }
        }

        state.start()
    }

    private func stopMeter() {
        guard state != nil else {
            // Already idle; ensure idle shell exists.
            startIdleShell()
            return
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        state?.stop()
        state = nil
        statusItemController = nil
        startIdleShell()
    }

    private func tearDownObservers() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let mimoLaunchObserver { NSWorkspace.shared.notificationCenter.removeObserver(mimoLaunchObserver) }
        if let mimoTerminateObserver { NSWorkspace.shared.notificationCenter.removeObserver(mimoTerminateObserver) }
        wakeObserver = nil
        mimoLaunchObserver = nil
        mimoTerminateObserver = nil
    }
}

private struct FailCredentials: CredentialReading {
    func loadAccountCredentials() throws -> AccountCredentials {
        throw UsageError.authExpired
    }
}

private struct FailingHTTP: HTTPPerforming {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw UsageError.bridgeUnavailable
    }
}

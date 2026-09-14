import AppKit
import Foundation
import ServiceManagement

enum LaunchAtLogin {
    enum Status: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case notAvailable(String)
    }

    static var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var currentStatus: Status {
        guard isBundledApp else {
            return .notAvailable("请使用 .app 包运行（不要用 swift run）后再设置开机启动")
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            // `.notFound` is common for freshly installed / ad-hoc signed apps
            // and must NOT disable the checkbox — register() can still succeed.
            return .disabled
        @unknown default:
            return .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard isBundledApp else {
            throw UsageError.network("请先通过 MImoMeter.app 启动，再设置登录项")
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Surface a clearer Chinese message; keep original for debugging.
            let ns = error as NSError
            throw UsageError.network(
                "系统拒绝注册登录项（\(ns.domain) \(ns.code)）。请确认应用位于「应用程序」或「用户应用程序」，并已在「系统设置 → 通用 → 登录项」允许。"
            )
        }
    }

    static var helpText: String {
        if isBundledApp {
            return "登录时由 macOS 启动 MImoMeter；MiMo 未运行时保持待命，MiMo 打开后自动开始读取额度，MiMo 退出后自动隐藏/退出。"
        }
        return "当前是命令行调试运行，无法注册登录项。请使用 Scripts/build-app.sh 生成的 MImoMeter.app。"
    }
}

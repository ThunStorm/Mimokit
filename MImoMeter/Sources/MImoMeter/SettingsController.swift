import AppKit
import ServiceManagement

@MainActor
final class SettingsController: NSObject {
    static let shared = SettingsController()
    private var window: NSWindow?

    private let apiBaseField = NSTextField(string: "")
    private let intervalField = NSTextField(string: "60")
    private let periodCheckbox = NSButton(checkboxWithTitle: "状态栏显示周期前缀（如 W 97%）", target: nil, action: nil)
    private let warningCheckbox = NSButton(checkboxWithTitle: "1–9% 颜色变成红色", target: nil, action: nil)
    private let underlineCheckbox = NSButton(checkboxWithTitle: "展示提示线", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "登录时启动，并跟随 MiMo", target: nil, action: nil)
    private let helpLabel = NSTextField(wrappingLabelWithString: "")

    func show() {
        if let window {
            loadValues()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        loadValues()
        apiBaseField.placeholderString = "https://mimo-server-cn.xiaomimimo.com/api（可选覆盖）"
        intervalField.placeholderString = "刷新间隔（秒，默认 60）"

        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLaunchAtLogin(_:))
        applyLoginState()

        helpLabel.stringValue = """
        \(LaunchAtLogin.helpText)

        主路径：只读本机 MiMo 账号分区 cookie，经官方 SSO 换取 serviceToken 后查询周额度。\
        本地桥 desktop-api 当前无用量路由，仅作探测。应用不修改 MiMo 配置，不外传凭证。
        """
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.preferredMaxLayoutWidth = 380

        let save = NSButton(title: "保存", target: self, action: #selector(save(_:)))

        let stack = NSStackView(views: [
            NSTextField(labelWithString: "平台 API Base（可选）"),
            apiBaseField,
            NSTextField(labelWithString: "刷新间隔（秒）"),
            intervalField,
            periodCheckbox,
            warningCheckbox,
            underlineCheckbox,
            loginCheckbox,
            helpLabel,
            save,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "MImoMeter 设置"
        window.contentView = stack
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyLoginState() {
        switch LaunchAtLogin.currentStatus {
        case .enabled:
            loginCheckbox.state = .on
            loginCheckbox.isEnabled = true
        case .disabled:
            loginCheckbox.state = .off
            loginCheckbox.isEnabled = true
        case .requiresApproval:
            loginCheckbox.state = .off
            loginCheckbox.isEnabled = true
            helpLabel.stringValue = "登录项已提交，需在「系统设置 → 通用 → 登录项」中允许 MImoMeter。"
        case .notAvailable(let message):
            // Only disable when truly not a .app bundle (e.g. swift run).
            loginCheckbox.state = .off
            loginCheckbox.isEnabled = false
            loginCheckbox.toolTip = message
            helpLabel.stringValue = message
        }
    }

    private func loadValues() {
        apiBaseField.stringValue = UserDefaults.standard.string(forKey: "mimoAPIBaseURL") ?? ""
        let interval = UserDefaults.standard.object(forKey: "refreshIntervalSeconds") as? Double ?? 60
        intervalField.stringValue = String(Int(interval))
        periodCheckbox.state = UserDefaults.standard.bool(forKey: "showQuotaPeriod") ? .on : .off
        warningCheckbox.state = UserDefaults.standard.bool(forKey: "showWarningColor") ? .on : .off
        underlineCheckbox.state = UserDefaults.standard.bool(forKey: "showPercentUnderline") ? .on : .off
        applyLoginState()
    }

    @objc private func save(_ sender: NSButton) {
        let apiBase = apiBaseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if apiBase.isEmpty {
            UserDefaults.standard.removeObject(forKey: "mimoAPIBaseURL")
        } else {
            UserDefaults.standard.set(apiBase, forKey: "mimoAPIBaseURL")
        }

        let interval = Double(intervalField.stringValue) ?? 60
        UserDefaults.standard.set(max(30, interval), forKey: "refreshIntervalSeconds")
        UserDefaults.standard.set(periodCheckbox.state == .on, forKey: "showQuotaPeriod")
        UserDefaults.standard.set(warningCheckbox.state == .on, forKey: "showWarningColor")
        UserDefaults.standard.set(underlineCheckbox.state == .on, forKey: "showPercentUnderline")
        window?.close()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        do {
            try LaunchAtLogin.setEnabled(sender.state == .on)
            applyLoginState()
            if case .requiresApproval = LaunchAtLogin.currentStatus {
                let alert = NSAlert()
                alert.messageText = "需要系统授权"
                alert.informativeText = "请打开「系统设置 → 通用 → 登录项」，允许 MImoMeter 在后台运行。"
                alert.runModal()
            }
        } catch {
            applyLoginState()
            let alert = NSAlert()
            alert.messageText = "无法设置开机启动"
            alert.informativeText = (error as? UsageError)?.userMessage
                ?? error.localizedDescription
            alert.runModal()
        }
    }
}

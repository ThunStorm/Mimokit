import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    enum Mode {
        case live
        case idle
    }

    private let state: AppState
    private let mode: Mode
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let contentView = StatusItemView()
    private let menu = NSMenu()

    init(state: AppState, mode: Mode = .live) {
        self.state = state
        self.mode = mode
        super.init()
        guard let button = statusItem.button else { return }
        button.title = ""
        button.target = self
        button.action = #selector(showMenu)
        button.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: button.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        button.setAccessibilityRole(.button)
        menu.delegate = self
        statusItem.menu = menu
        state.onChange = { [weak self] in
            Task { @MainActor in
                self?.updateView()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        updateView()
    }

    @objc private func userDefaultsChanged() {
        updateView()
    }

    @objc private func showMenu() {
        rebuildMenu()
        statusItem.button?.performClick(nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func updateView() {
        let display = state.display
        contentView.update(
            percentage: display.percentageText,
            color: statusColor(for: display.remainingPercent),
            accessibilityLabel: display.accessibilityLabel,
            showsUnderline: UserDefaults.standard.bool(forKey: "showPercentUnderline")
        )
        statusItem.button?.toolTip = display.tooltip
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        add("MiMo 额度", enabled: false)
        menu.addItem(.separator())

        if mode == .idle {
            add("等待 MiMo 启动…", enabled: false)
            add("MiMo 打开后会自动显示周额度", enabled: false)
        } else if state.menuWindows.isEmpty {
            let reason = {
                if case .unavailable(let text) = state.usage { return text }
                if case .stale = state.usage { return "数据已过期" }
                return "暂不可用"
            }()
            add("额度：\(reason)", enabled: false)
        }

        for window in state.menuWindows {
            add("\(label(for: window.kind))：剩余 \(window.remainingPercent)%", enabled: false)
            add("重置：\(formatReset(window.resetsAt))", enabled: false)
        }

        if mode == .live {
            add("更新：\(formatUpdated(state.lastUpdatedAt))", enabled: false)
        }
        menu.addItem(.separator())
        addAction("打开 MiMo", #selector(openMimo))
        if mode == .live {
            addAction("刷新", #selector(refresh))
        }
        menu.addItem(.separator())
        addAction("设置…", #selector(openSettings))
        addAction("退出 MImoMeter", #selector(quit))
    }

    private func label(for kind: UsageWindowKind) -> String {
        switch kind {
        case .weekly: return "每周"
        case .fiveHour: return "5 小时"
        case .monthly: return "每月"
        case .unknown: return "额度"
        }
    }

    private func add(_ title: String, enabled: Bool) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func addAction(_ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func refresh() {
        state.refresh()
    }

    @objc private func openMimo() {
        let workspace = NSWorkspace.shared
        let url = ProcessLocator.mimoApplicationURL() ?? URL(fileURLWithPath: ProcessLocator.fallbackAppPath)
        workspace.openApplication(at: url, configuration: .init()) { _, _ in }
    }

    @objc private func openSettings() {
        SettingsController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func statusColor(for remaining: Int?) -> NSColor {
        guard let remaining else { return .labelColor }
        if remaining <= 0 { return .systemRed }
        if state.showWarningColor, remaining < 10 { return .systemRed }
        return .labelColor
    }

    private func formatReset(_ date: Date?) -> String {
        guard let date else { return "未知" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    private func formatUpdated(_ date: Date?) -> String {
        guard let date else { return "尚未更新" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

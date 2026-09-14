import Foundation

enum UsageSelector {
    static func kind(for durationMinutes: Int) -> UsageWindowKind {
        switch durationMinutes {
        case 240...360: return .fiveHour
        case 9_000...11_000: return .weekly
        case 38_000...50_000: return .monthly
        default: return .unknown
        }
    }

    static func kind(fromHint hint: String?) -> UsageWindowKind? {
        guard let hint else { return nil }
        switch hint.lowercased() {
        case "five_hour", "5h", "fivehour", "five-hour":
            return .fiveHour
        case "weekly", "week":
            return .weekly
        case "monthly", "month":
            return .monthly
        default:
            return nil
        }
    }

    /// Clamp remaining percent into 0...100 and round to integer.
    static func remainingPercent(from remaining: Double) -> Int? {
        guard remaining.isFinite, remaining >= 0 else { return nil }
        return Int(min(100, remaining).rounded())
    }

    static func remainingPercent(usedPercent: Double) -> Int? {
        guard usedPercent.isFinite, usedPercent >= 0 else { return nil }
        return remainingPercent(from: 100 - usedPercent)
    }

    /// Status-bar primary number: weekly first; only real server windows.
    static func selectDisplayedWindow(_ windows: [UsageWindow]) -> UsageWindow? {
        windows.first { $0.kind == .weekly }
            ?? windows.first { $0.kind == .fiveHour }
            ?? windows.first { $0.kind == .monthly }
            ?? windows.first { $0.kind == .unknown }
    }

    /// Menu order: fiveHour → weekly → monthly → unknown; one window per kind.
    static func selectMenuWindows(_ windows: [UsageWindow]) -> [UsageWindow] {
        let order: [UsageWindowKind] = [.fiveHour, .weekly, .monthly, .unknown]
        return order.compactMap { kind in
            windows.first { $0.kind == kind }
        }
    }
}

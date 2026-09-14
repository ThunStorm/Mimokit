import Foundation

enum Normalizer {
    /// Normalize a channel-agnostic payload into concrete display windows.
    static func windows(from payload: RawUsagePayload, receivedAt: Date = .now) -> [UsageWindow] {
        var results: [UsageWindow] = []

        if !payload.windows.isEmpty {
            for (index, raw) in payload.windows.enumerated() {
                if let window = makeWindow(from: raw, fallbackIndex: index, receivedAt: receivedAt) {
                    results.append(window)
                }
            }
            return results
        }

        // Top-level single object (current MiMo platform shape) → forced weekly.
        if let remaining = payload.remainingPercent ?? payload.usedPercent.map({ 100 - $0 }),
           let clamped = UsageSelector.remainingPercent(from: remaining) {
            let resetsAt = resolveReset(payload.resetAtUnix, payload.resetDate)
            results.append(
                UsageWindow(
                    id: "weekly",
                    kind: .weekly,
                    remainingPercent: clamped,
                    usedPercent: Double(100 - clamped),
                    durationMinutes: 10_080,
                    resetsAt: resetsAt,
                    receivedAt: receivedAt
                )
            )
        }

        return results
    }

    private static func makeWindow(from raw: RawWindow, fallbackIndex: Int, receivedAt: Date) -> UsageWindow? {
        let remainingSource: Double
        if let remaining = raw.remainingPercent, remaining.isFinite, remaining >= 0 {
            remainingSource = remaining
        } else if let used = raw.usedPercent, used.isFinite, used >= 0 {
            remainingSource = 100 - used
        } else {
            return nil
        }

        guard let remainingPercent = UsageSelector.remainingPercent(from: remainingSource) else {
            return nil
        }

        let kind = UsageSelector.kind(fromHint: raw.kindHint)
            ?? raw.windowDurationMins.map(UsageSelector.kind(for:))
            ?? .unknown

        return UsageWindow(
            id: raw.id ?? "window-\(fallbackIndex)",
            kind: kind,
            remainingPercent: remainingPercent,
            usedPercent: raw.usedPercent ?? Double(100 - remainingPercent),
            durationMinutes: raw.windowDurationMins,
            resetsAt: raw.resetsAt,
            receivedAt: receivedAt
        )
    }

    private static func resolveReset(_ unix: Int?, _ dateString: String?) -> Date? {
        if let unix, unix > 0 {
            return Date(timeIntervalSince1970: TimeInterval(unix))
        }
        if let dateString {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
            return formatter.date(from: dateString)
        }
        return nil
    }
}

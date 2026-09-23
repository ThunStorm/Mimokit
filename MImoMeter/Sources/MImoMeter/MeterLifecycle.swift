import Foundation

/// Pure lifecycle decisions for MiMo ↔ MImoMeter pairing.
/// Update flows often launch the replacement process before the old one
/// posts terminate, so "terminated" must not blindly tear the meter down.
enum MeterLifecycleAction: Sendable, Equatable {
    case none
    case start
    case refresh
    case stop
}

enum MeterLifecycle {
    /// After a MiMo launch notification.
    static func afterLaunch(meterActive: Bool) -> MeterLifecycleAction {
        meterActive ? .refresh : .start
    }

    /// After a MiMo terminate notification (call after a short settle delay).
    static func afterTerminate(mimoStillRunning: Bool, meterActive: Bool) -> MeterLifecycleAction {
        if mimoStillRunning {
            return meterActive ? .refresh : .start
        }
        return .stop
    }

    /// Periodic / manual reconciliation against the real process table.
    static func reconcile(mimoRunning: Bool, meterActive: Bool) -> MeterLifecycleAction {
        switch (mimoRunning, meterActive) {
        case (true, false):
            return .start
        case (false, true):
            return .stop
        case (true, true), (false, false):
            return .none
        }
    }
}

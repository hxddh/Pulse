import Foundation

/// How hard Pulse should be looking right now.
///
/// A status lamp that forks a Python harvest every 3 seconds regardless of
/// context gets flagged by macOS as an energy hog — which is fatal for a
/// permanently-resident menu bar tool. The cadence therefore follows what is
/// actually happening: loud when something needs you, near-silent when nothing
/// is running, and fully parked when the screen is off.
enum ProbeSchedule {
    /// What the last scan found — drives the base interval.
    enum Activity: Equatable {
        /// At least one agent needs the user.
        case waiting
        /// Something is live, nothing is waiting.
        case running
        /// Only recent (harvest-only) rows.
        case recent
        /// Nothing at all.
        case empty
    }

    /// Machine context that can only ever slow us down, never speed us up.
    struct Power: Equatable {
        var displayAsleep = false
        var screenLocked = false
        var lowPowerMode = false

        /// No point probing what nobody can see.
        var parked: Bool { displayAsleep || screenLocked }

        static var current: Power {
            Power(
                displayAsleep: false,
                screenLocked: false,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }
    }

    /// Seconds between probes. `nil` means "stop the timer entirely" — the
    /// attention-file watcher still wakes us if an agent starts waiting.
    static func interval(
        activity: Activity,
        power: Power,
        trayOpen: Bool
    ) -> TimeInterval? {
        if power.parked, !trayOpen { return nil }

        var base: TimeInterval
        switch activity {
        case .waiting: base = 2.0
        case .running: base = 5.0
        case .recent: base = 15.0
        case .empty: base = 30.0
        }

        // An open tray is a user actively reading the panel — worth the cost.
        if trayOpen { base = min(base, 2.0) }
        if power.lowPowerMode { base *= 2 }
        return base
    }

    /// Harvest (a Python fork walking dozens of directories) is far more
    /// expensive than probe (`ps`), so it does not have to run every tick.
    /// Returns how many probe ticks may pass between harvests.
    static func harvestEveryNTicks(activity: Activity, trayOpen: Bool) -> Int {
        if trayOpen { return 1 }
        switch activity {
        case .waiting: return 1
        case .running: return 2
        case .recent: return 2
        case .empty: return 1
        }
    }
}

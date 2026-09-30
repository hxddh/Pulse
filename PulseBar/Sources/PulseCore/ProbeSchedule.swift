import CoreGraphics
import Foundation

/// How often Pulse looks, now that events drive it (24.0).
///
/// Nothing here polls a vendor. The event log (`events.tsv`) wakes Pulse
/// when a hook appends to it (a file-system watch), and a process exit
/// wakes it through kqueue. Two timers remain, both cheap:
///
/// - the **tick** re-projects the in-memory session book so facts that move
///   with the clock alone move on screen — a wait's age, the stall rule, the
///   idle bound, the recent window. No IO. It stops when nothing is on
///   screen or the display is asleep;
/// - the **process scan** (libproc) finds agent processes that have no
///   session yet — sessions started before Pulse was running — at launch
///   and wake, when a hook names a pid no scan found, and on a timer that
///   starts at 30 s and doubles while scans find the same processes, up to
///   5 min.
///
/// A resident menu-bar app flagged for energy use is a dead product.
public enum ProbeSchedule {
    /// What the last projection found — drives the tick.
    public enum Activity: Equatable, Sendable {
        /// At least one session needs the user.
        case waiting
        /// Something is running, nothing is waiting.
        case running
        /// Only quiet rows (your turn, recent, process only).
        case recent
        /// Nothing at all.
        case empty
    }

    /// Machine context that can only ever slow us down, never speed us up.
    public struct Power: Equatable {
        public var displayAsleep = false
        public var screenLocked = false
        public var lowPowerMode = false

        public init(displayAsleep: Bool = false, screenLocked: Bool = false, lowPowerMode: Bool = false) {
            self.displayAsleep = displayAsleep
            self.screenLocked = screenLocked
            self.lowPowerMode = lowPowerMode
        }

        /// No point probing what nobody can see.
        public var parked: Bool { displayAsleep || screenLocked }

        /// The machine as it actually is right now.
        ///
        /// This used to answer "awake and unlocked" unconditionally, and
        /// `PowerMonitor` seeds itself from it — so Pulse relaunched while the
        /// screen was locked or the displays were asleep never parked. The
        /// notification that would have told it is the one that already fired,
        /// and the next one to arrive says *unlocked*, which is exactly when
        /// polling should resume. Crash recovery and update replacement are
        /// the two relaunches nobody is watching, and they are the ones that
        /// would poll at full cadence all night.
        ///
        /// Both queries fail closed to the old assumption: a headless runner,
        /// a session dictionary without the key, or an unavailable display all
        /// mean "carry on as before" rather than a park nobody asked for.
        public static var current: Power {
            Power(
                displayAsleep: displaysAreAsleep,
                screenLocked: screenIsLocked,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }

        private static var displaysAreAsleep: Bool {
            CGDisplayIsAsleep(CGMainDisplayID()) != 0
        }

        private static var screenIsLocked: Bool {
            guard let raw = CGSessionCopyCurrentDictionary() else { return false }
            let session = raw as NSDictionary
            return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
        }
    }

    /// Seconds between ticks; `nil` stops the tick (the watchers and the
    /// exit sources still wake Pulse when something happens).
    ///
    /// A minute is enough for minute labels and every time rule; a wait
    /// younger than a minute is drawn in seconds, and an open tray is a
    /// person reading, so both tick every five seconds.
    public static func tick(
        activity: Activity,
        power: Power,
        trayOpen: Bool,
        freshWait: Bool = false
    ) -> TimeInterval? {
        if power.parked, !trayOpen { return nil }
        var base: TimeInterval
        if trayOpen || freshWait {
            base = 5
        } else if activity == .empty {
            return nil
        } else {
            base = 60
        }
        if power.lowPowerMode { base *= 2 }
        return base
    }

    /// Seconds between process scans; `nil` while the display sleeps or the
    /// screen is locked (a scan runs again on wake).
    public static let processScanSeconds: TimeInterval = 30
    /// The slowest the process scan backs off to.
    public static let processScanMaxSeconds: TimeInterval = 300

    /// `quietScans`: scans in a row that found the same processes — each
    /// doubles the period, up to `processScanMaxSeconds` (low power doubles
    /// the result, within the same cap).
    public static func processScan(power: Power, quietScans: Int = 0) -> TimeInterval? {
        if power.parked { return nil }
        let steps = min(max(quietScans, 0), 4)
        var seconds = processScanSeconds * Double(1 << steps)
        if power.lowPowerMode { seconds *= 2 }
        return min(seconds, processScanMaxSeconds)
    }

    /// The backoff after a scan: one more quiet scan when it found the same
    /// processes as the last one, none when anything changed.
    public static func nextQuietScans(_ current: Int, same: Bool) -> Int {
        same ? min(current + 1, 8) : 0
    }
}

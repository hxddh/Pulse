import Foundation

/// Rolling one-hour record of how hard Pulse actually worked.
///
/// 0.22 claimed the energy rework cut expensive harvests from ~28,800/day to
/// ~2,880/day. That number was arithmetic, not measurement — nobody could check
/// it, including the person who wrote it into a public release note. These
/// counters put the answer in the diagnostics text, so anyone can paste back
/// what their machine really did.
public struct ProbeStats: Equatable {
    public struct Sample: Equatable {
        public var at: Date
        /// Whether this tick paid for the activity harvest, or only ran `ps`.
        public var harvested: Bool
        public var harvestMs: Int?

        public init(at: Date, harvested: Bool, harvestMs: Int?) {
            self.at = at
            self.harvested = harvested
            self.harvestMs = harvestMs
        }
    }

    public init() {}

    public static let window: TimeInterval = 3600

    public private(set) var samples: [Sample] = []
    /// Seconds the timer spent parked (display asleep / screen locked).
    public private(set) var parkedSeconds: TimeInterval = 0

    public mutating func record(_ sample: Sample) {
        samples.append(sample)
        prune(now: sample.at)
    }

    public mutating func addParked(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        parkedSeconds += seconds
    }

    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.window)
        if let first = samples.first, first.at >= cutoff { return }
        samples.removeAll { $0.at < cutoff }
    }

    private func recent(_ now: Date) -> [Sample] {
        let cutoff = now.addingTimeInterval(-Self.window)
        return samples.filter { $0.at >= cutoff }
    }

    public func probeCount(now: Date) -> Int { recent(now).count }

    public func harvestCount(now: Date) -> Int { recent(now).filter(\.harvested).count }

    public func averageHarvestMs(now: Date) -> Int? {
        let durations = recent(now).compactMap(\.harvestMs)
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +) / durations.count
    }

    /// Harvests extrapolated to a day at the observed rate — directly comparable
    /// to the number in the 0.22 release notes.
    ///
    /// Only meaningful once there is enough of a window to extrapolate from;
    /// returns nil rather than multiplying up a handful of samples.
    public func projectedDailyHarvests(now: Date, minimumSpan: TimeInterval = 300) -> Int? {
        let window = recent(now)
        guard let first = window.first, window.count >= 2 else { return nil }
        let span = now.timeIntervalSince(first.at)
        guard span >= minimumSpan else { return nil }
        let perSecond = Double(window.filter(\.harvested).count) / span
        return Int((perSecond * 86_400).rounded())
    }

    /// One diagnostics line: `1h: 240 probes · 82 harvests (~2900/day) · avg 310ms · parked 12m`
    public func summary(now: Date) -> String {
        let probes = probeCount(now: now)
        guard probes > 0 else { return "1h: no scans yet" }

        var bits = ["\(probes) probes"]
        var harvestBit = "\(harvestCount(now: now)) harvests"
        if let daily = projectedDailyHarvests(now: now) {
            harvestBit += " (~\(daily)/day)"
        }
        bits.append(harvestBit)
        if let avg = averageHarvestMs(now: now) { bits.append("avg \(avg)ms") }
        if parkedSeconds >= 60 { bits.append("parked \(Int(parkedSeconds / 60))m") }
        return "1h: " + bits.joined(separator: " · ")
    }
}

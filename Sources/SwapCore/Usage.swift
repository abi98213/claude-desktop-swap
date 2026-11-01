import Foundation

/// Plan usage as Claude itself records it. While Claude runs it samples the
/// signed-in account about every 10 minutes into plan-usage-history.json:
/// {"samples": [{"t": ms, "org": uuid, "u": {"fh": 5-hour %, "sd": 7-day %}}]}.
/// The file only says which org a sample is for, so each new sample is
/// credited to whichever account is signed in when we see it. No tokens are
/// read and nothing is sent anywhere.
public struct Usage: Codable, Equatable {
    public var at: Date
    public var org: String
    public var fiveHour: Double?
    public var sevenDay: Double?

    static let fiveHours: TimeInterval = 5 * 3600
    static let sevenDays: TimeInterval = 7 * 86400

    /// Usage now, assuming a window has reset once it is older than itself.
    public func current(now: Date = Date()) -> (fiveHour: Double?, sevenDay: Double?) {
        let age = now.timeIntervalSince(at)
        return (age < Usage.fiveHours ? fiveHour : 0, age < Usage.sevenDays ? sevenDay : 0)
    }

    /// The higher of the two limits, as a percent (nil if unknown).
    public func peak(now: Date = Date()) -> Double? {
        let c = current(now: now)
        let values = [c.fiveHour, c.sevenDay].compactMap { $0 }
        return values.max()
    }

    /// When the binding limit is expected to clear (nil if not limited).
    public func resetsAt(threshold: Double) -> Date? {
        if let s = sevenDay, s >= threshold { return at.addingTimeInterval(Usage.sevenDays) }
        if let f = fiveHour, f >= threshold { return at.addingTimeInterval(Usage.fiveHours) }
        return nil
    }
}

public enum UsageTracker {
    struct State: Codable {
        var lastSeen: Double = 0
        var accounts: [String: Usage] = [:]
        var lastAutoSwitch: Date?
    }

    static var stateURL: URL { Paths.inStore("usage.json") }
    static var historyURL: URL { Paths.claude("plan-usage-history.json") }

    static func load() -> State { JSONFile.read(State.self, stateURL) ?? State() }
    static func save(_ s: State) { try? JSONFile.write(encodable: s, to: stateURL) }

    /// Credit unseen samples to the signed-in account. Call it often while
    /// Claude runs, and always right before a switch.
    @discardableResult
    public static func refresh() -> [String: Usage] {
        var state = load()
        guard let account = Slice.currentAccount,
              let samples = (JSONFile.read(historyURL) as? [String: Any])?["samples"] as? [[String: Any]]
        else { return state.accounts }
        let parsed: [(t: Double, org: String, u: [String: Any])] = samples.compactMap {
            guard let t = $0["t"] as? Double, let org = $0["org"] as? String,
                  let u = $0["u"] as? [String: Any] else { return nil }
            return (t, org, u)
        }.sorted { $0.t < $1.t }
        // First run: older samples can't be credited to an account safely,
        // so take only the newest one for whoever is signed in now.
        let fresh = state.lastSeen == 0 ? Array(parsed.suffix(1)) : parsed.filter { $0.t > state.lastSeen }
        for s in fresh {
            state.accounts[account] = Usage(
                at: Date(timeIntervalSince1970: s.t / 1000), org: s.org,
                fiveHour: s.u["fh"] as? Double, sevenDay: s.u["sd"] as? Double)
        }
        if let last = parsed.last { state.lastSeen = max(state.lastSeen, last.t) }
        save(state)
        return state.accounts
    }

    public static func usage(for account: String) -> Usage? { load().accounts[account] }

    /// Test hook and manual override: set an account's usage.
    public static func record(_ usage: Usage, for account: String) {
        var state = load()
        state.accounts[account] = usage
        save(state)
    }

    static func noteAutoSwitch() {
        var state = load()
        state.lastAutoSwitch = Date()
        save(state)
    }

    static var lastAutoSwitch: Date? { load().lastAutoSwitch }
}

/// Decides whether to move off the signed-in account.
public enum AutoSwitch {
    public enum Decision: Equatable {
        case stay(String)
        case switchTo(Profile, reason: String)
        case allLimited(nextReset: Date?)
    }

    /// Samples older than this don't count as "at the limit now".
    static let freshness: TimeInterval = 20 * 60
    static let cooldown: TimeInterval = 10 * 60

    public static func decide(settings: Settings = .load(), now: Date = Date()) -> Decision {
        let profiles = Profiles.all()
        guard let active = Profiles.active else { return .stay("the signed-in account isn't saved") }
        guard profiles.count > 1 else { return .stay("only one account is saved") }
        if let last = UsageTracker.lastAutoSwitch, now.timeIntervalSince(last) < cooldown {
            return .stay("switched less than 10 minutes ago")
        }
        guard let usage = UsageTracker.usage(for: active.account),
              now.timeIntervalSince(usage.at) < freshness,
              let peak = usage.peak(now: now) else {
            return .stay("no recent usage reading for \(active.label)")
        }
        guard peak >= settings.threshold else {
            return .stay("\(active.label) is at \(Int(peak))%")
        }
        // Next account in order whose last reading is under the threshold.
        let i = profiles.firstIndex(of: active) ?? 0
        let rotated = profiles[(i + 1)...] + profiles[..<i]
        for candidate in rotated {
            let p = UsageTracker.usage(for: candidate.account)?.peak(now: now) ?? 0
            if p < settings.threshold {
                return .switchTo(candidate, reason: "\(active.label) reached \(Int(peak))%")
            }
        }
        let resets = profiles.compactMap { UsageTracker.usage(for: $0.account)?.resetsAt(threshold: settings.threshold) }
        return .allLimited(nextReset: resets.min())
    }
}

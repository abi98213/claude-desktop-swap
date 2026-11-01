import Foundation

public struct Settings: Codable, Equatable {
    /// Give every account the same Code sessions (see Sharing).
    public var share = true
    public var shareCowork = false
    /// Switch to the next account when the active one reaches the threshold.
    public var autoSwitch = false
    /// Percent of the 5-hour or 7-day limit that triggers an auto-switch.
    public var threshold = 95.0
    /// Seconds the "switching soon" panel waits before switching.
    public var countdown = 60
    /// Shell command run after each switch while Claude is closed.
    public var afterSwitch: String?
    /// The one real folder per session root that the others link to.
    public var sharedDirs: [String: String] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerate missing keys so older settings files keep loading.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        share = try c.decodeIfPresent(Bool.self, forKey: .share) ?? d.share
        shareCowork = try c.decodeIfPresent(Bool.self, forKey: .shareCowork) ?? d.shareCowork
        autoSwitch = try c.decodeIfPresent(Bool.self, forKey: .autoSwitch) ?? d.autoSwitch
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? d.threshold
        countdown = try c.decodeIfPresent(Int.self, forKey: .countdown) ?? d.countdown
        afterSwitch = try c.decodeIfPresent(String.self, forKey: .afterSwitch)
        sharedDirs = try c.decodeIfPresent([String: String].self, forKey: .sharedDirs) ?? [:]
    }

    static var url: URL { Paths.inStore("settings.json") }

    public static func load() -> Settings { JSONFile.read(Settings.self, url) ?? Settings() }

    public func save() throws { try JSONFile.write(encodable: self, to: Settings.url) }
}

public struct Profile: Codable, Equatable, Identifiable {
    public var name: String
    public var account: String
    public var email: String?
    public var addedAt: Date
    public var savedAt: Date
    public var id: String { name }

    public var label: String { email ?? name }
}

/// Saved accounts: profiles/<name>/{meta.json, config-auth.json, slice/}.
public enum Profiles {
    static let namePattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._@+-]{1,64}$")

    static var root: URL { Paths.inStore("profiles") }

    static func folder(_ name: String) -> URL { root.appendingPathComponent(name) }

    public static func all() -> [Profile] {
        FS.list(root).compactMap { JSONFile.read(Profile.self, folder($0).appendingPathComponent("meta.json")) }
    }

    public static func named(_ name: String) -> Profile? { all().first { $0.name == name } }

    public static func forAccount(_ account: String?) -> Profile? {
        guard let account = account else { return nil }
        return all().first { $0.account == account }
    }

    public static var active: Profile? { forAccount(Slice.currentAccount) }

    public static func validate(_ name: String) throws -> String {
        let range = NSRange(location: 0, length: (name as NSString).length)
        guard namePattern.firstMatch(in: name, range: range) != nil else {
            throw SwapError("Names may use letters, digits and . _ @ + - (max 64).")
        }
        return name
    }

    /// A free name for an account: its email, or account-<id>.
    static func suggestedName(account: String, email: String?) -> String {
        if let email = email, (try? validate(email)) != nil, !FS.exists(folder(email)) { return email }
        return "account-" + account.prefix(8)
    }

    /// Store the signed-in account's slice under name (creating or
    /// refreshing the profile). live=true when Claude may be running.
    @discardableResult
    public static func save(as name: String? = nil, live: Bool) throws -> Profile {
        guard let account = Slice.currentAccount else {
            throw SwapError("Claude is not signed in, so there is nothing to save.")
        }
        var existing = forAccount(account)
        let email = existing?.email ?? Slice.detectEmail(account: account)
        let target = try name.map(validate) ?? existing?.name ?? suggestedName(account: account, email: email)
        if let other = named(target), other.account != account {
            throw SwapError("'\(target)' belongs to another account.")
        }
        if let old = existing, old.name != target {
            try FS.move(folder(old.name), to: folder(target))
            existing?.name = target
        }
        try Slice.save(to: folder(target), live: live)
        let now = Date()
        let profile = Profile(name: target, account: account, email: email,
                              addedAt: existing?.addedAt ?? now, savedAt: now)
        try JSONFile.write(encodable: profile, to: folder(target).appendingPathComponent("meta.json"))
        return profile
    }

    public static func rename(_ old: String, to new: String) throws {
        guard var profile = named(old) else { throw SwapError("No account named '\(old)'.") }
        _ = try validate(new)
        guard !FS.exists(folder(new)) else { throw SwapError("'\(new)' already exists.") }
        try FS.move(folder(old), to: folder(new))
        profile.name = new
        try JSONFile.write(encodable: profile, to: folder(new).appendingPathComponent("meta.json"))
    }

    public static func remove(_ name: String) throws {
        guard named(name) != nil else { throw SwapError("No account named '\(name)'.") }
        try FS.remove(folder(name))
    }
}

/// Copies of the slice taken before every switch, newest last.
public enum Backups {
    static let keep = 10
    static var root: URL { Paths.inStore("backups") }

    @discardableResult
    static func take(reason: String) throws -> URL {
        let dest = root.appendingPathComponent("\(stamp())-\(reason)")
        try Slice.save(to: dest, live: ClaudeApp.isRunning)
        try JSONFile.write(["reason": reason, "account": Slice.currentAccount ?? ""],
                           to: dest.appendingPathComponent("meta.json"))
        for old in FS.list(root).dropLast(keep) {
            try FS.remove(root.appendingPathComponent(old))
        }
        return dest
    }

    public static var latest: URL? {
        FS.list(root).last.map { root.appendingPathComponent($0) }
    }
}

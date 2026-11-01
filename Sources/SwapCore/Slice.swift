import Foundation
import SQLite3

/// The account-specific part of Claude's data folder: the claude.ai cookies,
/// web storage, and three keys in config.json. Everything else in the folder
/// (settings, MCP servers, sessions, VM images) is shared by all accounts.
public enum Slice {
    static let files = ["Cookies", "Cookies-journal", "cowork-enabled-cli-ops.json"]
    static let dirs = ["Local Storage", "IndexedDB", "Session Storage", "WebStorage"]
    static let configKeys = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"]

    static var configURL: URL { Paths.claude("config.json") }

    /// The account Claude signed in last, or nil when signed out.
    public static var currentAccount: String? {
        JSONFile.readObject(configURL)["lastKnownAccountUuid"] as? String
    }

    /// Copy the slice into dest/. With live=true Claude may be running, so
    /// the Cookies database goes through SQLite's online backup and folders
    /// that change mid-copy are retried.
    static func save(to dest: URL, live: Bool) throws {
        for name in files + dirs {
            let src = Paths.claude(name)
            let dst = dest.appendingPathComponent("slice").appendingPathComponent(name)
            guard FS.exists(src) else { try FS.remove(dst); continue }
            if live && name == "Cookies" {
                try sqliteBackup(src, to: dst)
            } else if live && FS.isDir(src) {
                try copyRetrying(src, to: dst)
            } else {
                try FS.copy(src, to: dst)
            }
        }
        let config = JSONFile.readObject(configURL)
        try JSONFile.write(config.filter { configKeys.contains($0.key) },
                           to: dest.appendingPathComponent("config-auth.json"))
    }

    /// Replace Claude's slice with the one saved in src/. nil clears it,
    /// which leaves Claude signed out. Claude must not be running.
    static func restore(from src: URL?) throws {
        for name in files + dirs {
            let target = Paths.claude(name)
            try FS.remove(target)
            if let saved = src?.appendingPathComponent("slice").appendingPathComponent(name),
               FS.exists(saved) {
                try FS.copy(saved, to: target)
            }
        }
        var config = JSONFile.readObject(configURL)
        let saved = src.map { JSONFile.readObject($0.appendingPathComponent("config-auth.json")) } ?? [:]
        for key in configKeys {
            config[key] = saved[key]
        }
        try JSONFile.write(config, to: configURL)
    }

    static func copyRetrying(_ src: URL, to dst: URL) throws {
        for attempt in 1...3 {
            do { return try FS.copy(src, to: dst) } catch {
                // A live LevelDB compacts files away mid-copy; try again.
                if attempt == 3 { throw error }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }

    static func sqliteBackup(_ src: URL, to dst: URL) throws {
        try FS.remove(dst)
        try FS.mkdir(dst.deletingLastPathComponent())
        var source: OpaquePointer?, target: OpaquePointer?
        defer { sqlite3_close(source); sqlite3_close(target) }
        guard sqlite3_open_v2(src.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open(dst.path, &target) == SQLITE_OK,
              let backup = sqlite3_backup_init(target, "main", source, "main") else {
            throw SwapError("Could not read Claude's cookie database.")
        }
        let step = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE else { throw SwapError("Cookie backup failed (\(step)).") }
    }

    /// Best effort: the signed-in email, read from claude.ai's local
    /// IndexedDB (it stores the account record next to the account id).
    public static func detectEmail(account: String? = currentAccount) -> String? {
        guard let account = account else { return nil }
        let root = Paths.claude("IndexedDB")
        guard let walker = FS.fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        let emailPattern = try! NSRegularExpression(
            pattern: "email_address\"?.{0,4}?([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,})")
        let idBytes = Data(account.utf8)
        for case let url as URL in walker {
            guard let data = try? Data(contentsOf: url), data.count < 50_000_000 else { continue }
            var searchFrom = data.startIndex
            while let hit = data.range(of: idBytes, in: searchFrom..<data.endIndex) {
                let end = min(hit.upperBound + 400, data.endIndex)
                let window = String(decoding: data[hit.upperBound..<end], as: UTF8.self)
                let ns = window as NSString
                if let m = emailPattern.firstMatch(in: window, range: NSRange(location: 0, length: ns.length)) {
                    return ns.substring(with: m.range(at: 1))
                }
                searchFrom = hit.upperBound
            }
        }
        return nil
    }
}

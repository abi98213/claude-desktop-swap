import Foundation

/// Claude files Code sessions under claude-code-sessions/<account>/<org>/,
/// so a different account shows an empty sidebar. Sharing keeps one real
/// folder per root and turns every other <account>/<org> folder into a
/// symlink to it, after moving its files over.
public enum Sharing {
    public struct Report {
        public var linked = 0, moved = 0, same = 0, merged = 0, conflicts = 0
        public var summary: String {
            "linked \(linked) folders · moved \(moved) files · \(same) duplicates · \(merged) merged · \(conflicts) conflicts"
        }
    }

    static let uuid = try! NSRegularExpression(
        pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

    static func isUUID(_ s: String) -> Bool {
        uuid.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    static func roots(_ settings: Settings) -> [String] {
        settings.shareCowork ? ["claude-code-sessions", "local-agent-mode-sessions"] : ["claude-code-sessions"]
    }

    /// Orgs each account has signed into, from the session folder names.
    public static func orgs(of account: String) -> [String] {
        FS.list(Paths.claude("claude-code-sessions", account)).filter(isUUID)
    }

    @discardableResult
    public static func run(dryRun: Bool = false, log: (String) -> Void) throws -> Report {
        var settings = Settings.load()
        var report = Report()
        let conflictsRoot = Paths.inStore("share-conflicts", stamp())
        for rootName in roots(settings) {
            let root = Paths.claude(rootName)
            let accounts = FS.list(root).filter { isUUID($0) && FS.isDir(root.appendingPathComponent($0)) }
            let orgs = Set(accounts.flatMap { FS.list(root.appendingPathComponent($0)).filter(isUUID) })
            guard !accounts.isEmpty, !orgs.isEmpty else { continue }
            let slots = accounts.flatMap { a in orgs.map { root.appendingPathComponent(a).appendingPathComponent($0) } }
            let real = slots.filter { FS.isDir($0) && !FS.isLink($0) }

            var canon = settings.sharedDirs[rootName].map { URL(fileURLWithPath: $0) }
            if canon == nil || !FS.isDir(canon!) || FS.isLink(canon!) {
                guard let busiest = real.max(by: { FS.list($0).count < FS.list($1).count }) else { continue }
                canon = busiest
            }
            let shared = canon!.standardizedFileURL
            let sharedReal = FS.real(shared)
            settings.sharedDirs[rootName] = shared.path

            for slot in slots where FS.isLink(slot) || FS.real(slot) != sharedReal {
                let conflicts = conflictsRoot.appendingPathComponent(rootName)
                    .appendingPathComponent(slot.deletingLastPathComponent().lastPathComponent)
                    .appendingPathComponent(slot.lastPathComponent)
                if FS.isLink(slot) {
                    let target = FS.real(slot)
                    if target == sharedReal { continue }
                    // A link to some other folder: copy that folder's files in
                    // (unless it's a slot we visit anyway). Never move or
                    // delete through a link: the folder may be anything,
                    // even another copy of Claude's live data.
                    if FS.isDir(slot), !real.contains(where: { FS.real($0) == target }) {
                        try merge(URL(fileURLWithPath: target), into: shared, conflicts: conflicts,
                                  consume: false, dryRun: dryRun, report: &report)
                    }
                    if !dryRun { try FS.remove(slot) }
                } else if FS.isDir(slot) {
                    try merge(slot, into: shared, conflicts: conflicts, consume: true, dryRun: dryRun, report: &report)
                    if !dryRun { try FS.remove(slot) }
                } else if FS.exists(slot) {
                    continue  // a stray file; leave it alone
                }
                report.linked += 1
                if !dryRun {
                    try FS.mkdir(slot.deletingLastPathComponent())
                    try FS.fm.createSymbolicLink(at: slot, withDestinationURL: shared)
                }
            }
            log("\(rootName) → \(shared.deletingLastPathComponent().lastPathComponent.prefix(8))/\(shared.lastPathComponent.prefix(8))")
        }
        if !dryRun { try settings.save() }
        log((dryRun ? "Would have " : "") + report.summary
            + ((report.merged + report.conflicts > 0 && !dryRun) ? " (originals in \(conflictsRoot.path))" : ""))
        return report
    }

    /// Bring src's contents into dst. A session in both keeps the copy with
    /// the newer lastActivityAt; JSON indexes (scheduled tasks, archive
    /// list) are merged so nothing is dropped. Losers go to conflicts/.
    /// consume=true moves files out of src (the caller deletes it next);
    /// consume=false only copies and leaves src exactly as it was.
    static func merge(_ src: URL, into dst: URL, conflicts: URL, consume: Bool,
                      dryRun: Bool, report: inout Report) throws {
        // Merging a folder into itself would delete every "duplicate".
        guard !FS.exists(dst) || FS.real(src) != FS.real(dst) else { return }
        if !dryRun { try FS.mkdir(dst) }
        for name in FS.list(src) {
            let s = src.appendingPathComponent(name), d = dst.appendingPathComponent(name)
            if FS.isDir(s) && !FS.isLink(s) {
                guard !FS.exists(d) || FS.isDir(d) else {
                    throw SwapError("Cannot merge folder \(s.path) onto file \(d.path)")
                }
                try merge(s, into: d, conflicts: conflicts.appendingPathComponent(name),
                          consume: consume, dryRun: dryRun, report: &report)
                continue
            }
            // take(s, to:) moves when consuming, copies otherwise.
            func take(_ from: URL, to: URL) throws {
                if consume { try FS.move(from, to: to) } else { try FS.copy(from, to: to) }
            }
            if !FS.exists(d) {
                report.moved += 1
                if !dryRun { try take(s, to: d) }
                continue
            }
            if FS.sameContents(s, d) {
                report.same += 1
                if !dryRun && consume { try FS.remove(s) }
                continue
            }
            if !name.hasPrefix("local_"), let merged = mergedJSON(s, d) {
                report.merged += 1
                if !dryRun {
                    try FS.mkdir(conflicts)
                    try FS.copy(d, to: conflicts.appendingPathComponent(name + ".kept"))
                    try take(s, to: conflicts.appendingPathComponent(name + ".merged-in"))
                    try JSONFile.write(merged, to: d, pretty: false)
                }
                continue
            }
            report.conflicts += 1
            let keepSource = activity(s) > activity(d)
            if !dryRun {
                try FS.mkdir(conflicts)
                if keepSource {
                    try FS.move(d, to: conflicts.appendingPathComponent(name))
                    try take(s, to: d)
                } else {
                    try take(s, to: conflicts.appendingPathComponent(name))
                }
            }
        }
    }

    static func activity(_ url: URL) -> Double {
        if let object = JSONFile.read(url) as? [String: Any], let t = object["lastActivityAt"] as? Double {
            return t
        }
        return FS.mtime(url).timeIntervalSince1970 * 1000
    }

    static func mergedJSON(_ a: URL, _ b: URL) -> Any? {
        guard let va = JSONFile.read(a), let vb = JSONFile.read(b) else { return nil }
        return FS.mtime(a) >= FS.mtime(b) ? JSONMerge.merge(va, vb) : JSONMerge.merge(vb, va)
    }
}

/// Union of two JSON values, the newer side winning on scalars. Lists of
/// objects with an "id" merge by id; other lists keep every distinct item.
public enum JSONMerge {
    public static func merge(_ newer: Any, _ older: Any) -> Any {
        if let n = newer as? [String: Any], let o = older as? [String: Any] {
            var out = n
            for (k, v) in o { out[k] = n[k].map { merge($0, v) } ?? v }
            return out
        }
        if let n = newer as? [Any], let o = older as? [Any] {
            let all = n + o
            if !all.isEmpty, all.allSatisfy({ ($0 as? [String: Any])?["id"] != nil }) {
                let seen = Set(n.map { key(($0 as! [String: Any])["id"]!) })
                return n + o.filter { !seen.contains(key(($0 as! [String: Any])["id"]!)) }
            }
            let seen = Set(n.map(key))
            return n + o.filter { !seen.contains(key($0)) }
        }
        return newer
    }

    static func key(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) {
            return String(decoding: data, as: UTF8.self)
        }
        return "\(value)"
    }
}

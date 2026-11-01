import Foundation

public struct SwapError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Where things live. Tests point both folders at a temp copy and set
/// CDSWAP_NO_APP=1 so the real Claude app is never quit or opened.
public enum Paths {
    static let env = ProcessInfo.processInfo.environment

    public static var claudeDir: URL {
        URL(fileURLWithPath: expand(env["CDSWAP_CLAUDE_DIR"] ?? "~/Library/Application Support/Claude"))
    }

    public static var store: URL {
        URL(fileURLWithPath: expand(env["CDSWAP_HOME"] ?? "~/Library/Application Support/Claude Desktop Swap"))
    }

    public static var noApp: Bool { env["CDSWAP_NO_APP"] == "1" }

    public static func claude(_ parts: String...) -> URL {
        parts.reduce(claudeDir) { $0.appendingPathComponent($1) }
    }

    public static func inStore(_ parts: String...) -> URL {
        parts.reduce(store) { $0.appendingPathComponent($1) }
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}

enum FS {
    static let fm = FileManager.default

    static func exists(_ url: URL) -> Bool {
        // Also true for a dangling symlink.
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    static func isDir(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    static func isLink(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    static func remove(_ url: URL) throws {
        if exists(url) { try fm.removeItem(at: url) }
    }

    static func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func list(_ url: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    static func mtime(_ url: URL) -> Date {
        ((try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date) ?? .distantPast
    }

    /// Replace dst with a copy of src.
    static func copy(_ src: URL, to dst: URL) throws {
        try remove(dst)
        try mkdir(dst.deletingLastPathComponent())
        try fm.copyItem(at: src, to: dst)
    }

    static func move(_ src: URL, to dst: URL) throws {
        try mkdir(dst.deletingLastPathComponent())
        try fm.moveItem(at: src, to: dst)
    }

    /// The physical path with every symlink resolved (Foundation's
    /// resolvingSymlinksInPath drops /private, so it can't be compared).
    static func real(_ url: URL) -> String {
        guard let p = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(p) }
        return String(cString: p)
    }

    static func sameContents(_ a: URL, _ b: URL) -> Bool {
        fm.contentsEqual(atPath: a.path, andPath: b.path)
    }
}

enum JSONFile {
    static func read(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func readObject(_ url: URL) -> [String: Any] {
        (read(url) as? [String: Any]) ?? [:]
    }

    /// Atomic write, readable only by the user (these files hold tokens).
    static func write(_ value: Any, to url: URL, pretty: Bool = true) throws {
        try FS.mkdir(url.deletingLastPathComponent())
        let data = try JSONSerialization.data(
            withJSONObject: value, options: pretty ? [.prettyPrinted, .sortedKeys] : [])
        let tmp = url.appendingPathExtension("cdswap-tmp")
        try data.write(to: tmp)
        try FS.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        guard rename(tmp.path, url.path) == 0 else {
            throw SwapError("Could not write \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func write<T: Encodable>(encodable value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: encoder.encode(value))
        try write(object, to: url)
    }
}

func stamp(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: date)
}

import AppKit
import Foundation

/// The Claude desktop app as a process: is it running, quit it, open it.
public enum ClaudeApp {
    public static let bundleID = "com.anthropic.claudefordesktop"

    static func instances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }

    public static var isRunning: Bool {
        Paths.noApp ? false : !instances().isEmpty
    }

    public static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// True when this process descends from Claude (a command typed into a
    /// Code tab). Quitting Claude would then kill us mid-switch.
    public static func isAncestorOfCurrentProcess() -> Bool {
        let claude = Set(instances().map { $0.processIdentifier })
        var pid = getpid()
        for _ in 0..<64 {
            if claude.contains(pid) { return true }
            guard let parent = parentPID(of: pid), parent > 1 else { return false }
            pid = parent
        }
        return false
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Ask Claude to quit (same as ⌘Q) and wait for it to exit.
    public static func quit(timeout: TimeInterval = 90, log: (String) -> Void) throws {
        guard !Paths.noApp else { return }
        let running = instances()
        guard !running.isEmpty else { return }
        log("Quitting Claude…")
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if instances().isEmpty {
                Thread.sleep(forTimeInterval: 1.5)  // let helpers flush their files
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw SwapError("Claude did not quit within \(Int(timeout))s (a confirm dialog may be open). Nothing was changed.")
    }

    public static func launch(log: (String) -> Void) {
        guard !Paths.noApp else { return }
        log("Opening Claude…")
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", bundleID]
        try? open.run()
        open.waitUntilExit()
    }
}

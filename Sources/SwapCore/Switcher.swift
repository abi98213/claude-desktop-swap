import Foundation

/// The switch itself: quit Claude, keep the signed-in account's fresh
/// tokens, put another account's sign-in in place, open Claude again.
public enum Switcher {
    public typealias Log = (String) -> Void

    /// Switch to a saved account, or sign out (nil) to add a new one.
    public static func switchTo(_ target: Profile?, reason: String = "switch", log: @escaping Log) throws {
        UsageTracker.refresh()
        try ClaudeApp.quit(log: log)
        let backup = try Backups.take(reason: reason)
        do {
            if Slice.currentAccount != nil {
                let saved = try Profiles.save(live: false)
                log("Saved \(saved.label).")
            }
            try Slice.restore(from: target.map { Profiles.folder($0.name) })
            if Settings.load().share { try Sharing.run(log: log) }
        } catch {
            log("Something failed (\(error.localizedDescription)); restoring the previous sign-in.")
            try? Slice.restore(from: backup)
            runHook(log: log)
            ClaudeApp.launch(log: log)
            throw error
        }
        if reason == "auto" { UsageTracker.noteAutoSwitch() }
        runHook(log: log)
        ClaudeApp.launch(log: log)
        log(target.map { "Switched to \($0.label)." }
            ?? "Claude is signed out. Sign in with the other account, then save it.")
    }

    /// Put back the sign-in from before the last switch.
    public static func undo(log: @escaping Log) throws {
        guard let backup = Backups.latest else { throw SwapError("No backups yet.") }
        try ClaudeApp.quit(log: log)
        if Slice.currentAccount != nil { try Profiles.save(live: false) }
        try Slice.restore(from: backup)
        runHook(log: log)
        ClaudeApp.launch(log: log)
        log("Restored the sign-in from before \(backup.lastPathComponent).")
    }

    /// Share sessions now. Folders in use can only be replaced while Claude
    /// is closed, so this restarts it when needed.
    public static func shareNow(restart: Bool, log: @escaping Log) throws {
        if ClaudeApp.isRunning {
            guard restart else {
                throw SwapError("Claude is running. Pass --restart to quit and reopen it, or it happens on your next switch.")
            }
            try ClaudeApp.quit(log: log)
            defer { ClaudeApp.launch(log: log) }
            try Sharing.run(log: log)
            runHook(log: log)
        } else {
            try Sharing.run(log: log)
        }
    }

    /// The user's after-switch command, run while Claude is closed. A
    /// failure is reported but never undoes the switch.
    static func runHook(log: Log) {
        guard let command = Settings.load().afterSwitch, !command.isEmpty else { return }
        log("Running after-switch hook…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["CDSWAP_ACCOUNT"] = Slice.currentAccount ?? ""
        p.environment = env
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                log("After-switch hook exited with \(p.terminationStatus) (the switch itself is done).")
            }
        } catch {
            log("After-switch hook could not start: \(error.localizedDescription)")
        }
    }
}

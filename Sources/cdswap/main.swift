import Foundation
import SwapCore

let usage = """
cdswap — switch Claude desktop accounts without signing out

  cdswap                      who is signed in
  cdswap list                 saved accounts with their last usage
  cdswap add [name]           save the signed-in account (name defaults to its email)
  cdswap switch [name]        switch account (no name: the next one)
  cdswap new                  sign out, keeping this account saved, to add another
  cdswap auto [--once] [--dry-run]
                              switch when the account hits its limit (see `cdswap config`)
  cdswap share [--dry-run] [--restart] [--cowork|--no-cowork] [--on|--off]
                              every account shows the same Code sessions
  cdswap undo                 restore the sign-in from before the last switch
  cdswap rename OLD NEW · cdswap remove NAME
  cdswap hook ["command"] [--clear]
                              run a command after each switch, while Claude is closed
  cdswap config [key value]   threshold (percent), autoSwitch (true/false), countdown (s)

A switch quits and reopens Claude, so running sessions stop.
"""

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
let foreground = flag("--foreground")
let detachRequested = flag("--detach")
let command = args.first ?? "status"
if !args.isEmpty { args.removeFirst() }

func say(_ s: String) { print(s); fflush(stdout) }
func fail(_ s: String) -> Never {
    FileHandle.standardError.write(("cdswap: " + s + "\n").data(using: .utf8)!)
    exit(1)
}

/// Quitting Claude kills processes it started (a command typed into a Code
/// tab). In that case hand the work to a detached copy of ourselves.
func detachIfNeeded() {
    guard !Paths.noApp, !foreground, detachRequested || ClaudeApp.isAncestorOfCurrentProcess() else { return }
    let logURL = Paths.inStore("logs", "last.log")
    try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var argv = [CommandLine.arguments[0], command] + args + ["--foreground"]
    var attr = posix_spawnattr_t(bitPattern: 0)
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var actions = posix_spawn_file_actions_t(bitPattern: 0)
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, logURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    argv[0] = exe
    var cargs = argv.map { strdup($0) } + [nil]
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, exe, &actions, &attr, &cargs, environ)
    cargs.forEach { free($0) }
    guard rc == 0 else { fail("could not start the background switch (\(rc))") }
    say("Running in the background (Claude will restart). Log: \(logURL.path)")
    exit(0)
}

func profile(named name: String) -> Profile {
    if let p = Profiles.named(name) ?? Profiles.all().first(where: { $0.email == name }) { return p }
    fail("No account named '\(name)'. Saved: \(Profiles.all().map(\.name).joined(separator: ", "))")
}

func usageText(_ account: String) -> String {
    guard let u = UsageTracker.usage(for: account) else { return "usage unknown" }
    let c = u.current()
    let f = c.fiveHour.map { "\(Int($0))%" } ?? "–"
    let s = c.sevenDay.map { "\(Int($0))%" } ?? "–"
    let age = Int(Date().timeIntervalSince(u.at) / 60)
    return "5h \(f) · 7d \(s) (\(age < 120 ? "\(age)m" : "\(age / 60)h") ago)"
}

do {
    switch command {
    case "status":
        UsageTracker.refresh()
        let account = Slice.currentAccount
        if flag("--name") {
            say(Profiles.active?.name ?? (account.map { "unsaved:" + $0 } ?? "signed-out"))
            break
        }
        say("Claude is \(ClaudeApp.isRunning ? "running" : "not running").")
        if let account = account {
            if let p = Profiles.active {
                say("Signed in: \(p.label) — \(usageText(account))")
            } else {
                say("Signed in: \(Slice.detectEmail() ?? String(account.prefix(8))) (not saved yet: cdswap add)")
            }
        } else {
            say("Signed out.")
        }

    case "list":
        UsageTracker.refresh()
        let all = Profiles.all()
        if flag("--names") { all.forEach { say($0.name) }; break }
        if flag("--json") {
            let rows: [[String: Any]] = all.map { p in
                var row: [String: Any] = ["name": p.name, "account": p.account,
                                          "active": p.account == Slice.currentAccount]
                if let e = p.email { row["email"] = e }
                if let u = UsageTracker.usage(for: p.account) {
                    let c = u.current()
                    row["fiveHour"] = c.fiveHour ?? NSNull()
                    row["sevenDay"] = c.sevenDay ?? NSNull()
                    row["usageAt"] = ISO8601DateFormatter().string(from: u.at)
                }
                return row
            }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            say(String(decoding: data, as: UTF8.self))
            break
        }
        if all.isEmpty { say("No saved accounts. Sign in to Claude, then run: cdswap add") }
        for p in all {
            let mark = p.account == Slice.currentAccount ? "*" : " "
            say("\(mark) \(p.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(usageText(p.account))")
        }

    case "add":
        UsageTracker.refresh()
        let p = try Profiles.save(as: args.first, live: ClaudeApp.isRunning)
        say("Saved the signed-in account as '\(p.name)'.")

    case "switch":
        let force = flag("--force")
        let all = Profiles.all()
        guard !all.isEmpty else { fail("No saved accounts yet. Sign in, then run: cdswap add") }
        let target: Profile
        if let name = args.first {
            target = profile(named: name)
        } else {
            let i = all.firstIndex { $0.account == Slice.currentAccount } ?? -1
            target = all[(i + 1) % all.count]
        }
        if target.account == Slice.currentAccount && !force { say("Already on \(target.label)."); break }
        detachIfNeeded()
        try Switcher.switchTo(target, log: say)

    case "new":
        detachIfNeeded()
        try Switcher.switchTo(nil, reason: "new", log: say)

    case "auto":
        let once = flag("--once"), dry = flag("--dry-run")
        if !once && !dry { detachIfNeeded() }
        repeat {
            UsageTracker.refresh()
            switch AutoSwitch.decide() {
            case .stay(let why):
                if once || dry { say("Staying: \(why).") }
            case .allLimited(let reset):
                say("Every saved account is at its limit" + (reset.map { "; the next resets around \($0.formatted(date: .omitted, time: .shortened))" } ?? "") + ".")
            case .switchTo(let p, let reason):
                say("\(reason); switching to \(p.label).")
                if !dry {
                    try Switcher.switchTo(p, reason: "auto", log: say)
                }
            }
            if once || dry { break }
            Thread.sleep(forTimeInterval: 30)
        } while true

    case "share":
        var s = Settings.load()
        if flag("--cowork") { s.shareCowork = true }
        if flag("--no-cowork") { s.shareCowork = false }
        if flag("--off") { s.share = false; try s.save(); say("Sessions won't be shared on future switches."); break }
        if flag("--on") { s.share = true }
        try s.save()
        if flag("--dry-run") { try Sharing.run(dryRun: true, log: say); break }
        let restart = flag("--restart")
        if restart { detachIfNeeded() }
        try Switcher.shareNow(restart: restart, log: say)

    case "undo":
        detachIfNeeded()
        try Switcher.undo(log: say)

    case "rename":
        guard args.count == 2 else { fail("usage: cdswap rename OLD NEW") }
        try Profiles.rename(args[0], to: args[1])
        say("Renamed '\(args[0])' to '\(args[1])'.")

    case "remove":
        guard let name = args.first else { fail("usage: cdswap remove NAME") }
        try Profiles.remove(name)
        say("Removed '\(name)'. Its sessions stay; only the saved sign-in is gone.")

    case "hook":
        var s = Settings.load()
        if flag("--clear") {
            s.afterSwitch = nil
            try s.save()
            say("After-switch hook cleared.")
        } else if let cmd = args.first {
            s.afterSwitch = cmd
            try s.save()
            say("After every switch, while Claude is closed, cdswap runs: \(cmd)")
        } else {
            say(s.afterSwitch ?? "No after-switch hook.")
        }

    case "config":
        var s = Settings.load()
        if args.count == 2 {
            switch args[0] {
            case "threshold": guard let v = Double(args[1]), v > 0, v <= 100 else { fail("threshold is 1–100") }; s.threshold = v
            case "autoSwitch": s.autoSwitch = ["1", "true", "on", "yes"].contains(args[1].lowercased())
            case "countdown": guard let v = Int(args[1]), v >= 0 else { fail("countdown is seconds") }; s.countdown = v
            default: fail("unknown key \(args[0])")
            }
            try s.save()
        }
        say("autoSwitch \(s.autoSwitch) · threshold \(Int(s.threshold))% · countdown \(s.countdown)s · share \(s.share) · cowork \(s.shareCowork)")

    case "help", "-h", "--help":
        say(usage)

    default:
        fail("unknown command '\(command)'\n\n" + usage)
    }
} catch {
    fail(error.localizedDescription)
}

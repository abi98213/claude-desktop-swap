import AppKit
import ServiceManagement
import SwapCore
import SwiftUI

/// Everything the menu shows, refreshed every 30 seconds, plus the
/// auto-switch loop.
@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var activeAccount: String?
    @Published var detectedEmail: String?
    @Published var usage: [String: Usage] = [:]
    @Published var settings = SwapCore.Settings.load()
    @Published var busy: String?
    @Published var lastMessage: String?
    @Published var countdown: Countdown?

    struct Countdown: Equatable {
        var target: Profile
        var reason: String
        var secondsLeft: Int
    }

    private var timer: Timer?
    private var tick: Timer?
    private var snoozedUntil: [String: Date] = [:]
    private let panel = CountdownPanel()

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    var active: Profile? { profiles.first { $0.account == activeAccount } }

    /// Auto-switch can't see the limit coming without recent readings.
    var usageIsStale: Bool {
        guard settings.autoSwitch, ClaudeApp.isRunning, let account = activeAccount else { return false }
        guard let u = usage[account] else { return true }
        return Date().timeIntervalSince(u.at) > 30 * 60
    }
    var claudeInstalled: Bool { ClaudeApp.isInstalled }

    func reload() {
        usage = UsageTracker.refresh()
        profiles = Profiles.all()
        activeAccount = Slice.currentAccount
        settings = SwapCore.Settings.load()
        if active == nil, activeAccount != nil, detectedEmail == nil {
            detectedEmail = Slice.detectEmail()
        }
    }

    func poll() {
        guard busy == nil else { return }
        reload()
        guard settings.autoSwitch, countdown == nil, ClaudeApp.isRunning else { return }
        if case .switchTo(let target, let reason) = AutoSwitch.decide(settings: settings) {
            if let active = activeAccount, let until = snoozedUntil[active], until > Date() { return }
            startCountdown(target: target, reason: reason)
        }
    }

    // MARK: actions

    func saveCurrent() {
        run("Saving…") { _ in
            let p = try Profiles.save(live: ClaudeApp.isRunning)
            return "Saved \(p.label)."
        }
    }

    func switchTo(_ profile: Profile, reason: String = "switch") {
        run("Switching to \(profile.label)…") { log in
            try Switcher.switchTo(profile, reason: reason, log: log)
            return "Switched to \(profile.label)."
        }
    }

    func addAnother() {
        let alert = NSAlert()
        alert.messageText = "Sign in to another account"
        alert.informativeText = "Claude restarts signed out and your current account stays saved. Sign in with the other account, then click “Save this account” here. Running sessions stop."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run("Signing out…") { log in
            try Switcher.switchTo(nil, reason: "new", log: log)
            return "Sign in with the other account in Claude, then save it here."
        }
    }

    func undo() {
        run("Undoing the last switch…") { log in
            try Switcher.undo(log: log)
            return "Restored the previous sign-in."
        }
    }

    func rename(_ profile: Profile) {
        let alert = NSAlert()
        alert.messageText = "Rename \(profile.label)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = profile.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(nil) { _ in
            try Profiles.rename(profile.name, to: field.stringValue)
            return nil
        }
    }

    func remove(_ profile: Profile) {
        let alert = NSAlert()
        alert.messageText = "Forget \(profile.label)?"
        alert.informativeText = "Only its saved sign-in is removed. Sessions stay. To use it again, sign in to it in Claude and save it."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(nil) { _ in try Profiles.remove(profile.name); return nil }
    }

    func update(_ change: (inout SwapCore.Settings) -> Void) {
        change(&settings)
        try? settings.save()
    }

    func shareNow() {
        run("Sharing sessions…") { log in
            try Switcher.shareNow(restart: true, log: log)
            return "Every account now shows the same sessions."
        }
    }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastMessage = "Couldn't change Open at Login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }

    /// Run blocking work (quitting Claude takes seconds) off the main thread.
    private func run(_ status: String?, _ work: @escaping (@escaping (String) -> Void) throws -> String?) {
        busy = status
        lastMessage = nil
        let log: (String) -> Void = { line in
            DispatchQueue.main.async { if self.busy != nil { self.busy = line } }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: String?
            do { result = try work(log) } catch { result = "⚠︎ " + error.localizedDescription }
            DispatchQueue.main.async {
                self.busy = nil
                self.lastMessage = result
                self.reload()
            }
        }
    }

    // MARK: auto-switch countdown

    private func startCountdown(target: Profile, reason: String) {
        countdown = Countdown(target: target, reason: reason, secondsLeft: max(settings.countdown, 0))
        if settings.countdown == 0 { return finishCountdown(switchNow: true) }
        panel.show(model: self)
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, var c = self.countdown else { return }
                c.secondsLeft -= 1
                self.countdown = c
                if c.secondsLeft <= 0 { self.finishCountdown(switchNow: true) }
            }
        }
    }

    func finishCountdown(switchNow: Bool) {
        tick?.invalidate()
        tick = nil
        panel.hide()
        guard let c = countdown else { return }
        countdown = nil
        if switchNow {
            switchTo(c.target, reason: "auto")
        } else if let active = activeAccount {
            snoozedUntil[active] = Date().addingTimeInterval(30 * 60)
            lastMessage = "Auto-switch paused for 30 minutes."
        }
    }
}

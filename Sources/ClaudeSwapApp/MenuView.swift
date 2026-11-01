import AppKit
import SwapCore
import SwiftUI

@main
struct ClaudeSwapApp: App {
    @StateObject private var model = AppModel()

    init() {
        // `--render-preview out.png [--dark] [--countdown]` draws the menu (or
        // the auto-switch warning) to a PNG and exits: README screenshots,
        // and checking the UI without clicking the menu bar.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
            MainActor.assumeIsolated {
                Self.renderPreview(to: args[i + 1], dark: args.contains("--dark"),
                                   countdown: args.contains("--countdown"))
            }
            exit(0)
        }
    }

    @MainActor
    static func renderPreview(to path: String, dark: Bool, countdown: Bool) {
        let model = AppModel()
        let root: AnyView
        if countdown, let target = model.profiles.first(where: { $0.account != model.activeAccount }) {
            model.countdown = .init(target: target, reason: "\(model.active?.label ?? "This account") reached 96%",
                                    secondsLeft: 42)
            root = AnyView(CountdownView().environmentObject(model))
        } else {
            root = AnyView(MenuView().environmentObject(model))
        }
        // A real window, so native switches and sliders draw (ImageRenderer
        // replaces AppKit-backed controls with placeholders).
        let host = NSHostingView(rootView: root.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.setFrameSize(host.fittingSize)
        let window = PreviewWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = host.appearance
        // Switches only draw in the accent color in the active app, so show
        // the window far off screen for the capture.
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: model.busy != nil ? "arrow.triangle.2.circlepath"
                  : model.countdown != nil ? "exclamationmark.arrow.triangle.2.circlepath"
                  : "person.2.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Draws controls in their focused (accent-colored) state off screen.
private final class PreviewWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

struct MenuView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let busy = model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).lineLimit(2)
                }
            }
            if model.active == nil, model.activeAccount != nil {
                unsavedBanner
            }
            accounts
            Divider()
            options
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .disabled(model.busy != nil)
        .onAppear { model.reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Claude accounts").font(.headline)
            if !model.claudeInstalled {
                Text("Claude desktop app not found.").font(.caption).foregroundStyle(.red)
            } else if model.activeAccount == nil {
                Text("Claude is signed out.").font(.caption).foregroundStyle(.secondary)
            }
            if model.usageIsStale {
                Text("No fresh usage reading. Claude only records usage if you've opened its usage view in the last 24 hours.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.lastMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var unsavedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Signed in as \(model.detectedEmail ?? "an unsaved account")")
                .font(.callout)
            Button("Save this account") { model.saveCurrent() }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
    }

    private var accounts: some View {
        VStack(spacing: 4) {
            if model.profiles.isEmpty && model.activeAccount == nil {
                Text("Sign in to Claude, save the account here, then add your others.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(model.profiles) { profile in
                AccountRow(profile: profile,
                           usage: model.usage[profile.account],
                           active: profile.account == model.activeAccount,
                           threshold: model.settings.threshold)
            }
            Button {
                model.addAnother()
            } label: {
                Label("Add another account…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow(title: "Switch automatically at the limit",
                       detail: "At \(Int(model.settings.threshold))% of the 5-hour or weekly limit, after a \(model.settings.countdown)s warning",
                       isOn: Binding(get: { model.settings.autoSwitch },
                                     set: { v in model.update { $0.autoSwitch = v } }))
            if model.settings.autoSwitch {
                HStack {
                    Text("Threshold").font(.caption)
                    Slider(value: Binding(get: { model.settings.threshold },
                                          set: { v in model.update { $0.threshold = v.rounded() } }),
                           in: 50...100, step: 5)
                    Text("\(Int(model.settings.threshold))%").font(.caption.monospacedDigit()).frame(width: 36)
                }
                .controlSize(.small)
            }
            SettingRow(title: "Same sessions on every account",
                       detail: "Code sessions stay in the sidebar after a switch",
                       isOn: Binding(get: { model.settings.share },
                                     set: { v in model.update { $0.share = v } }))
            SettingRow(title: "Open at login", detail: nil,
                       isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
        }
    }

    private var footer: some View {
        HStack {
            Menu("More") {
                Button("Share sessions now (restarts Claude)") { model.shareNow() }
                Button("Undo last switch") { model.undo() }
                Divider()
                Button("Open data folder") {
                    NSWorkspace.shared.open(Paths.store)
                }
                Button("About Claude Desktop Swap") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/abi98213/claude-desktop-swap")!)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .font(.callout)
    }
}

struct SettingRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail = detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile
    let usage: Usage?
    let active: Bool
    let threshold: Double
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.label).lineLimit(1).truncationMode(.middle)
                    .fontWeight(active ? .semibold : .regular)
                UsageBars(usage: usage, threshold: threshold)
            }
            Spacer(minLength: 0)
            if !active && hovering {
                Text("Switch").font(.caption).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering && !active ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !active { model.switchTo(profile) } }
        .contextMenu {
            if !active { Button("Switch to \(profile.label)") { model.switchTo(profile) } }
            Button("Rename…") { model.rename(profile) }
            Button("Forget…", role: .destructive) { model.remove(profile) }
        }
    }
}

struct UsageBars: View {
    let usage: Usage?
    let threshold: Double

    var body: some View {
        if let usage = usage {
            let c = usage.current()
            HStack(spacing: 10) {
                bar("5h", c.fiveHour)
                bar("7d", c.sevenDay)
                Text(age(usage.at)).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).fixedSize()
            }
        } else {
            Text("No usage reading yet").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func bar(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill((value ?? 0) >= threshold ? Color.red : Color.accentColor)
                    .frame(width: 36 * CGFloat(min(max(value ?? 0, 0), 100) / 100))
            }
            .frame(width: 36, height: 5)
            Text(value.map { "\(Int($0))%" } ?? "–").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func age(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "now" }
        if minutes < 120 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}

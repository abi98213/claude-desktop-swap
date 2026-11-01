import AppKit
import SwiftUI

/// A small floating window shown before an automatic switch, because the
/// switch restarts Claude and stops running sessions.
@MainActor
final class CountdownPanel {
    private var panel: NSPanel?

    func show(model: AppModel) {
        let panel = self.panel ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
            styleMask: [.titled, .nonactivatingPanel, .hudWindow, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "Claude Desktop Swap"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CountdownView().environmentObject(model))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 380, y: frame.maxY - 170))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() { panel?.orderOut(nil) }
}

struct CountdownView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let c = model.countdown {
                Text("\(c.reason).").font(.headline)
                Text("Switching to \(c.target.label) in \(c.secondsLeft)s. Claude will restart and running sessions stop.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Not now") { model.finishCountdown(switchNow: false) }
                    Button("Switch now") { model.finishCountdown(switchNow: true) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

import AppKit
import SwiftUI

@MainActor
final class LockgateAppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?
    var stopForTermination: (() async -> Bool)?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let stopForTermination else { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true
        Task {
            let stopped = await stopForTermination()
            terminating = false
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let openMainWindow else { return true }
        openMainWindow()
        sender.activate(ignoringOtherApps: true)
        return false
    }
}

struct MainWindowReopenHandler: ViewModifier {
    let delegate: LockgateAppDelegate
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.openMainWindow = { openWindow(id: "main") }
        }
    }
}

import SwiftUI
import AppKit

@main
struct ProjectMCPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { MainView() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let image = Bundle.main.url(forResource: "AppIcon", withExtension: "png") {
            NSApp.applicationIconImage = NSImage(contentsOf: image)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppController.shared.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "停止连接并退出？"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            await AppController.shared.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

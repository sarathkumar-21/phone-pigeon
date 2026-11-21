import SwiftUI

@main
struct PhonePigeonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        Window("PhonePigeon", id: "main") {
            RootView()
                .environment(app)
                .onAppear { NotificationManager.shared.bootstrap() }
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") { app.showNewMessage = true }
                    .keyboardShortcut("n")
                    .disabled(!app.isPaired)
                Button("Add Phone…") { app.showAddPhone = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Phone") {
                ForEach(Array(AppState.Section.tabs.enumerated()), id: \.element) { i, s in
                    Button(s.title) { app.section = s }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                }
                Divider()
                Button("Mark All as Read") { app.markAllRead() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Reconnect") { app.reconnect() }
                if app.isDemo {
                    Divider()
                    Menu("Demo Phone") {
                        Button("Simulate Incoming Call") { app.demoIncomingCall() }
                            .keyboardShortcut("i", modifiers: [.command, .shift])
                        Button("Simulate Incoming SMS") { app.demoIncomingMessage() }
                        Button("Simulate OTP") { app.demoIncomingOTP() }
                    }
                }
            }
        }

        Settings {
            SettingsView().environment(app)
        }

        MenuBarExtra {
            MenuBarView().environment(app)
        } label: {
            Image(systemName: app.unreadTotal > 0 ? "message.badge.filled.fill" : "iphone.gen3.radiowaves.left.and.right")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

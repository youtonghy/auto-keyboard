import AppKit
import SwiftUI

@main
struct AutoKeyboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("AutoKeyboard", systemImage: "keyboard.badge.ellipsis") {
            MenuView()
                .environmentObject(delegate.coordinator)
                .environmentObject(delegate.coordinator.settings)
                .environmentObject(delegate.coordinator.sources)
                .environmentObject(delegate.coordinator.tracker)
                .environmentObject(delegate.coordinator.smartLearning)
                .environmentObject(delegate.coordinator.loadGovernor)
        }

        Settings {
            SettingsView()
                .environmentObject(delegate.coordinator)
                .environmentObject(delegate.coordinator.settings)
                .environmentObject(delegate.coordinator.sources)
                .environmentObject(delegate.coordinator.tracker)
                .environmentObject(delegate.coordinator.smartLearning)
                .environmentObject(delegate.coordinator.loadGovernor)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
    }
}

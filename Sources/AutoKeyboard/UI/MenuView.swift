import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var sources: InputSourceManager
    @EnvironmentObject private var tracker: FocusTracker
    @EnvironmentObject private var loadGovernor: AXLoadGovernor
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("当前输入源：\(sources.name(of: sources.currentID))")

        Toggle("启用自动切换", isOn: Binding(
            get: { settings.value.enabled },
            set: { settings.value.enabled = $0 }
        ))

        if !coordinator.axTrusted {
            Button("⚠️ 未授权辅助功能，点击前往设置") {
                Permissions.openAccessibilitySettings()
            }
        }

        Divider()

        if let focus = tracker.lastFocus {
            let capability = coordinator.axCapabilityForUI(focus: focus)
            Text(capability.label)
                .foregroundStyle(.secondary)

            if capability == .overloaded, loadGovernor.isSuspended(focus.bundleID) {
                Button("恢复「\(focus.appName)」的智能模式") {
                    loadGovernor.resume(bundleID: focus.bundleID)
                }
            }

            Menu("「\(focus.appName)」的模式") {
                appModeButtons(for: focus)
            }
        }

        Divider()

        Button("设置…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Button("退出 AutoKeyboard") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private func appModeButtons(for focus: FocusTracker.Focus) -> some View {
        let currentMode = settings.rule(for: focus.bundleID)?.mode ?? .memory
        ForEach(AppMode.allCases, id: \.self) { mode in
            Button {
                var rule = settings.rule(for: focus.bundleID)
                    ?? AppRule(bundleID: focus.bundleID, displayName: focus.appName)
                rule.mode = mode
                settings.upsertRule(rule)
            } label: {
                if mode == currentMode {
                    Label(mode.label, systemImage: "checkmark")
                } else {
                    Text(mode.label)
                }
            }
        }
    }
}

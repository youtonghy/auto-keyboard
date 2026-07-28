import AppKit
import Foundation

@MainActor
final class AppCoordinator: ObservableObject {
    let settings = SettingsStore()
    let sources = InputSourceManager()
    let tracker = FocusTracker()
    let memory = WindowStateStore()
    let smartLearning = SmartLearningStore()
    lazy var loadGovernor = AXLoadGovernor(settings: settings)
    private lazy var engine = RuleEngine(
        settings: settings,
        sources: sources,
        memory: memory,
        smartLearning: smartLearning,
        loadGovernor: loadGovernor
    )

    @Published var axTrusted = false

    private var evalTask: Task<Void, Never>?
    private var trustTimer: Timer?

    /// 统一读取应用的 AX 能力状态，由 governor 判定是否因过载而暂停智能模式。
    /// 不记录样本——仅供 UI 状态显示。
    func axCapabilityForUI(focus: FocusTracker.Focus) -> AXCapability {
        let mode = loadGovernor.samplingMode(for: focus.bundleID)
        guard mode == .full else { return .overloaded }
        return ContextDetector.axCapability(
            bundleID: focus.bundleID,
            element: focus.element,
            window: focus.window,
            config: ContextDetectionConfig(settings: settings.value.smartContext),
            mode: mode
        )
    }

    func start() {
        axTrusted = Permissions.axTrusted
        if !axTrusted {
            Permissions.requestAXPrompt()
        }

        if settings.value.englishSourceID == nil || settings.value.chineseSourceID == nil {
            let guess = sources.guessDefaults()
            if settings.value.englishSourceID == nil { settings.value.englishSourceID = guess.english }
            if settings.value.chineseSourceID == nil { settings.value.chineseSourceID = guess.chinese }
        }

        sources.onUserChange = { [weak self] sourceID in
            guard let self else { return }
            self.evalTask?.cancel()
            self.engine.noteManualSwitch(
                sourceID: sourceID,
                focus: self.tracker.isSelfFrontmost ? nil : self.tracker.lastFocus
            )
        }

        tracker.onFocusEvent = { [weak self] focus, trigger in
            self?.scheduleEvaluation(focus: focus, trigger: trigger)
        }

        settings.onChange = { [weak self] in
            guard let self, let focus = self.tracker.lastFocus else { return }
            self.scheduleEvaluation(focus: focus, trigger: .appActivated)
        }

        tracker.start()

        trustTimer = Timer.scheduledTimer(
            timeInterval: 2.0,
            target: self,
            selector: #selector(trustTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func trustTimerFired() {
        let trusted = Permissions.axTrusted
        if trusted != axTrusted {
            axTrusted = trusted
            if trusted {
                tracker.reattachFrontmost()
            }
        }
    }

    private func scheduleEvaluation(focus: FocusTracker.Focus, trigger: FocusTracker.Trigger) {
        guard !tracker.isSelfFrontmost else { return }
        evalTask?.cancel()
        let delay: Duration = switch trigger {
        case .titleChanged: .milliseconds(300)
        case .selectionChanged: .milliseconds(400)
        default: .milliseconds(120)
        }
        evalTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.engine.evaluate(focus: focus, trigger: trigger)
        }
    }
}

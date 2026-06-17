import AppKit
import Foundation

@MainActor
final class AppCoordinator: ObservableObject {
    let settings = SettingsStore()
    let sources = InputSourceManager()
    let tracker = FocusTracker()
    let memory = WindowStateStore()
    let smartLearning = SmartLearningStore()
    let fileLogger = FileLogger()
    private lazy var engine = RuleEngine(
        settings: settings,
        sources: sources,
        memory: memory,
        smartLearning: smartLearning,
        fileLogger: fileLogger
    )

    @Published var axTrusted = false
    @Published var screenCaptureTrusted = false

    private var evalTask: Task<Void, Never>?
    private var trustTimer: Timer?

    func start() {
        axTrusted = Permissions.axTrusted
        if !axTrusted {
            Permissions.requestAXPrompt()
        }
        screenCaptureTrusted = Permissions.screenCaptureTrusted

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

        tracker.onDebugLog = { [weak self] message in
            guard let self, self.settings.value.debugLogging else { return }
            self.fileLogger.log(message)
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
        let captureTrusted = Permissions.screenCaptureTrusted
        if captureTrusted != screenCaptureTrusted {
            screenCaptureTrusted = captureTrusted
            // 授权后（通常需重启进程才生效）立刻重评一次，让 OCR 兜底有机会介入
            if captureTrusted, let focus = tracker.lastFocus {
                scheduleEvaluation(focus: focus, trigger: .appActivated)
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

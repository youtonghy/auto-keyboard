import Foundation

struct MemoryResolution: Equatable {
    let sourceID: String
    let source: String
}

@MainActor
final class MemoryResolver {
    private let windowMemory: WindowStateStoring
    private let smartLearning: SmartLearningStoring

    init(windowMemory: WindowStateStoring, smartLearning: SmartLearningStoring) {
        self.windowMemory = windowMemory
        self.smartLearning = smartLearning
    }

    func learnedLanguage(for keys: SmartLearningKeyBuilder.Keys) -> SmartLearningMatch? {
        smartLearning.lookup(keys)
    }

    func recordWindowMemory(focus: FocusTracker.Focus, sourceID: String) {
        windowMemory.record(focus.key, sourceID: sourceID)
    }

    func recordManualCorrection(keys: SmartLearningKeyBuilder.Keys, lang: LangChoice) {
        smartLearning.recordManualCorrection(keys, lang: lang)
    }

    func recordNegativeFeedback(keys: SmartLearningKeyBuilder.Keys, against lang: LangChoice) {
        smartLearning.recordNegativeFeedback(keys, against: lang)
    }

    func reinforce(keys: SmartLearningKeyBuilder.Keys, lang: LangChoice) {
        smartLearning.reinforce(keys, lang: lang)
    }

    func fallback(
        focus: FocusTracker.Focus,
        rule: AppRule?,
        sourceFor: (LangChoice) -> String
    ) -> MemoryResolution? {
        if let remembered = windowMemory.lookup(focus.key) {
            return MemoryResolution(sourceID: remembered, source: "window-memory")
        }
        if let defaultLang = rule?.defaultLang {
            return MemoryResolution(sourceID: sourceFor(defaultLang), source: "app-default")
        }
        return nil
    }
}

import Foundation
import NaturalLanguage

struct LanguageClassification: Equatable {
    let lang: DetectedLang
    let confidence: Double
    let source: String
}

enum LanguageClassifier {
    static func classify(_ text: String) -> DetectedLang? {
        classifyDetailed(text)?.lang
    }

    static func classifyDetailed(_ text: String) -> LanguageClassification? {
        var han = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF:
                han += 1
            case 0x3001, 0x3002, 0xFF0C, 0xFF1B, 0xFF1A, 0xFF1F, 0xFF01:
                han += 1
            case 0x41...0x5A, 0x61...0x7A:
                latin += 1
            default:
                break
            }
        }
        let total = han + latin
        guard total >= 2 else { return nil }
        let ratio = Double(han) / Double(total)
        if ratio >= 0.30 {
            return LanguageClassification(lang: .chinese, confidence: min(1, ratio), source: "han-ratio")
        }
        if han == 0 {
            return LanguageClassification(lang: .english, confidence: 1, source: "latin-only")
        }
        if ratio < 0.05, total > 20 {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese, .english]
        recognizer.processString(String(text.suffix(400)))
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let (language, confidence) = hypotheses.max(by: { $0.value < $1.value }),
              confidence >= 0.6
        else { return nil }
        switch language {
        case .simplifiedChinese, .traditionalChinese:
            return LanguageClassification(lang: .chinese, confidence: confidence, source: "nl-language")
        case .english:
            return LanguageClassification(lang: .english, confidence: confidence, source: "nl-language")
        default:
            return nil
        }
    }
}

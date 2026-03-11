import Foundation

enum TextPostProcessor {
    static func clean(_ text: String, settings: AppSettings) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        var output = trimmed

        if settings.removeFillerWords {
            output = replace(pattern: "\\b(uh+|um+)\\b", in: output, with: "")
        }
        output = replace(pattern: "\\s{2,}", in: output, with: " ")
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !output.isEmpty else {
            return ""
        }

        if settings.capitalizeFirstLetter, let firstCharacter = output.first {
            output.replaceSubrange(output.startIndex...output.startIndex, with: String(firstCharacter).uppercased())
        }

        if settings.autoPunctuation,
           let lastCharacter = output.last,
           ![".", "?", "!"].contains(lastCharacter) {
            output += "."
        }

        return output
    }

    private static func replace(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}

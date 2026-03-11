import Foundation

enum TextPostProcessor {
    private static let technicalTermCorrections: [(pattern: String, replacement: String)] = [
        ("\\b(voice\\s+whats\\s*app)\\b", "voice WhatsApp"),
        ("\\b(speech\\s+recognizing)\\b", "speech recognition"),
        ("\\b(git|get|gate)\\s+come(?:\\s+it)?\\b", "git commit"),
        ("\\b(git|get|gate)\\s+check\\s*out\\b", "git checkout"),
        ("\\b(git|get|gate)\\s+pool\\b", "git pull"),
        ("\\b(git|get|gate)\\s+pull\\b", "git pull"),
        ("\\b(git|get|gate)\\s+push\\b", "git push"),
        ("\\b(git|get|gate)\\s+bush\\b", "git push"),
        ("\\b(git|get|gate)\\s+status\\b", "git status"),
        ("\\b(git|get|gate)\\s+fetch\\b", "git fetch"),
        ("\\b(git|get|gate)\\s+merge\\b", "git merge"),
        ("\\b(git|get|gate)\\s+branch\\b", "git branch"),
        ("\\b(git|get|gate)\\s+diff\\b", "git diff"),
        ("\\b(git|get|gate)\\s+log\\b", "git log"),
        ("\\b(git|get|gate)\\s+add\\b", "git add"),
        ("\\b(git|get|gate)\\s+stash\\b", "git stash"),
        ("\\b(on|in|from|to|open)\\s+get\\s+up\\b", "$1 GitHub"),
        ("\\bget\\s+up\\s+(repo|repository|issue|issues|branch|branches|actions)\\b", "GitHub $1"),
        ("\\bget\\s+up\\s+pull\\s+request\\b", "GitHub pull request"),
        ("\\bget\\s+get\\s+up\\b", "GitHub"),
        ("\\bget\\s+come\\s+it\\b", "git commit"),
        ("\\bget\\s+come\\b", "git commit"),
        ("\\bget\\s+check\\s+out\\b", "git checkout"),
        ("\\bget\\s+pool\\b", "git pull"),
        ("\\bget\\s+push\\b", "git push"),
        ("\\bget\\s+bush\\b", "git push"),
        ("\\bgate\\s+pool\\b", "git pull"),
        ("\\bgate\\s+push\\b", "git push"),
        ("\\bfor\\s+request\\b", "pull request"),
        ("\\bshift\\s+rested\\s+fbi\\s+in\\s+point\\s+jason\\s+yarmouth\\b", "Swift REST API endpoint JSON YAML"),
        ("\\bgo\\s+rush\\b", "Go Rust"),
        ("\\bicd\\s+built\\s+pipe\\b", "CI/CD build pipeline"),
        ("\\bin\\s+point\\b", "endpoint"),
        ("\\bjason\\b", "JSON"),
        ("\\byarmouth\\b", "YAML"),
        ("\\bopen\\s*ai\\b", "OpenAI"),
        ("\\b(git\\s*hub|get\\s*hub)\\b", "GitHub"),
        ("\\bget\\s+commit\\b", "git commit"),
        ("\\b(pool\\s+request)\\b", "pull request"),
        ("\\b(c\\s*plus\\s*plus|see\\s*plus\\s*plus)\\b", "C++"),
        ("\\b(c\\s*sharp)\\b", "C#"),
        ("\\b(node\\s*(dot\\s*)?js)\\b", "Node.js"),
        ("\\b(react\\s*(dot\\s*)?js)\\b", "React"),
        ("\\b(next\\s*(dot\\s*)?js)\\b", "Next.js"),
        ("\\b(type\\s*script)\\b", "TypeScript"),
        ("\\b(java\\s*script)\\b", "JavaScript"),
        ("\\b(post\\s*gres\\s*ql|postgresql|postgres)\\b", "PostgreSQL"),
        ("\\b(my\\s*sql)\\b", "MySQL"),
        ("\\b(sql\\s*light)\\b", "SQLite"),
        ("\\b(red\\s*is)\\b", "Redis"),
        ("\\b(kubernetees|kuberneties|kubernetes)\\b", "Kubernetes"),
        ("\\b(ci\\s*cd)\\b", "CI/CD"),
        ("\\b(rest\\s*api)\\b", "REST API"),
        ("\\b(graph\\s*ql|graphql)\\b", "GraphQL"),
        ("\\b(api)\\b", "API"),
        ("\\b(json)\\b", "JSON"),
        ("\\b(yaml)\\b", "YAML"),
        ("\\b(async\\s*await)\\b", "async/await"),
        ("\\b(v\\s*s\\s*code|vs\\s*code)\\b", "VS Code"),
        ("\\b(ex\\s*code|x\\s*code)\\b", "Xcode"),
        ("\\b(dot\\s*net)\\b", ".NET")
    ]

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
        output = normalizeTechnicalTerms(in: output)
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

    private static func normalizeTechnicalTerms(in text: String) -> String {
        var normalized = text
        for correction in technicalTermCorrections {
            normalized = replace(pattern: correction.pattern, in: normalized, with: correction.replacement)
        }
        return normalized
    }
}

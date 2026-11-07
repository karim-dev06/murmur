import Foundation

/// Tech words that speech recognition gets wrong, and the fixes for them.
///
/// The list comes from recordings: five voices (Indian, American and British English) read
/// sixty sentences of developer talk, and every mistake Apple's engine made more than by chance
/// became a rule. Each rule says how sure it is, so "I play the guitar" stays as it is
/// while "share the guitar link with the repo" becomes GitHub.
enum TechWords {
    enum Need {
        /// The misheard form is not normal English, so it is always fixed.
        case always
        /// Fixed only when the sentence is about software.
        case tech
        /// Fixed only when the sentence is about git: repos, commits, branches.
        case git
    }

    struct Rule {
        let pattern: String
        let replacement: String
        let need: Need
    }

    private static func r(_ pattern: String, _ replacement: String, _ need: Need = .always) -> Rule {
        Rule(pattern: pattern, replacement: replacement, need: need)
    }

    static let gitSentence = #"\b(git|github|repos?|commits?|push(ed)?|pull requests?|branch(es)?|merge|rebase|clone|readme|fork|stash|checkout)\b"#

    /// Words that only come up when talking about software. Everyday words like "app",
    /// "test" or "data" are left out on purpose: they would make "I paid cash for the app" a tech sentence.
    static let techSentence = #"\b(git|github|repos?|commits?|code|coding|codebase|api|apis|servers?|deploy(ed|ing|ment)?|database|frontend|backend|npm|json|sdk|cli|endpoints?|terminal|localhost|staging|xcode|ios|android|docker|kubernetes|aws|vercel|supabase|firebase|postgres|redis|typescript|javascript|python|swift|swiftui|react|css|html|sql|components?|quer(y|ies)|webhooks?|figma|stripe|revenuecat|posthog|sentry|bundle|framework|librar(y|ies)|dependenc(y|ies)|variables?|functions?|scripts?|branch|merge|bugs?|debug|refactor|compile|regex|cache|oauth|env|config|ui|ux|cursor|expo|graphql|testflight|kotlin|gradle|tailwind|next\.js|node\.js|pull request)\b"#

    /// Misheard words and phrases, most specific first.
    static let mishearings: [Rule] = [
        // Phrases that are never normal English.
        r(#"\b(pool|poll|full) requests?\b"#, "pull request"),
        r(#"\bco[- ]?others?\b"#, "co-author"),
        r(#"\bread ?me (file|fire)s?\b"#, "README file"),
        r(#"\b(the|this|that|a|our|your|my) read ?me\b"#, "$1 README"),
        r(#"\bREADME (of the |the )?fire\b"#, "README file"),
        r(#"\b(to|on|in|via|through|from) test ?flight\b"#, "$1 TestFlight"),
        r(#"\btestflight\b"#, "TestFlight"),
        r(#"\breact native\b"#, "React Native"),
        r(#"\brevenue ?(cat|cad)\b"#, "RevenueCat"),
        r(#"\bgraph (ql|duel)\b"#, "GraphQL"),
        r(#"\bnext ?\.? ?js\b"#, "Next.js"),
        r(#"\bpost (hog|hob)\b"#, "PostHog"),
        r(#"\blaunch darkly\b"#, "LaunchDarkly"),
        r(#"\bcloud front\b"#, "CloudFront"),
        r(#"\bweb ?hooks?\b"#, "webhook"),
        r(#"\bwebbooks?\b"#, "webhook"),
        r(#"\bsuperbase\b"#, "Supabase"),
        r(#"\b5 base\b"#, "Firebase"),
        r(#"\btype ?script\b"#, "TypeScript"),
        r(#"\bjava ?script\b"#, "JavaScript"),
        r(#"\bchat ?gpt\b"#, "ChatGPT"),
        r(#"\bopen ?ai\b"#, "OpenAI"),
        r(#"\blocalhost\b"#, "localhost"),
        r(#"\b(on|to|at|from) local host\b"#, "$1 localhost"),
        r(#"\blo(c|ck|ch)el?h(u|e)r?st\b"#, "localhost"),
        r(#"\bwhisper ?flow\b"#, "Wispr Flow"),
        r(#"\bjso in\b"#, "JSON"),
        r(#"\bpackage ?(\.|dot) ?(json|bison|gen)\b"#, "package.json"),
        r(#"\basync ?await\b"#, "async/await"),
        r(#"\bhdml\b"#, "HTML"),
        r(#"\b(chron|kron|crown) ?job\b"#, "cron job"),
        r(#"\bkronjob\b"#, "cron job"),
        r(#"\b(kubernates|kubonets|cubanets|kubernets)\b"#, "Kubernetes"),
        r(#"\b(cortlin|cutlin|codlin)\b"#, "Kotlin"),
        r(#"\b(ridis|rhadis)\b"#, "Redis"),
        r(#"\b(postcurs|postingers|post ?guz)\b"#, "Postgres"),
        r(#"\b(versel|versal)\b"#, "Vercel"),
        r(#"\b(jithub|git hub|get hub)\b"#, "GitHub"),
        r(#"\b(dsdk|bsdk)\b"#, "SDK"),
        r(#"\bhearts app\b"#, "WhatsApp"),
        r(#"\bversus code\b"#, "VS Code"),
        r(#"\bemerge conflicts?\b"#, "merge conflict"),
        r(#"\bfing me\b"#, "ping me"),
        r(#"\brun devon\b"#, "run dev on"),
        r(#"\bnnpm\b"#, "npm"),

        // Fine as English, so only fixed in a sentence about software.
        r(#"\blocal host\b"#, "localhost", .tech),
        r(#"\bsuper base\b"#, "Supabase", .tech),
        r(#"\bfire base\b"#, "Firebase", .tech),
        r(#"\bfront ?end\b"#, "frontend", .tech),
        r(#"\bback ?end\b"#, "backend", .tech),
        r(#"\bcash\b(?= (the |this |that )?(response|responses|results|layer|keys?|hits?|miss|misses|invalidation|images|query|queries|requests?|headers))"#, "cache", .tech),
        r(#"\brejects\b(?= (didn't|doesn't|does|did|is|to|for|that|pattern|match))"#, "regex", .tech),
        r(#"\bvessel\b"#, "Vercel", .tech),
        r(#"\bposters\b"#, "Postgres", .tech),
        r(#"\bsigma\b"#, "Figma", .tech),
        r(#"\bstrike\b(?= (for|payments?|checkout|api|webhook))"#, "Stripe", .tech),
        r(#"\b(avi|ati)\b"#, "API", .tech),
        r(#"\bcradle\b"#, "Gradle", .tech),
        r(#"\bgson\b"#, "JSON", .tech),
        r(#"\btail ?win(d)?\b"#, "Tailwind", .tech),
        r(#"\b(chatgpt|gpt|gemini) or cloud\b"#, "$1 or Claude", .tech),
        r(#"\bsentries\b"#, "Sentry", .tech),
        r(#"\breactant\b"#, "React and", .tech),

        // Fine as English, so only fixed in a sentence about git.
        r(#"\b(get|gate|gid|gift) (history|log|status|states|diff|commit|push|pull|clone|rebase|stash|checkout|init)\b"#, "git $2", .git),
        r(#"\bguitar\b"#, "GitHub", .git),
        r(#"\breport(s?)\b"#, "repo$1", .git),
        r(#"\bmaine\b"#, "main", .git),
        r(#"\b(clown|flown) the repo\b"#, "clone the repo", .git),
    ]

    /// Names and terms that recognition writes in the wrong case ("github", "Json").
    /// Only words that are not ordinary English, so fixing their case is always safe.
    static let spellings: [String] = [
        "GitHub", "GitLab", "README", "JavaScript", "TypeScript", "GraphQL", "PostgreSQL", "Postgres",
        "Supabase", "Firebase", "Vercel", "Netlify", "Kubernetes", "Xcode", "SwiftUI", "UIKit", "TestFlight",
        "ChatGPT", "OpenAI", "PostHog", "RevenueCat", "LaunchDarkly", "CloudFront", "Redis", "Kotlin",
        "npm", "JSON", "API", "APIs", "SDK", "CLI", "URL", "URLs", "HTML", "CSS", "SQL", "JWT", "OAuth",
        "iOS", "iPadOS", "macOS", "iPhone", "iPad", "localhost", "webhook", "Figma", "WhatsApp", "LinkedIn",
        "YouTube", "MongoDB", "MySQL", "SQLite", "Dockerfile", "DevOps", "CI/CD", "VS Code", "Claude Code",
        "Next.js", "Node.js", "Vue.js", "Nuxt", "Webpack", "ESLint", "pnpm",
    ]

    /// Fixes every rule that applies to one sentence.
    static func fix(sentence: String) -> String {
        var s = sentence
        for rule in mishearings where rule.need == .always {
            s = s.replacingOccurrences(of: rule.pattern, with: rule.replacement, options: [.regularExpression, .caseInsensitive])
        }
        // Judged after the always-safe fixes, so "revenue cat" counts as tech once it reads RevenueCat.
        let isTech = s.range(of: techSentence, options: [.regularExpression, .caseInsensitive]) != nil
        let isGit = s.range(of: gitSentence, options: [.regularExpression, .caseInsensitive]) != nil
        for rule in mishearings where rule.need != .always {
            guard rule.need == .tech ? isTech : isGit else { continue }
            s = s.replacingOccurrences(of: rule.pattern, with: rule.replacement, options: [.regularExpression, .caseInsensitive])
        }
        for word in spellings {
            let pattern = "(?<![\\w.])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\w])"
            s = s.replacingOccurrences(of: pattern, with: word, options: [.regularExpression, .caseInsensitive])
        }
        return s
    }
}

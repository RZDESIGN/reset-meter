import Foundation

/// Plan labels come strictly from provider-reported account metadata, never from usage percentages.
public enum AccountPlan {
    public static func codex(_ value: String?) -> String? {
        guard var normalized = normalizedToken(value) else { return nil }
        for prefix in ["self_serve_", "chatgpt_"] where normalized.hasPrefix(prefix) {
            normalized = String(normalized.dropFirst(prefix.count))
        }
        normalized = normalized.replacingOccurrences(of: "prolite", with: "pro_lite")
        return label(normalized)
    }

    public static func claude(_ value: String?, rateLimitTier: String? = nil) -> String? {
        guard var type = normalizedToken(value) else { return nil }
        if type.hasPrefix("claude_") {
            type = String(type.dropFirst(7))
        }
        guard ["free", "pro", "max", "team", "enterprise"].contains(type) else { return nil }
        if type == "max" {
            switch rateLimitTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "default_claude_max_5x": return "Max 5×"
            case "default_claude_max_20x": return "Max 20×"
            default: return "Max"
            }
        }
        return label(type)
    }

    public static func antigravity(tierName: String?, planName: String?) -> String? {
        if let tier = sanitizedDisplay(tierName) {
            return tier
        }
        return label(planName)
    }

    public static func cursor(_ value: String?) -> String? {
        guard let token = normalizedToken(value) else { return nil }
        switch token {
        case "free_trial": return "Trial"
        case "pro_plus", "pro+": return "Pro+"
        default: return label(token)
        }
    }

    private static func normalizedToken(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty,
              !["unknown", "null", "none"].contains(trimmed) else { return nil }
        return trimmed
    }

    private static func sanitizedDisplay(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !["unknown", "null", "none"].contains(trimmed.lowercased()) else { return nil }
        return trimmed
    }

    private static func label(_ value: String?) -> String? {
        guard let token = normalizedToken(value) else { return nil }
        switch token {
        case "api", "apikey", "api_key": return "API"
        case "edu": return "Edu"
        case "ai": return "AI"
        default:
            return token
                .split(separator: "_")
                .map { word -> String in
                    switch word {
                    case "ai": return "AI"
                    case "api": return "API"
                    default: return word.capitalized
                    }
                }
                .joined(separator: " ")
        }
    }
}

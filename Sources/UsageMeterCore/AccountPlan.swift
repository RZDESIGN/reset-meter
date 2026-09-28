import Foundation

/// Plan labels come from account metadata, never from usage percentages.
public enum AccountPlan {
    public static func codex(_ value: String?) -> String? {
        label(value)
    }

    public static func claude(_ value: String?, rateLimitTier: String? = nil) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = normalized?.hasPrefix("claude_") == true ? normalized.map { String($0.dropFirst(7)) } : normalized
        // Organization types also include non-subscription organizations.
        guard let type, ["free", "pro", "max", "team", "enterprise"].contains(type) else { return nil }
        if type == "max" {
            switch rateLimitTier {
            case "default_claude_max_5x": return "Max 5×"
            case "default_claude_max_20x": return "Max 20×"
            default: return "Max"
            }
        }
        return label(type)
    }

    private static func label(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !["unknown", "null", "none"].contains(value.lowercased()) else { return nil }
        switch value.lowercased() {
        case "api", "apikey", "api_key": return "API"
        case "edu": return "Edu"
        default: return value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

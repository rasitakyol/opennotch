import Foundation

/// Compact, space-conscious text for the notch.
public enum UsageFormat {
    /// Whole percent, so a barely touched limit reads "0%" rather than "<1%".
    public static func percent(_ value: Double) -> String {
        "\(wholePercent(value))%"
    }

    public static func wholePercent(_ value: Double) -> Int {
        Int(min(max(value, 0), 100).rounded())
    }

    /// Compact duration: "4h 48m", "1d 6h", "22d", "12m".
    public static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days >= 3 { return "\(days)d" }
        if days >= 1 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours >= 1 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(max(minutes, 1))m"
    }

    /// Short countdown for the metric caption.
    public static func countdown(to date: Date, now: Date = Date()) -> String {
        date.timeIntervalSince(now) <= 0 ? "now" : duration(date.timeIntervalSince(now))
    }

    /// Full sentence for tooltips.
    public static func resetSentence(_ date: Date, now: Date = Date()) -> String {
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 { return "This limit has reset; it updates on the next refresh." }
        return "Resets in \(spokenDuration(remaining)) · \(absolute(date, now: now))"
    }

    /// "Sat 04:59" within a week, otherwise "Oct 18, 14:00". English names, the user's 12/24-hour preference.
    public static func absolute(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = displayLocale
        let withinWeek = date.timeIntervalSince(now) < 6 * 86_400
        formatter.setLocalizedDateFormatFromTemplate(withinWeek ? "EEE jmm" : "MMM d jmm")
        return formatter.string(from: date)
    }

    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        if seconds < 3_600 { return "\(max(1, Int((seconds / 60).rounded())))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    /// Unabbreviated duration for tooltips and VoiceOver: "4 hours 48 minutes".
    public static func spokenDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        var parts: [String] = []
        if days > 0 { parts.append(plural(days, "day")) }
        if hours > 0 && days < 3 { parts.append(plural(hours, "hour")) }
        if minutes > 0 && days == 0 { parts.append(plural(minutes, "minute")) }
        return parts.isEmpty ? "less than a minute" : parts.joined(separator: " ")
    }

    /// "$19.27" — trailing zeros trimmed ("$20").
    public static func dollars(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return "$\(Int(rounded))" }
        return String(format: "$%.2f", rounded)
    }

    /// One decimal for small values, whole numbers from 100 up ("7.5", "475") to keep captions short.
    public static func number(_ value: Double) -> String {
        if abs(value) >= 100 { return "\(Int(value.rounded()))" }
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded))" }
        return String(format: "%.1f", rounded)
    }

    private static func plural(_ count: Int, _ unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s")"
    }

    /// English text with the user's regional conventions (e.g. 24-hour clock outside the US).
    private static var displayLocale: Locale {
        Locale(identifier: "en_\(Locale.current.region?.identifier ?? "US")")
    }
}

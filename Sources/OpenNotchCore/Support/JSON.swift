import Foundation

/// Forgiving read-only view over decoded JSON.
///
/// The usage endpoints are undocumented and change shape over time (numbers arrive as strings,
/// proto3 JSON omits zero values, fields come and go), so providers navigate them leniently
/// instead of decoding into strict `Codable` types that would fail as a whole.
///
/// `@unchecked Sendable`: the wrapped value is an immutable Foundation object graph produced by
/// `JSONSerialization` and is never mutated after decoding.
public struct JSON: @unchecked Sendable {
    public let raw: Any?

    public init(_ raw: Any?) {
        self.raw = raw is NSNull ? nil : raw
    }

    public init(data: Data) throws {
        self.init(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    public init(string: String) throws {
        try self.init(data: Data(string.utf8))
    }

    public subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    public subscript(index: Int) -> JSON {
        guard let array = raw as? [Any], array.indices.contains(index) else { return JSON(nil) }
        return JSON(array[index])
    }

    public var isNull: Bool { raw == nil }

    public var array: [JSON] {
        (raw as? [Any])?.map(JSON.init) ?? []
    }

    public var dictionary: [String: JSON] {
        (raw as? [String: Any])?.mapValues(JSON.init) ?? [:]
    }

    public var string: String? {
        if let string = raw as? String { return string }
        if let number = raw as? NSNumber, !number.isBoolean { return number.stringValue }
        return nil
    }

    /// Numbers, including int64 values that proto3 JSON encodes as strings.
    public var double: Double? {
        if let number = raw as? NSNumber, !number.isBoolean { return number.doubleValue }
        if let string = raw as? String { return Double(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    public var bool: Bool? {
        if let number = raw as? NSNumber { return number.boolValue }
        if let string = raw as? String {
            switch string.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }
}

private extension NSNumber {
    var isBoolean: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
}

public enum ISODate {
    /// Parses ISO-8601 timestamps with any number of fractional digits ("…:59.570238+00:00", "…:00.623Z", "…:00Z").
    public static func parse(_ value: String?) -> Date? {
        guard var text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let dot = text.firstIndex(of: "."),
           let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "z" || $0 == "+" || $0 == "-" }) {
            let fraction = String((String(text[text.index(after: dot)..<zone]) + "000").prefix(3))
            text = String(text[..<dot]) + "." + fraction + String(text[zone...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Unix timestamps in seconds or milliseconds.
    public static func fromUnix(_ value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }
}

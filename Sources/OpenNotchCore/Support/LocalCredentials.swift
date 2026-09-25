import Foundation
import SQLite3

/// Helpers for reading credentials that other tools already keep on this Mac.
/// Everything here is read-only: OpenNotch never writes, refreshes or copies a token.
public enum LocalFiles {
    public static var home: String { NSHomeDirectory() }

    public static func path(_ components: String...) -> String {
        ([home] + components).joined(separator: "/")
    }

    public static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public static func data(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    public static func json(_ path: String) -> JSON? {
        data(path).flatMap { try? JSON(data: $0) }
    }
}

enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
    }

    private final class Buffer: @unchecked Sendable {
        var data = Data()
    }

    /// Runs a short-lived tool off the cooperative pool and returns its stdout.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) async -> Output? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(executable, arguments, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Drain stdout concurrently so a large payload can never fill the pipe and stall the child.
        let buffer = Buffer()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            buffer.data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        if drained.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: buffer.data)
    }
}

public enum Keychain {
    private static let tool = "/usr/bin/security"

    /// Reads a generic password through `security`, which the owning tools (e.g. Claude Code) use to create
    /// their items. Reusing it keeps the item's existing access list, so no extra keychain prompt appears.
    public static func genericPassword(service: String) async -> String? {
        guard let output = await ProcessRunner.run(tool, ["find-generic-password", "-s", service, "-w"]),
              output.status == 0,
              let text = String(data: output.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    /// Checks that an item exists without reading its secret.
    public static func hasGenericPassword(service: String) async -> Bool {
        await ProcessRunner.run(tool, ["find-generic-password", "-s", service])?.status == 0
    }
}

/// Reads VS Code–style `state.vscdb` key/value stores (Cursor, Devin Desktop) without disturbing the owning app.
public enum SQLiteKV {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public static func value(forKey key: String, databaseAt path: String) -> String? {
        guard LocalFiles.exists(path) else { return nil }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        // Plain read-only first; if the owner holds a write lock, fall back to an immutable snapshot read.
        return query(key, uri: "file:\(encoded)?mode=ro") ?? query(key, uri: "file:\(encoded)?mode=ro&immutable=1")
    }

    private static func query(_ key: String, uri: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
}

public enum JWT {
    public static func claims(_ token: String) -> JSON? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSON(data: data)
    }

    public static func expiry(_ token: String) -> Date? {
        claims(token)?["exp"].double.map { Date(timeIntervalSince1970: $0) }
    }

    /// True only when the token carries an expiry that has already passed (with a small safety margin).
    public static func isExpired(_ token: String, now: Date = Date()) -> Bool {
        guard let expiry = expiry(token) else { return false }
        return expiry <= now.addingTimeInterval(30)
    }
}

/// Just enough TOML for flat `key = "value"` credential files.
public enum SimpleTOML {
    public static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break } // only top-level keys are needed
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }
}

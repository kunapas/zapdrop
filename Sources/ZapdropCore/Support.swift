import Foundation

/// Minimal lock-protected value (works on macOS 14 and Linux; `Mutex` needs macOS 15).
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    public init(_ value: Value) { self.value = value }
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
    public var current: Value { withLock { $0 } }
}

/// Thread-safe cancellation flag shared between async code and blocking device callbacks.
public final class CancellationFlag: @unchecked Sendable {
    private let state = Locked(false)
    public init() {}
    public func cancel() { state.withLock { $0 = true } }
    public var isCancelled: Bool { state.current }
}

// MARK: - Logging

public enum LogLevel: Int, Sendable, Comparable {
    case debug, info, warning, error
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Logging sink. Messages never leave the Mac. File names must be passed as `privateValue` so production
/// builds can redact them.
public protocol ApplicationLogger: Sendable {
    func log(_ level: LogLevel, _ category: String, _ message: String, privateValue: String?)
}

public struct ConsoleLogger: ApplicationLogger {
    public var minimumLevel: LogLevel
    public var redactPrivate: Bool
    public init(minimumLevel: LogLevel = .info, redactPrivate: Bool = true) {
        self.minimumLevel = minimumLevel
        self.redactPrivate = redactPrivate
    }
    public func log(_ level: LogLevel, _ category: String, _ message: String, privateValue: String?) {
        guard level >= minimumLevel else { return }
        let p = privateValue.map { redactPrivate ? " <private>" : " \($0)" } ?? ""
        FileHandle.standardError.write(Data("[Zapdrop][\(category)] \(message)\(p)\n".utf8))
    }
}

public enum Log {
    private static let current = Locked<any ApplicationLogger>(ConsoleLogger(minimumLevel: .warning))
    public static func install(_ logger: any ApplicationLogger) { current.withLock { $0 = logger } }
    public static func debug(_ c: String, _ m: String, _ p: String? = nil) { current.current.log(.debug, c, m, privateValue: p) }
    public static func info(_ c: String, _ m: String, _ p: String? = nil) { current.current.log(.info, c, m, privateValue: p) }
    public static func warning(_ c: String, _ m: String, _ p: String? = nil) { current.current.log(.warning, c, m, privateValue: p) }
    public static func error(_ c: String, _ m: String, _ p: String? = nil) { current.current.log(.error, c, m, privateValue: p) }
}

// MARK: - Byte formatting and progress maths

/// Deterministic, locale-independent byte formatting (decimal units, like Finder).
public enum ByteFormatter {
    public static func string(_ bytes: UInt64) -> String {
        if bytes < 1000 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        let units = ["KB", "MB", "GB", "TB", "PB", "EB"]
        var value = Double(bytes)
        var index = -1
        while value >= 1000, index < units.count - 1 { value /= 1000; index += 1 }
        let rounded = value < 10 ? (value * 10).rounded() / 10 : value.rounded()
        if rounded >= 1000, index < units.count - 1 { return "1 \(units[index + 1])" }
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "\(text) \(units[index])"
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return string(UInt64(min(bytesPerSecond, Double(UInt64.max / 2)))) + "/s"
    }

    public static func duration(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s >= 0 else { return "Calculating…" }
        let total = Int(s.rounded(.up))
        if total < 60 { return total <= 1 ? "About a second" : "About \(total) seconds" }
        let minutes = total / 60, hours = minutes / 60
        if hours == 0 { return minutes == 1 ? "About a minute" : "About \(minutes) minutes" }
        let m = minutes % 60
        return m == 0 ? "About \(hours) h" : "About \(hours) h \(m) min"
    }
}

public enum ProgressMath {
    /// Fraction in 0...1 without overflow for any 64-bit values.
    public static func fraction(done: UInt64, total: UInt64) -> Double {
        guard total > 0 else { return done > 0 ? 1 : 0 }
        if done >= total { return 1 }
        return Double(done) / Double(total)
    }

    /// Saturating addition for byte counters.
    public static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (r, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : r
    }

    public static func remaining(done: UInt64, total: UInt64) -> UInt64 { total > done ? total - done : 0 }
}

/// Smoothed transfer speed. Feed it cumulative byte counts with timestamps.
public struct SpeedEstimator: Sendable {
    public private(set) var bytesPerSecond: Double = 0
    private var lastBytes: UInt64?
    private var lastTime: Double?
    private let smoothing: Double
    private let minimumInterval: Double

    public init(smoothing: Double = 0.3, minimumInterval: Double = 0.25) {
        self.smoothing = smoothing
        self.minimumInterval = minimumInterval
    }

    public mutating func record(totalBytes: UInt64, at time: Double) {
        guard let lb = lastBytes, let lt = lastTime else {
            lastBytes = totalBytes; lastTime = time; return
        }
        let dt = time - lt
        guard dt >= minimumInterval else { return }
        let delta = totalBytes >= lb ? Double(totalBytes - lb) : 0
        let instant = delta / dt
        bytesPerSecond = bytesPerSecond == 0 ? instant : smoothing * instant + (1 - smoothing) * bytesPerSecond
        lastBytes = totalBytes; lastTime = time
    }

    /// Resets the time base (e.g. after a pause) without forgetting the smoothed speed.
    public mutating func rebase() { lastBytes = nil; lastTime = nil }

    public func secondsRemaining(remainingBytes: UInt64) -> Double? {
        guard bytesPerSecond > 1 else { return nil }
        return Double(remainingBytes) / bytesPerSecond
    }
}

/// Monotonic clock in seconds, injectable for tests.
public protocol TimeSource: Sendable { func now() -> Double }
public struct MonotonicClock: TimeSource {
    public init() {}
    public func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}

import Foundation

public enum Formatters {
    /// Decimal bytes, the way drive makers and Finder count: 1 TB = 10^12 bytes.
    public static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var v = max(0, value)
        var i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return "\(Int(v)) B" }
        return "\(trim(v, digits: v >= 100 ? 0 : (v >= 10 ? 1 : 2))) \(units[i])"
    }

    public static func bytes(_ value: Int64) -> String { bytes(Double(value)) }

    /// MB/s with CrystalDiskMark-style precision (decimal megabytes).
    public static func throughput(_ bytesPerSecond: Double) -> String {
        let mb = bytesPerSecond / 1_000_000
        return String(format: mb >= 1000 ? "%.0f" : "%.2f", mb)
    }

    public static func iops(_ value: Double) -> String {
        value >= 10_000 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    public static func latency(_ microseconds: Double) -> String {
        microseconds >= 1000 ? String(format: "%.2f ms", microseconds / 1000) : String(format: "%.0f µs", microseconds)
    }

    /// "172 days, 4 h" style, the way people think about a drive's age.
    public static func powerOnTime(hours: Double) -> String {
        let h = Int(hours)
        if h < 48 { return "\(h) h" }
        let days = h / 24
        if days < 365 { return "\(days) days" }
        let years = trim(Double(days) / 365.25, digits: 1)
        return years == "1" ? "1 year" : "\(years) years"
    }

    public static func count(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }

    public static func trim(_ value: Double, digits: Int = 2) -> String {
        var s = String(format: "%.\(digits)f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}

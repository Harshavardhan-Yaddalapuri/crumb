import Foundation

/// How many bites Crumb takes to eat a file: round(1 + 2 × log10(sizeMB + 1)), clamped to 1…10.
public func biteCount(bytes: Int64) -> Int {
    let mb = Double(bytes) / 1_000_000
    return min(10, max(3, Int((1 + 2 * log10(mb + 1)).rounded())))
}

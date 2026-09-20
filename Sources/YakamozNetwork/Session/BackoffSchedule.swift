import Foundation

/// A pure exponential-backoff schedule with a cap and deterministic jitter.
///
/// Delays are computed from an attempt number (1-based) with no wall clock and
/// no RNG state, so tests are deterministic across runs. Jitter is derived from
/// a stable hash of `(attempt, seed)`, which spreads reconnect storms across
/// clients that share a schedule while remaining reproducible for a fixed seed.
public struct BackoffSchedule: Sendable, Equatable {
    /// The first-attempt delay, in seconds.
    public let base: TimeInterval
    /// The multiplier applied per attempt.
    public let factor: Double
    /// The maximum delay, in seconds, before jitter is applied.
    public let cap: TimeInterval
    /// Jitter fraction in `0...1`; `0` disables jitter. Applied as a symmetric
    /// multiplier in `1-jitter ... 1+jitter`.
    public let jitter: Double
    /// Seed for deterministic jitter.
    public let seed: UInt64

    public init(
        base: TimeInterval = 0.5,
        factor: Double = 2.0,
        cap: TimeInterval = 30.0,
        jitter: Double = 0.2,
        seed: UInt64 = 0
    ) {
        self.base = base
        self.factor = factor
        self.cap = cap
        self.jitter = max(0, min(1, jitter))
        self.seed = seed
    }

    /// The delay, in seconds, before the given 1-based attempt. Attempts below 1
    /// are treated as attempt 1.
    public func delaySeconds(forAttempt attempt: Int) -> TimeInterval {
        let clampedAttempt = max(1, attempt)
        let exponent = clampedAttempt - 1
        let raw = base * pow(factor, Double(exponent))
        let capped = min(raw, cap)
        guard jitter > 0 else { return capped }
        let unit = Self.unitJitter(attempt: clampedAttempt, seed: seed)
        let multiplier = 1 + jitter * (2 * unit - 1)
        return capped * multiplier
    }

    /// The delay, in seconds, before the given 1-based attempt as a `Duration`.
    public func delay(forAttempt attempt: Int) -> Duration {
        .seconds(delaySeconds(forAttempt: attempt))
    }

    /// A deterministic value in `0..<1` derived from the attempt and seed.
    private static func unitJitter(attempt: Int, seed: UInt64) -> Double {
        var value = UInt64(bitPattern: Int64(attempt)) &* 0x9E37_79B9_7F4A_7C15
        value &+= seed
        value ^= value >> 30
        value &*= 0xBF58_476D_1CE4_E5B9
        value ^= value >> 27
        value &*= 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value % 10_000) / 10_000.0
    }
}

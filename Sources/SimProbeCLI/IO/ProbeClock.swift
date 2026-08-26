import Foundation

/// The passage of time, injectable so a poll loop can be asserted without waiting for it.
///
/// Named `ProbeClock` rather than `Clock` because `Swift.Clock` is in scope everywhere the
/// standard library is, and a same-named protocol turns every mention into an ambiguity.
public protocol ProbeClock {

    /// A monotonic millisecond counter. Only differences between two readings are meaningful.
    var nowMs: Int { get }

    func sleep(ms: Int)
}

/// The real clock: monotonic uptime, and a blocking sleep.
///
/// Uptime rather than wall time so that an NTP correction mid-poll cannot make a screen appear
/// to have settled before the watch began.
public struct SystemClock: ProbeClock {

    public init() {}

    public var nowMs: Int {
        Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    public func sleep(ms: Int) {
        guard ms > 0 else { return }
        Thread.sleep(forTimeInterval: Double(ms) / 1_000)
    }
}

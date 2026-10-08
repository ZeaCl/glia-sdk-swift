import Foundation

/// Manages offline FIFO buffering, repeated error suppression (Circuit Breaker),
/// and thread-safe sequence incrementing for mobile telemetry.
public actor TelemetryManager {
    public static let defaultMaxBufferSize: Int = 50
    public static let defaultCircuitBreakerWindow: TimeInterval = 60.0

    private let maxBufferSize: Int
    private let circuitBreakerWindow: TimeInterval
    private var sequenceNumber: Int = 0

    private var buffer: [TelemetryEvent] = []
    private var circuitBreakerRecords: [String: Date] = [:]

    public init(
        maxBufferSize: Int = defaultMaxBufferSize,
        circuitBreakerWindow: TimeInterval = defaultCircuitBreakerWindow
    ) {
        self.maxBufferSize = maxBufferSize
        self.circuitBreakerWindow = circuitBreakerWindow
    }

    /// Next sequence number for telemetry events.
    public func nextSequence() -> Int {
        sequenceNumber += 1
        return sequenceNumber
    }

    /// Evaluates whether an error with the given flow and code should be suppressed by the circuit breaker.
    /// Returns `true` if the error is suppressed (within 60s of previous occurrence), `false` if allowed.
    public func shouldSuppressError(flow: String, code: String?, now: Date = Date()) -> Bool {
        let key = "\(flow):\(code ?? "default")"

        // Purge expired records older than 2x circuit breaker window to avoid memory growth
        let cutoff = now.addingTimeInterval(-2 * circuitBreakerWindow)
        circuitBreakerRecords = circuitBreakerRecords.filter { $0.value > cutoff }

        if let lastTimestamp = circuitBreakerRecords[key] {
            if now.timeIntervalSince(lastTimestamp) < circuitBreakerWindow {
                return true
            }
        }

        circuitBreakerRecords[key] = now
        return false
    }

    /// Enqueues an event into the offline FIFO buffer.
    /// If capacity exceeds `maxBufferSize`, drops the oldest element.
    public func enqueue(_ event: TelemetryEvent) {
        if buffer.count >= maxBufferSize {
            _ = buffer.removeFirst()
        }
        buffer.append(event)
    }

    /// Flushes all enqueued telemetry events in FIFO order and empties the buffer.
    public func flush() -> [TelemetryEvent] {
        let events = buffer
        buffer.removeAll(keepingCapacity: true)
        return events
    }

    /// Current number of buffered events.
    public var bufferedCount: Int {
        buffer.count
    }

    /// Clears the buffer and circuit breaker records.
    public func clear() {
        buffer.removeAll()
        circuitBreakerRecords.removeAll()
    }
}

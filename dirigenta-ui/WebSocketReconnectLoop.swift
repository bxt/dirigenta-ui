import Foundation
import OSLog

/// Returns the reconnection delay (seconds) for attempt `n` (zero-indexed):
/// exponential backoff capped at 60 s with ±25 % random jitter, minimum 1 s.
/// Exposed as a free function so tests can verify bounds without going through
/// the full reconnect loop.
nonisolated func wsBackoffDelay(attempt: Int) -> Double {
    let base = min(pow(2.0, Double(attempt)), 60.0)
    let jitter = Double.random(in: -0.25 * base ... 0.25 * base)
    return max(1.0, base + jitter)
}

/// WebSocket reconnect loop, extracted from SwiftUI's `.task` modifier so it
/// can be unit-tested with an injectable event stream and sleep function.
///
/// - Parameters:
///   - maxRetries: Maximum *consecutive* failed connection attempts before giving up.
///   - eventStream: Factory called once per attempt; the returned stream is fully
///     consumed before the next attempt. An immediately-finished stream counts as
///     a dropped/failed connection.
///   - onConnecting: Called once before the first attempt and again before each
///     subsequent sleep-and-retry.
///   - onConnected: Called exactly once per connection, on the first received event.
///   - onEvent: Called for every received event.
///   - onDisconnected: Called once when the retry budget is exhausted.
///   - sleepFn: Injectable sleep; defaults to `Task.sleep`. Inject a no-op in tests.
@MainActor
func wsReconnectLoop(
    maxRetries: Int = 8,
    eventStream: () -> AsyncStream<DirigeraEvent>,
    onConnecting: () -> Void,
    onConnected: () -> Void,
    onEvent: (DirigeraEvent) -> Void,
    onDisconnected: () -> Void,
    sleepFn: ((Duration) async throws -> Void)? = nil
) async {
    let sleep = sleepFn ?? { try await Task.sleep(for: $0) }
    onConnecting()
    var attempt = 0
    while attempt <= maxRetries {
        if Task.isCancelled { break }
        var receivedAnyEvent = false
        for await event in eventStream() {
            if !receivedAnyEvent { onConnected() }
            receivedAnyEvent = true
            onEvent(event)
        }
        guard !Task.isCancelled else { break }
        // A connection that delivered at least one event was live — reset the
        // attempt counter before checking the limit so that a live-then-dropped
        // connection on the final attempt does not incorrectly exhaust the budget.
        if receivedAnyEvent { attempt = 0 }
        if attempt >= maxRetries {
            onDisconnected()
            break
        }
        onConnecting()
        let delay = wsBackoffDelay(attempt: attempt)
        Logger.webSocket.info(
            "Reconnecting in \(String(format: "%.1f", delay))s (attempt \(attempt + 1)/\(maxRetries))…"
        )
        try? await sleep(.seconds(delay))
        attempt += 1
    }
}

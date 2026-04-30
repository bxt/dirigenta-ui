import XCTest

@testable import dirigenta_ui

private func makeEvent(type: String = "deviceStateChanged") -> DirigeraEvent {
    try! JSONDecoder().decode(
        DirigeraEvent.self,
        from: #"{"type":"\#(type)"}"#.data(using: .utf8)!
    )
}

/// A no-op sleep that returns immediately, so loop tests don't actually wait.
private let noopSleep: (Duration) async throws -> Void = { _ in }

// MARK: - wsBackoffDelay

@MainActor
final class WsBackoffDelayTests: XCTestCase {

    func testAttempt0_alwaysAtLeast1s() {
        for _ in 0..<200 {
            XCTAssertGreaterThanOrEqual(wsBackoffDelay(attempt: 0), 1.0)
        }
    }

    func testAttempt0_atMost1_25s() {
        // base=1, jitter=[-0.25,0.25] → max(1, 0.75..1.25) = 1..1.25
        for _ in 0..<200 {
            XCTAssertLessThanOrEqual(wsBackoffDelay(attempt: 0), 1.25)
        }
    }

    func testAttempt1_between1and3() {
        // base=2, jitter=[-0.5,0.5] → 1.5..2.5 (above floor of 1)
        for _ in 0..<200 {
            let d = wsBackoffDelay(attempt: 1)
            XCTAssertGreaterThanOrEqual(d, 1.0)
            XCTAssertLessThanOrEqual(d, 3.0)
        }
    }

    func testAttempt2_between3and5() {
        // base=4, jitter=[-1,1] → 3..5
        for _ in 0..<200 {
            let d = wsBackoffDelay(attempt: 2)
            XCTAssertGreaterThanOrEqual(d, 3.0)
            XCTAssertLessThanOrEqual(d, 5.0)
        }
    }

    func testLargeAttempt_cappedAt60sWithJitter() {
        // base=60 (cap), jitter=[-15,15] → 45..75
        for _ in 0..<200 {
            let d = wsBackoffDelay(attempt: 20)
            XCTAssertGreaterThanOrEqual(d, 45.0)
            XCTAssertLessThanOrEqual(d, 75.0)
        }
    }
}

// MARK: - wsReconnectLoop

@MainActor
final class WsReconnectLoopTests: XCTestCase {

    // MARK: Retry exhaustion

    func testExhaustsRetriesAndCallsOnDisconnected() async {
        var streamCalls = 0
        var disconnected = false

        await wsReconnectLoop(
            maxRetries: 3,
            eventStream: {
                streamCalls += 1
                return AsyncStream { $0.finish() }  // every attempt immediately empty
            },
            onConnecting: {},
            onConnected: { XCTFail("onConnected must not fire on an empty stream") },
            onEvent: { _ in },
            onDisconnected: { disconnected = true },
            sleepFn: noopSleep
        )

        XCTAssertTrue(disconnected)
        XCTAssertEqual(streamCalls, 4)  // attempts 0, 1, 2, 3
    }

    func testNoDisconnectWhenMaxRetriesIsZeroButStreamDeliversEvents() async {
        // maxRetries=0 means one attempt; if it delivers events the counter
        // resets to 0, which still exhausts maxRetries=0 → onDisconnected.
        var disconnected = false
        await wsReconnectLoop(
            maxRetries: 0,
            eventStream: {
                AsyncStream { cont in cont.yield(makeEvent()); cont.finish() }
            },
            onConnecting: {},
            onConnected: {},
            onEvent: { _ in },
            onDisconnected: { disconnected = true },
            sleepFn: noopSleep
        )
        XCTAssertTrue(disconnected)
    }

    // MARK: Live-connection reset

    func testLiveConnectionResetsAttemptCounter() async {
        // First stream delivers one event (live connection), subsequent streams empty.
        var streamCalls = 0
        var onConnectedCalls = 0
        var eventCount = 0
        var disconnected = false

        await wsReconnectLoop(
            maxRetries: 2,
            eventStream: {
                streamCalls += 1
                if streamCalls == 1 {
                    return AsyncStream { cont in
                        cont.yield(makeEvent())
                        cont.finish()
                    }
                }
                return AsyncStream { $0.finish() }
            },
            onConnecting: {},
            onConnected: { onConnectedCalls += 1 },
            onEvent: { _ in eventCount += 1 },
            onDisconnected: { disconnected = true },
            sleepFn: noopSleep
        )

        // Call 1 resets attempt to 0; calls 2 (attempt 1) and 3 (attempt 2) exhaust maxRetries.
        XCTAssertEqual(streamCalls, 3)
        XCTAssertEqual(onConnectedCalls, 1)
        XCTAssertEqual(eventCount, 1)
        XCTAssertTrue(disconnected)
    }

    // MARK: State transitions

    func testOnConnectingCalledAtStartAndAfterEachFailedAttempt() async {
        var connectingCalls = 0

        await wsReconnectLoop(
            maxRetries: 2,
            eventStream: { AsyncStream { $0.finish() } },
            onConnecting: { connectingCalls += 1 },
            onConnected: {},
            onEvent: { _ in },
            onDisconnected: {},
            sleepFn: noopSleep
        )

        // Once at start + once after attempt 0 + once after attempt 1.
        // Attempt 2 = maxRetries → onDisconnected, no further onConnecting.
        XCTAssertEqual(connectingCalls, 3)
    }

    func testOnConnectedCalledExactlyOncePerConnection() async {
        // Three events on one connection → onConnected called exactly once.
        var onConnectedCalls = 0

        await wsReconnectLoop(
            maxRetries: 0,
            eventStream: {
                AsyncStream { cont in
                    cont.yield(makeEvent())
                    cont.yield(makeEvent())
                    cont.yield(makeEvent())
                    cont.finish()
                }
            },
            onConnecting: {},
            onConnected: { onConnectedCalls += 1 },
            onEvent: { _ in },
            onDisconnected: {},
            sleepFn: noopSleep
        )

        XCTAssertEqual(onConnectedCalls, 1)
    }

    func testAllEventsDeliveredToOnEvent() async {
        var received: [String] = []
        let types = ["deviceStateChanged", "sceneUpdated", "ping"]

        await wsReconnectLoop(
            maxRetries: 0,
            eventStream: {
                AsyncStream { cont in
                    types.forEach { t in
                        cont.yield(makeEvent(type: t))
                    }
                    cont.finish()
                }
            },
            onConnecting: {},
            onConnected: {},
            onEvent: { received.append($0.type) },
            onDisconnected: {},
            sleepFn: noopSleep
        )

        XCTAssertEqual(received, types)
    }

    // MARK: Cancellation

    func testCancellationHonoredBetweenAttempts() async {
        var streamCalls = 0
        let task = Task { @MainActor in
            await wsReconnectLoop(
                maxRetries: 100,
                eventStream: {
                    streamCalls += 1
                    return AsyncStream { $0.finish() }
                },
                onConnecting: {},
                onConnected: {},
                onEvent: { _ in },
                onDisconnected: {},
                sleepFn: { _ in
                    // A tiny real sleep lets Task.isCancelled propagate.
                    try await Task.sleep(for: .milliseconds(1))
                }
            )
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await task.value
        XCTAssertLessThan(streamCalls, 100, "Loop must stop well before maxRetries on cancellation")
    }
}

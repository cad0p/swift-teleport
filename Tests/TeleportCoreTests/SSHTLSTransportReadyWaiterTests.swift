// SPDX-License-Identifier: MIT
//
//  SSHTLSTransportReadyWaiterTests.swift
//  TeleportCoreTests
//
//  The #237 `ReadyWaiter` contract (host `2e533466`): the `NWConnection`
//  state handler must be armed BEFORE `connection.start(...)` and the first
//  terminal state must be buffered, because `NWConnection` does not replay
//  its current state to a handler assigned after the transition. A fast
//  `.ready` (the loopback TLS handshake completes in tens of milliseconds)
//  that lands between `start` and the wait attachment would otherwise leave
//  the wait suspended forever.
//
//  The ordering itself is not behaviourally reproducible deterministically —
//  the race only loses under host starvation — so it is pinned structurally:
//  `theConnectionArmsTheHandlerBeforeStart` reads the production file and
//  asserts the arm-before-start order, the `readyWaiter.wait()` call, and the
//  absence of the deleted `waitForReady`. The behavioural tests drive
//  `ReadyWaiter` directly and pin the buffering mechanism (a terminal state
//  that lands before `wait()` still resolves it).
//
//  Counterfactual hook: the package pins resolve the repository root from
//  `#filePath`; CF-A5 is measured by mutating the tree in place (arming the
//  handler after `start`), running the pin, and reverting.
//

#if canImport(Network)
import Foundation
import Network
import Testing
import os.log
@testable import TeleportCore

struct SSHTLSTransportReadyWaiterTests {

    private enum WaitOutcome: Sendable, Equatable {
        case resolved
        case failed(String)
        case timedOut
    }

    /// Resumes exactly once across the wait task and the timeout.
    private nonisolated final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        func fire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    /// A bounded `ReadyWaiter.wait()` so a regression that drops the buffered
    /// state reds as `.timedOut` instead of hanging the suite. The timeout
    /// resumes the test's continuation; the (leaked) wait task stays
    /// suspended.
    private func boundedWait(
        _ waiter: ReadyWaiter,
        timeout: TimeInterval = 5
    ) async -> WaitOutcome {
        let flag = OnceFlag()
        return await withCheckedContinuation { (continuation: CheckedContinuation<WaitOutcome, Never>) in
            let deliver: @Sendable (WaitOutcome) -> Void = { outcome in
                if flag.fire() {
                    continuation.resume(returning: outcome)
                }
            }
            Task {
                do {
                    try await waiter.wait()
                    deliver(.resolved)
                } catch {
                    deliver(.failed(String(describing: error)))
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                deliver(.timedOut)
            }
        }
    }

    private func makeWaiter() -> ReadyWaiter {
        ReadyWaiter(logger: Logger(subsystem: "swift-teleport.tests", category: "ReadyWaiter"))
    }

    /// The #237 regression shape: a fast `.ready` lands before `wait()`
    /// attaches. The buffer must resolve the wait immediately.
    @Test
    func fastReadyBeforeTheWaitIsBuffered() async {
        let waiter = makeWaiter()
        waiter.handle(.ready)
        #expect(await boundedWait(waiter) == .resolved)
    }

    /// The same for a terminal failure.
    @Test
    func failureBeforeTheWaitIsBuffered() async {
        let waiter = makeWaiter()
        waiter.handle(.failed(.posix(.ECONNREFUSED)))
        let outcome = await boundedWait(waiter)
        guard case .failed = outcome else {
            Issue.record("expected the buffered NWError failure, got \(outcome)")
            return
        }
    }

    /// The handler firing after the wait attaches resolves it too (the
    /// continuation is already installed).
    @Test
    func waitAttachedFirstResolvesWhenTheHandlerFires() async {
        let waiter = makeWaiter()
        let wait = Task { await boundedWait(waiter) }
        waiter.handle(.ready)
        #expect(await wait.value == .resolved)
    }

    /// The first terminal state wins; a later state is dropped.
    @Test
    func theFirstTerminalStateWinsAndLaterStatesAreDropped() async {
        let waiter = makeWaiter()
        waiter.handle(.ready)
        waiter.handle(.failed(.posix(.ECONNREFUSED)))
        #expect(await boundedWait(waiter) == .resolved)
    }

    // MARK: - The arm-before-start pin

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SSHTLSTransportReadyWaiterTests.swift
            .deletingLastPathComponent()  // TeleportCoreTests/
            .deletingLastPathComponent()  // Tests/
    }

    @Test
    func theConnectionArmsTheHandlerBeforeStart() throws {
        let text = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "Sources/TeleportCore/Infrastructure/SSHTLSTransport.swift"
            ),
            encoding: .utf8
        )

        let arm = try #require(
            text.range(of: "connection.stateUpdateHandler = { readyWaiter.handle($0) }"),
            "connect() must arm the state handler on the pre-armed ReadyWaiter — re-derive this pin (#237)"
        )
        let start = try #require(
            text.range(of: "connection.start(queue: .global(qos: .userInitiated))"),
            "connect() must start the NWConnection — re-derive this pin (#237)"
        )
        #expect(
            arm.lowerBound < start.lowerBound,
            "the state handler must be armed BEFORE connection.start(...): NWConnection does not replay a state a handler installed after the transition missed (host 2e533466, #237)"
        )
        #expect(
            text.contains("try await readyWaiter.wait()"),
            "connect() must wait through the pre-armed ReadyWaiter — re-derive this pin (#237)"
        )
        #expect(
            !text.contains("func waitForReady("),
            "the start-first waitForReady path must stay deleted (#237) — a handler installed after start can miss a fast .ready and hang the wait"
        )
    }
}

#endif // canImport(Network)

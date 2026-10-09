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
//  `theConnectionArmsTheHandlerBeforeStart` reads the production file
//  (comments stripped) and asserts the arm-before-start order, the
//  `readyWaiter.wait()` call, and the absence of the deleted `waitForReady`;
//  each anchor must occur exactly once, so an earlier duplicate or a
//  commented-out copy of the token cannot satisfy it (a renamed token still
//  escapes — formatting tripwire, not a behavioural proof). The behavioural
//  tests drive `ReadyWaiter` directly and pin the buffering mechanism (a
//  terminal state that lands before `wait()` still resolves it), plus the
//  second-concurrent-wait guard (one winner, one already-attached failure,
//  and the winner still resolves — no continuation leak).
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

    /// One waiter per `connect()`: a second concurrent `wait()` must fail
    /// with the already-attached error instead of leaking its continuation
    /// or hijacking the first wait's resume. Neither wait's attach order is
    /// assumed — whichever takes the continuation wins and stays parked
    /// until the terminal state, the other reports the failure, and the
    /// winner still resolves after `handle`. The bounded timeout turns a
    /// scheduler stall into a red instead of a hang.
    @Test
    func theSecondConcurrentWaitFailsInsteadOfLeakingTheContinuation() async {
        let waiter = makeWaiter()
        let reported = OnceFlag()
        let loser: WaitOutcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<WaitOutcome, Never>) in
            let report: @Sendable (WaitOutcome) -> Void = { outcome in
                if reported.fire() { continuation.resume(returning: outcome) }
            }
            Task {
                do {
                    try await waiter.wait()
                } catch {
                    report(.failed(String(describing: error)))
                }
            }
            Task {
                do {
                    try await waiter.wait()
                } catch {
                    report(.failed(String(describing: error)))
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5) {
                report(.timedOut)
            }
        }
        guard case .failed(let message) = loser else {
            Issue.record(
                "expected one of the two concurrent waits to fail with already-attached, got \(loser)"
            )
            waiter.handle(.ready)
            return
        }
        #expect(
            message.contains("already attached"),
            "the second wait must fail instead of leaking its continuation: \(message)"
        )
        // The winner is still parked; the terminal state must resolve it.
        waiter.handle(.ready)
    }

    // MARK: - The arm-before-start pin

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SSHTLSTransportReadyWaiterTests.swift
            .deletingLastPathComponent()  // TeleportCoreTests/
            .deletingLastPathComponent()  // Tests/
    }

    /// A comment-stripped copy of the production source for the token scans:
    /// `//` line comments and nested `/* … */` block comments become spaces,
    /// newlines are preserved (so slice anchors still resolve), and string
    /// contents are copied verbatim (a `//` inside a literal is not a
    /// comment). Duplicated from the sibling pin suites in
    /// `TeleportPackageTests` because SwiftPM targets cannot share a source
    /// file; keep the scanners in sync if either changes.
    private static func strippingComments(_ source: String) -> String {
        let characters = Array(source)
        var result = ""
        result.reserveCapacity(characters.count)
        var index = 0
        var blockCommentDepth = 0
        var inLineComment = false
        var stringDelimiter: Int? = nil  // 1 for `"…"`, 3 for `"""…"""`
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                    result.append("\n")
                } else {
                    result.append(" ")
                }
                index += 1
                continue
            }
            if blockCommentDepth > 0 {
                if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                    blockCommentDepth += 1
                    result.append("  ")
                    index += 2
                } else if character == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                    blockCommentDepth -= 1
                    result.append("  ")
                    index += 2
                } else {
                    result.append(character == "\n" ? "\n" : " ")
                    index += 1
                }
                continue
            }
            if let delimiter = stringDelimiter {
                result.append(character)
                index += 1
                if escaped {
                    escaped = false
                    continue
                }
                if character == "\\" {
                    escaped = true
                    continue
                }
                if delimiter == 1, character == "\"" {
                    stringDelimiter = nil
                    continue
                }
                if delimiter == 3,
                   character == "\"",
                   index + 1 < characters.count,
                   characters[index] == "\"",
                   characters[index + 1] == "\"" {
                    result.append("\"\"")
                    index += 2
                    stringDelimiter = nil
                }
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                inLineComment = true
                result.append("  ")
                index += 2
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                blockCommentDepth = 1
                result.append("  ")
                index += 2
                continue
            }
            if character == "\"" {
                if index + 2 < characters.count, characters[index + 1] == "\"", characters[index + 2] == "\"" {
                    stringDelimiter = 3
                    result.append("\"\"\"")
                    index += 3
                } else {
                    stringDelimiter = 1
                    result.append("\"")
                    index += 1
                }
                continue
            }
            result.append(character)
            index += 1
        }
        return result
    }

    /// `range(of:)` returns the first occurrence; a count of one is what makes
    /// "the first occurrence" the one the pin means (an earlier duplicate of
    /// the exact token must red the pin, not satisfy it).
    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test
    func theConnectionArmsTheHandlerBeforeStart() throws {
        let text = Self.strippingComments(
            try String(
                contentsOf: repositoryRoot().appendingPathComponent(
                    "Sources/TeleportCore/Infrastructure/SSHTLSTransport.swift"
                ),
                encoding: .utf8
            )
        )

        let armToken = "connection.stateUpdateHandler = { readyWaiter.handle($0) }"
        let startToken = "connection.start(queue: .global(qos: .userInitiated))"
        #expect(
            Self.occurrences(of: armToken, in: text) == 1,
            "the arm anchor must be unique (comment-stripped) — a commented-out or earlier duplicate must not satisfy this pin (#237)"
        )
        #expect(
            Self.occurrences(of: startToken, in: text) == 1,
            "the start anchor must be unique (comment-stripped) — a commented-out or earlier duplicate must not satisfy this pin (#237)"
        )
        let arm = try #require(
            text.range(of: armToken),
            "connect() must arm the state handler on the pre-armed ReadyWaiter — re-derive this pin (#237)"
        )
        let start = try #require(
            text.range(of: startToken),
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

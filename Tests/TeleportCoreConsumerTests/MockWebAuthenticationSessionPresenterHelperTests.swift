// SPDX-License-Identifier: MIT
//
//  MockWebAuthenticationSessionPresenterHelperTests.swift
//  TeleportCoreConsumerTests
//
//  The #267 mock helper surface the host's bootstrap/retry tests drive:
//  `liveSessionCount` (the leak signal — the mock does not
//  cancel-before-replace) and `waitUntilOpenStarted(_:timeout:)` (the
//  deterministic interleave). A non-`@testable` consumer test, so it also
//  pins that both helpers stay public.
//

import Foundation
import Testing
import TeleportTesting

struct MockWebAuthenticationSessionPresenterHelperTests {

    private let url = URL(string: "https://teleport.example.com/web/headless/x")!

    @Test
    func liveSessionCountTracksOpenAndCancel() async {
        let presenter = MockWebAuthenticationSessionPresenter()
        #expect(presenter.liveSessionCount == 0)

        _ = await presenter.open(url: url)
        #expect(presenter.liveSessionCount == 1, "open(url:) starts one live session")

        // The mock deliberately does NOT cancel-before-replace, so a caller
        // that opens a second session while one is live shows count == 2
        // (the leak signal the retry tests rely on).
        _ = await presenter.open(url: url)
        #expect(presenter.liveSessionCount == 2, "the mock must expose the leak rather than hide it")

        presenter.cancel()
        #expect(presenter.liveSessionCount == 0, "cancel() closes the session(s)")
        #expect(presenter.cancelCallCount == 1)
    }

    @Test
    func waitUntilOpenStartedReturnsTheCountFlagWithoutAnUnboundedTimeout() async {
        let presenter = MockWebAuthenticationSessionPresenter()

        // Not-yet-reached: the wait is bounded by the caller's timeout and
        // returns false rather than hanging.
        #expect(await presenter.waitUntilOpenStarted(1, timeout: 0.1) == false)

        _ = await presenter.open(url: url)
        #expect(await presenter.waitUntilOpenStarted(1, timeout: 0.1))
        #expect(await presenter.waitUntilOpenStarted(2, timeout: 0.1) == false)
    }
}

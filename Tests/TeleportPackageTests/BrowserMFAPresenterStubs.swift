// SPDX-License-Identifier: MIT
//
//  BrowserMFAPresenterStubs.swift
//  VVTermTests
//
//  Shared test doubles for the `BrowserMFAPresenting` seam. The ceremony
//  tests exercise paths that must never reach Safari (the empty-challenge
//  path), so the stub records any presentation attempt instead of opening a
//  session.
//

import Foundation
@testable import TeleportCore
@testable import TeleportAuth
import TeleportTesting

/// A presenter stub that records presentation attempts and never opens a
/// browser session.
@MainActor
final class RecordingBrowserMFAPresenter: BrowserMFAPresenting {
    nonisolated deinit {}
    private(set) var presentedURLs: [URL] = []

    func present(
        url: URL,
        completion: @escaping @Sendable (Error?) -> Void
    ) async -> any BrowserMFASessionHandle {
        presentedURLs.append(url)
        return StubBrowserMFASessionHandle()
    }
}

/// A no-op session handle.
@MainActor
final class StubBrowserMFASessionHandle: BrowserMFASessionHandle {
    nonisolated deinit {}
    let didStart = true
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

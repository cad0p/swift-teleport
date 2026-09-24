// SPDX-License-Identifier: MIT
//
//  MockWebAuthenticationSessionPresenter.swift
//  VVTerm
//
//  A mock `WebAuthenticationSessionPresenting` for unit tests. Records
//  `open(url:)` / `cancel()` calls without actually presenting Safari.
//

import Foundation
import TeleportCore

/// A mock Safari presenter. `open(url:)` returns `scriptedOpenResult`
/// (default `true`) without launching ASWebAuthenticationSession.
/// `cancel()` is recorded but does nothing.
@MainActor
public final class MockWebAuthenticationSessionPresenter: WebAuthenticationSessionPresenting {

    nonisolated deinit {}
    /// The value returned by `open(url:)`. Default `true` (Safari "opened").
    public var scriptedOpenResult: Bool = true

    /// The URLs passed to `open(url:)`, in order.
    public private(set) var openedURLs: [URL] = []

    /// The number of times `cancel()` was called.
    public private(set) var cancelCallCount = 0

    public init() {}

    public func open(url: URL) async -> Bool {
        openedURLs.append(url)
        return scriptedOpenResult
    }

    public func cancel() {
        cancelCallCount += 1
    }
}

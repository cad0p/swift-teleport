// SPDX-License-Identifier: MIT
//
//  TeleportNIOCoreLinkPinsTests.swift
//  TeleportPackageTests
//
//  Source pin for swift-teleport#66: `Sources/` must copy a gRPC response body
//  through NIOCore only — never through the `Foundation.ContiguousBytes`
//  conformance of `NIOCore.ByteBufferView`.
//
//  Why a source pin: the defect is a *link-time* dependency on a retroactive
//  conformance declared in swift-nio's separate `NIOFoundationEssentialsCompat`
//  module (public product, swift-nio `Package.swift:54`) that `TeleportCore`
//  does not declare. `body.append(contentsOf: buffer.readableBytesView)` can
//  pick the `ContiguousBytes` overload, making the object file reference the
//  conformance descriptor. The resolver choice is toolchain-dependent: the
//  Xcode 27 object file references it (and the dynamic-framework link then
//  fails), while an Xcode 26.3 object file was measured referencing only the
//  NIOCore-native `ByteBufferView: Swift.Sequence` witness (lens-1 MINOR-2,
//  measured pre-fix). Either way the static link succeeds (the package's own
//  builds); the failure is the dynamic-framework consumer
//  (`PackageFrameworks/TeleportCore.framework`, iOS Simulator Debug
//  `build-for-testing`, vvterm#425 `build` job `114001367173`):
//
//      Undefined symbols for architecture arm64:
//        "protocol conformance descriptor for NIOCore.ByteBufferView :
//         Foundation.ContiguousBytes in NIOFoundationEssentialsCompat",
//        referenced from … in GRPCClient.o
//
//  The failure needs the CI Xcode 27 dynamic-framework link, so no local
//  `swift test` can reproduce it (local Xcode 26.3 links it statically; the
//  `MACH_O_TYPE=mh_dylib` probe is not faithful — it breaks SwiftProtobuf's
//  own link). The structural shape is what is pinnable here: the tokens that
//  route through the undeclared conformance must not reappear in `Sources/`.
//
//  FORMATTING HEURISTIC, NOT A PROOF: the scan reads the production sources as
//  text. Comments are stripped before scanning (the #66 fix's own comment
//  names both tokens), so a commented-out call can neither satisfy nor trip
//  the scan; a token inside a string literal still trips it. Defeats recorded
//  deliberately: (a) a helper in another module that hands back a
//  `ByteBufferView`/`ContiguousBytes` value, or any API that resolves to the
//  same overload without naming either token, keeps this package's `Sources/`
//  token-free; (b) a multi-line spelling of the `append(contentsOf:)` call
//  still contains the bare `readableBytesView` token and is caught, but a
//  token-hiding spelling (e.g. an aliased property whose body sits in a
//  dependency) escapes; (c) `@_disfavoredOverload` on the Foundation side
//  could flip overload resolution to the NIO witness with neither token in
//  this package; (d) the `ContiguousBytes` refusal is file-set-wide and
//  fails closed — an unrelated legitimate use reds and needs a deliberate
//  re-derivation of this pin; (e) the positive control pins the current
//  `getBytes(at:length:)` copy shape — the equally valid
//  `withUnsafeReadableBytes` spelling is refused until the pin is updated on
//  purpose; (f) the comment stripper below does not understand raw strings
//  (`#"…"#`) or regex literals, so an unclosed `/*` inside one (e.g.
//  `let s = #"a"/*"#; let t = readableBytesView`, or a regex literal
//  `let re = /[/*]/; …`) swallows the rest of the file and can hide a token
//  after it (lens-1 MINOR-1, measured); the stripper doc's cross-reference
//  below names this row.
//
//  Counterfactual hook: the package pins resolve the repository root from
//  `#filePath` (no host-only `VVTERM_PINS_SOURCE_ROOT` override, per this
//  package's pin convention). CF-66 is measured by mutating the tree in
//  place, running the pin, and reverting — the mutation is named in the PR
//  report.
//

import Foundation
import Testing

struct TeleportNIOCoreLinkPinsTests {

    // MARK: - Fixtures

    /// The repository root, derived from this file's location
    /// (`Tests/TeleportPackageTests/TeleportNIOCoreLinkPinsTests.swift`).
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TeleportNIOCoreLinkPinsTests.swift
            .deletingLastPathComponent()  // TeleportPackageTests/
            .deletingLastPathComponent()  // Tests/
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private static func relativePath(of file: URL, from root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return file.path.hasPrefix(rootPath) ? String(file.path.dropFirst(rootPath.count)) : file.path
    }

    // MARK: - Source helpers

    /// A comment-stripped copy of the production source for the token scans:
    /// `//` line comments and nested `/* … */` block comments become spaces,
    /// newlines are preserved, and string contents are copied verbatim (a
    /// `//` inside a literal is not read as a comment). Duplicated from the
    /// sibling pin suites (`TeleportCredentialPairPinsTests`,
    /// `SSHTLSTransportReadyWaiterTests`) because SwiftPM targets cannot share
    /// a source file; keep the scanners in sync if either changes. The scanner
    /// does not understand raw strings (`#"…"#`), regex literals, or comments
    /// inside an interpolation — defeat (f) in the header records the measured
    /// consequence (an unclosed `/*` inside a raw string/regex swallows the
    /// remainder of the file).
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

    private static func swiftFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - The pin

    /// Pin (#66): no `Sources/` file may name `readableBytesView` or
    /// `ContiguousBytes` after comment stripping; `GRPCClient` must copy the
    /// readable bytes through the NIOCore `getBytes(at:length:)` route.
    @Test
    func testSourcesKeepOffTheUndeclaredNIOConformance() throws {
        let files = Self.swiftFiles(under: repositoryRoot().appendingPathComponent("Sources"))
        #expect(
            files.count >= 40,
            "the Sources scan must enumerate the package's sources (≥40 files; measured 55 at #66) — re-derive the source root (issue #66)"
        )

        // Coverage guard: a path-derivation mistake must fail loudly, not pass
        // vacuously on an empty or wrong file set.
        let grpcClient = try #require(
            files.first { $0.lastPathComponent == "GRPCClient.swift" },
            "the scan must cover Sources/TeleportCore/Infrastructure/GRPCClient.swift — re-derive the source root (issue #66)"
        )
        #expect(
            grpcClient.path.contains("/Sources/TeleportCore/Infrastructure/"),
            "GRPCClient.swift must resolve to the TeleportCore Infrastructure path (got \(grpcClient.path))"
        )

        var offenders: [String] = []
        for file in files {
            let text = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            let relative = Self.relativePath(of: file, from: repositoryRoot())
            for needle in ["readableBytesView", "ContiguousBytes"] where text.contains(needle) {
                offenders.append("\(relative): \(needle)")
            }
        }
        #expect(
            offenders.isEmpty,
            """
            Sources/ must not use `readableBytesView`/`ContiguousBytes`: the `ContiguousBytes` \
            conformance of `ByteBufferView` lives in swift-nio's separate \
            `NIOFoundationEssentialsCompat` product, which TeleportCore does not declare, and the \
            Xcode 27 dynamic-framework link fails with an undefined conformance descriptor \
            (swift-teleport#66). Offenders: \(offenders)
            """
        )

        // Positive control: the fixed copy site is present and NIOCore-only,
        // so deleting the append instead of fixing it cannot keep the scan
        // green (a raw `getBytes(at:length:)` copy is the pinned shape).
        let grpcText = Self.strippingComments(
            try source("Sources/TeleportCore/Infrastructure/GRPCClient.swift")
        )
        #expect(
            grpcText.contains("buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes)"),
            "GRPCClient must copy the readable bytes through the NIOCore `getBytes(at:length:)` API (issue #66)"
        )
        #expect(
            grpcText.contains("body.append(contentsOf: bytes)"),
            "GRPCClient must append the copied bytes to the response body (issue #66)"
        )
    }
}

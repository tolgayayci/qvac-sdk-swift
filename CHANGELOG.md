# Changelog

All notable changes to **QVACClient** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial Swift Package skeleton: `Package.swift` targets macOS 14 / iOS 17 / Swift 5.10. (YK-174)
- `docs/qvac-sdk-internals.md` — full request type registry, error codes, init handshake,
  per-method request/response schemas pinned to `@qvac/sdk` 0.10.2 (`tetherto/qvac@9db6f98`). (YK-175)
- `docs/bare-rpc-wire-protocol.md` — frame layout, message types, stream OPEN/PAUSE/RESUME/END/CLOSE/DESTROY,
  payload encoding (JSON only), and `bare-rpc-swift` API surface pinned to main @ `3983622`. (YK-176)
- Smoke + doc-baseline tests under `Tests/QVACClientTests/`.

### Notes
- No public API yet — `QVACClient` is a placeholder actor used to anchor the package layout.
- All bounty milestone targets ([Tether Bounty #2885283454](https://tether.dev/grants/bounties/2885283454/))
  remain in scope: M1 (code-gen + IPC transport), M2 (full method surface), M3 (RAG + plugins + DocC + release).

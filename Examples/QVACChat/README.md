# QVACChat — SwiftUI example for QVACClient

Minimal chat app demonstrating the QVACClient streaming-completion
surface. SwiftUI on macOS today; iOS lands when YK-207 v2's
`qvac-worker.bundle` SPM resource ships.

## Run

From this directory:

```bash
# One-time setup — stage BareKit + the qvac-worker fixture.
(cd ../.. && ./scripts/download-barekit.sh)
(cd ../../Tests/Fixtures/qvac-worker && npm install)

# Build + run.
swift run QVACChat
```

That opens a SwiftUI window. On first run the model loads (~5-30s
for a 1B GGUF depending on connection); subsequent runs are fast
when the model is cached.

## What it shows

- **Spawn factory** — `QVACClient.spawning(...)` starts the Bare
  worker subprocess and runs `__init_config`.
- **Streaming completion** — `client.completion(...)` returns an
  `AsyncThrowingStream`. The view model appends each `.token(_)`
  chunk into the trailing assistant message as it arrives.
- **Cancel** — the Cancel button flips the streaming `Task` into
  cancelled; the stream's `onTermination` tears down the RPC.
- **Error mapping** — `QVACError` → typed banner via the
  `bannerText` computed property in `ContentView.swift`.
- **`@Observable` view model** — Swift 5.10 Observation framework,
  `@MainActor` for thread safety, history tracked as
  `[ChatMessageItem]`.

## Sources

| File | What |
| --- | --- |
| `QVACChatApp.swift` | `@main`, single `WindowGroup`, Cmd-N "New Chat" |
| `ChatSession.swift` | Streaming + lifecycle state, spawn bootstrap, fixture path resolution |
| `ContentView.swift` | Header + status badge + scroll-bound message list + input row, `MessageBubble`, error banner, SwiftUI preview |

## iOS

iOS support comes online once the embedded factory's worker
bundle ships (YK-207 v2). The same SwiftUI views compile for iOS
today; the only change is swapping
`QVACClient.spawning(bareBinary:workerScript:)` for
`QVACClient.embedded()` in `ChatSession.bootstrap()`.

## Wiring as a separate Xcode project

If you'd rather have a standalone `QVACChat.xcodeproj` (instead of
an SPM executable), drag the three Swift files into a new SwiftUI
App template and add the QVACClient SPM dependency. The view model
and views work unchanged.

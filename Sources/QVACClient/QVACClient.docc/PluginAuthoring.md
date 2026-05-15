# Plugins

QVAC plugins are user-supplied extensions that run inside the Bare
worker. The Swift client calls them through a generic
`invokePlugin` / `invokePluginStream` surface that doesn't need to
know plugin schemas at codegen time.

## Overview

A plugin lives on the worker side and registers handlers via
`@qvac/sdk`'s `definePlugin(...)`. From Swift you invoke a handler
by name, sending whatever `Encodable` params it expects and
decoding the result as whatever `Decodable` shape it returns:

```swift
struct GreetArgs: Codable { let name: String; let formal: Bool }
struct GreetResult: Codable { let message: String }

let greeting: GreetResult = try await client.invokePlugin(
  modelId: "my-plugin-model",
  handler: "greet",
  params: GreetArgs(name: "Tolga", formal: true))
print(greeting.message)
```

The SDK is generic over the args + result types — caller-defined
`Codable` structs round-trip without any SDK changes.

## Streaming plugins

A handler can be streaming (emits multiple chunks then a terminal
frame with `done: true`):

```swift
struct LogChunk: Codable { let line: String; let level: String }

let stream: AsyncThrowingStream<LogChunk, Error> =
  client.invokePluginStream(
    modelId: "my-plugin-model",
    handler: "tailLog",
    params: GreetArgs(name: "anything", formal: false))

for try await chunk in stream {
  print("[\(chunk.level)]", chunk.line)
}
```

## Fluent wrapper

For code that talks to one plugin a lot, ``PluginClient`` pins the
model id:

```swift
let myPlugin = client.plugin(modelId: "my-plugin-model")

let greeting: GreetResult = try await myPlugin.call(
  "greet", params: GreetArgs(name: "Tolga", formal: true))

let logs: AsyncThrowingStream<LogChunk, Error> =
  myPlugin.stream("tailLog", params: GreetArgs(name: "x", formal: false))
```

## Wire shape

Under the hood:

- `pluginInvoke` request: `{type:"pluginInvoke", modelId, handler, params}`
- `pluginInvoke` response: `{type:"pluginInvoke", result: <any JSON>}`
- `pluginInvokeStream` request: same shape, type `pluginInvokeStream`
- `pluginInvokeStream` frame: `{type:"pluginInvokeStream", result, done?: true}`

The `result` field is decoded via `JSONEncoder` + `JSONDecoder` on
the Swift side, so the caller's `Codable` type materializes through
the standard path — no manual `AnyCodableValue` → `T` translation.

## Authoring a plugin

Plugin code lives on the **worker side** in JavaScript. The Swift
client only invokes; the authoring story is `@qvac/sdk`'s. A minimal
echo plugin manifest looks like:

```javascript
// my-plugin.mjs
import { definePlugin, defineHandler } from "@qvac/sdk/server"
import { z } from "zod"

const EchoArgs = z.object({ text: z.string() })
const EchoResult = z.object({ text: z.string() })

export default definePlugin({
  id: "echo",
  modelTypes: ["llamacpp-completion"],
  handlers: {
    echo: defineHandler({
      request: EchoArgs,
      response: EchoResult,
      handler: async ({ text }) => ({ text }),
    }),
  },
})
```

Register it in your worker entry:

```javascript
// worker.mjs
import "@qvac/sdk/dist/server/worker.js"
import myPlugin from "./my-plugin.mjs"
import { registerPlugin } from "@qvac/sdk/server/plugins"

registerPlugin(myPlugin)
```

For the full plugin authoring story (worker context, handler
signatures, registering for specific `modelType`s, error
propagation) refer to `@qvac/sdk`'s plugin docs upstream — those
APIs aren't Swift-side concerns.

## Error handling

Plugin handlers can throw; the worker serializes the error and
returns it. Today those surface as ``QVACError/server(_:message:)``
with the JS plugin's `error.message`. A dedicated
`QVACError.pluginError(...)` case is an M3 followup once the worker
side commits to a stable code for plugin errors.

## Cancellation

Stream consumers can `break` or `Task.cancel()` like any other
streaming surface — see <doc:Streaming>. Per-plugin wire-level
cancel doesn't exist in `@qvac/sdk`'s cancel schema today; the
plugin handler should respect its own `signal` argument if you need
to stop the worker from doing more work.

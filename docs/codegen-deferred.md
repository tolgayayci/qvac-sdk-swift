# Codegen — deferred type translation

YK-179 ships an allowlist of types from `@qvac/sdk@0.10.2` that translate
cleanly into Swift `Codable` structs and enums. Anything outside that
allowlist is *deferred* — the codegen scaffolding can see those types but
declines to emit them, because at least one of the following blocks a
clean Swift port:

| Blocker | Why it defers |
| --- | --- |
| Cross-type field references | Field type points at another generated type whose own translation chain isn't clean yet; one bad link drops the whole chain. Avoided by tightening the allowlist until the dependency graph is closed. |
| Generics (`Foo<T>`) | Swift's generic-Codable inference doesn't compose like TS's; needs a per-shape protocol witness or `AnyCodable` fallback. Not a YK-179 deliverable. |
| Intersections (`A & B`) | Lose fidelity flattened into a Swift struct; surfaced as `AnyCodable` per the YK-179 type-mapping table. |
| Discriminated unions with shared discriminant values | `{ type: "deleteCache", all: true } \| { type: "deleteCache", kvCacheKey }` reuses the same `type` literal on both branches; the heuristic that pairs `discriminator → distinct value` doesn't apply. A second-pass walker keyed on per-variant unique fields lands in M2. |
| Zod transforms / `.refine` | The TS type after `.transform(...)` doesn't match the input shape on the wire. Emitting the input or output type alone is misleading; needs an explicit request/response split per method (the YK-180 work). |
| Nested anonymous objects | Anonymous `{ a: x, b: y }` inside a field type can't be named at the call site. The IR surfaces them as `AnyCodable`; YK-180 hoists them to sibling structs as the method-emit pass needs them. |

## Current allowlist (26 emitted in M1)

Lifecycle: `LifecycleState`, `StateRequest`, `StateResponse`,
`SuspendRequest`, `SuspendResponse`, `ResumeRequest`, `ResumeResponse`.

Connectivity: `HeartbeatRequest`, `HeartbeatResponse`, `DelegateBase`.

Embed: `EmbedParams`, `EmbedRequest`, `EmbedResponse`, `EmbedStats`.

Unload: `UnloadModelRequest`, `UnloadModelResponse`.

Provider: `ProvideRequest`, `ProvideResponse`, `FirewallConfig`,
`StopProvideRequest`, `StopProvideResponse`.

Cache + cancel: `DeleteCacheResponse`, `CancelResponse`.

Common enums: `TtsLanguage`, `BergamotLanguage`, `ProfilerMode`,
`ModelType` (skipped at build time — needs the M2 namespace pass).

## Forward plan

| Issue | Coverage |
| --- | --- |
| YK-180 (codegen methods) | Hoists nested anonymous objects to sibling structs; expands the discriminated-union walker; emits per-method `Request`/`Response` Swift types and the `QVACCommand` enum. |
| YK-182 (codegen format) | Idempotency check, swift-format pinning, deterministic re-runs. |
| M2 codegen pass | Drains the deferred set — extracts the long tail of Zod-inferred types via a deeper TypeChecker walk + per-shape custom Codable for discriminated unions with shared discriminant values. |

The deferred set is a backlog item, not an accuracy problem. Every
generated file in `Sources/QVACClient/Generated/Models/` is an honest
representation of the upstream type; anything not generated is documented
here so M2/M3 work picks it up explicitly.

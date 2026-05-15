# Retrieval-augmented generation (RAG)

QVAC ships a built-in RAG store backed by `bare-rag-hyperdb`. The
Swift surface covers the full workflow: chunk → embed → store →
search → reindex → close.

## Overview

A *workspace* is an isolated chunk store. Documents ingested into
workspace A can't bleed into workspace B's searches. The worker's
`DEFAULT_WORKSPACE` is used when callers pass `nil`.

```swift
// 1. Load an embedding model
let modelId = try await client.loadModel(
  modelId: "bge-small-en-v1.5",
  modelType: "embeddings",
  modelSrc: "https://huggingface.co/.../bge-small-en-v1.5-q4_k_m.gguf")

// 2. Ingest documents — chunker runs server-side
let result = try await client.ragIngest(
  modelId: modelId,
  workspace: "docs-v1",
  documents: [
    "Swift Concurrency uses actors to serialize mutable state.",
    "AsyncSequence lets you write iterator-style code without manual cancellation.",
  ])
print("Ingested:", result.processed.count, "dropped:", result.droppedIndices)

// 3. Search
let hits = try await client.ragSearch(
  modelId: modelId,
  workspace: "docs-v1",
  query: "How do I avoid data races in async code?",
  topK: 3)
for hit in hits {
  print(hit.score, hit.content)
}

// 4. (Optional) Tear down
try await client.ragCloseWorkspace(workspace: "docs-v1")
```

## Streaming ingest

For large ingestion jobs, use ``QVACClient/ragIngestStream(modelId:workspace:documents:chunk:chunkOpts:progressInterval:bufferSize:)``
to get progress events as the worker chunks, embeds, and saves:

```swift
let stream = client.ragIngestStream(
  modelId: modelId,
  workspace: "books",
  documents: bookContents,    // [String], one per book
  progressInterval: 250)      // ms between progress frames

for try await event in stream {
  switch event {
  case .progress(let stage, let current, let total, _):
    print("\(stage) \(current)/\(total)")
  case .completed(let result):
    print("Done. Processed \(result.processed.count) chunks.")
  }
}
```

The streaming variant sets `withProgress: true` on the wire; the
worker switches from `executeReplyHandler` to `executeProgressHandler`
and emits progress frames over `req.createResponseStream()` before
the final reply.

## Workspace management

- ``QVACClient/ragListWorkspaces()`` — list all workspaces (open
  and closed).
- ``QVACClient/ragCloseWorkspace(workspace:deleteOnClose:)`` —
  release the in-memory index without deleting the on-disk store.
  Pass `deleteOnClose: true` to do both in one round-trip.
- ``QVACClient/ragDeleteWorkspace(workspace:)`` — permanently
  delete a workspace and its backing files.

## Embeddings management

For callers who want to bypass the worker's embedding model (e.g.
using a third-party embedder or cached vectors):

- ``QVACClient/ragSaveEmbeddings(workspace:modelId:documents:)`` —
  save pre-computed `RAGEmbeddedDocument` values directly. The
  `embeddingModelId` field is informational; the worker doesn't
  validate vector length against the labeled model.
- ``QVACClient/ragDeleteEmbeddings(workspace:ids:)`` — delete by id.
  Idempotent; unknown ids are silent no-ops.

## Reindexing

After upgrading the embedding model or shifting chunking strategy,
``QVACClient/ragReindex(workspace:)`` rebuilds the index in-place.
For large stores, prefer the streaming variant to get progress:

```swift
let stream = client.ragReindexStream(workspace: "books")
for try await event in stream {
  switch event {
  case .progress(let stage, _, _, _): print("Reindex:", stage)
  case .completed(let result): print("Reindexed:", result.reindexed)
  }
}
```

## Cancellation

In-progress RAG operations are cancellable worker-side via the
typed cancel API:

```swift
try await client.cancel(
  AnyCodable(.object([
    "operation": .string("rag"),
    "workspace": .string("books")
  ])))
```

Per-operation cancel matches `@qvac/sdk`'s
`cancelRagParamsSchema` which takes `{operation: "rag", workspace?}`.
Consumer-side cancel of `ragIngestStream` only stops Swift reading;
the typed wire-level cancel is what stops the worker. See
<doc:ErrorHandling> for the post-cancel error path.

## What's still tested with stubs

The unit tests for RAG-core (YK-212) and RAG-admin (YK-213) use a
loopback peer that echoes deterministic stub responses, so they
pin the envelope shapes but not the semantic quality of search
results. Real-model recall/precision (does `"feline"` retrieve
`"the cat sat on the mat"`?), large-workspace reindex behavior,
mid-ingest cancel rollback, and concurrent-ingest isolation roll
into the M3 final-integration suite tracked as YK-222.

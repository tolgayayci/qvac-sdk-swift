import Foundation
import Observation
import QVACClient

/// Single in-memory message in the chat. UI rows are keyed on
/// `id`; the `content` field is mutated as streaming tokens
/// arrive into the trailing assistant message.
struct ChatMessageItem: Identifiable, Equatable {
  enum Role: String { case user, assistant }
  let id = UUID()
  let role: Role
  var content: String
  var isStreaming: Bool = false
}

/// Top-level state container — owns the spawn factory's
/// `SpawnedClient`, the chat history, the streaming task, and
/// the UI-facing loading / error flags.
///
/// Marked `@Observable` so SwiftUI views auto-track property
/// access. Marked `@MainActor` so all mutations land on the main
/// run loop — the streaming task hops onto MainActor before
/// appending tokens to avoid concurrent mutation.
@Observable
@MainActor
final class ChatSession {

  enum BootstrapState: Equatable {
    case notStarted
    case starting
    case loadingModel(String)
    case ready(modelId: String)
    case failed(String)
  }

  var messages: [ChatMessageItem] = []
  var input: String = ""
  var bootstrapState: BootstrapState = .notStarted
  var isStreaming: Bool = false
  var error: QVACError?

  private var spawned: SpawnedClient?
  private var modelId: String?
  private var streamTask: Task<Void, Never>?

  // MARK: - Bootstrap

  /// Spawn the worker, run the init handshake, and load the chat
  /// model. Idempotent — subsequent calls return immediately.
  func bootstrap() async {
    guard case .notStarted = bootstrapState else { return }
    bootstrapState = .starting

    do {
      let (bareBinary, workerScript) = try Self.fixturePaths()
      let spawned = try await QVACClient.spawning(
        bareBinary: bareBinary, workerScript: workerScript)
      self.spawned = spawned

      // The worker dispatcher assigns the modelId — it's the return
      // value of loadModel, not an input. Source is a HuggingFace
      // GGUF URL; the worker downloads + caches on first use.
      bootstrapState = .loadingModel("Llama-3.2-1B-Inst-Q4_0")

      let loaded = try await spawned.client.loadModel(
        modelSrc:
          "https://huggingface.co/lmstudio-community/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_0.gguf",
        modelType: "llm")

      self.modelId = loaded
      bootstrapState = .ready(modelId: loaded)
    } catch let err as QVACError {
      bootstrapState = .failed(err.errorDescription ?? "\(err)")
    } catch {
      bootstrapState = .failed("\(error)")
    }
  }

  // MARK: - Send

  /// Append the user's message, launch the streaming completion
  /// task, append `.token(_)` chunks into a new assistant message
  /// as they arrive.
  func send() {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty,
      !isStreaming,
      case .ready(let modelId) = bootstrapState,
      let spawned
    else { return }

    messages.append(.init(role: .user, content: text))
    input = ""

    // Reserve a streaming assistant message that tokens append to.
    var assistant = ChatMessageItem(
      role: .assistant, content: "", isStreaming: true)
    let assistantId = assistant.id
    messages.append(assistant)
    isStreaming = true

    let history: [ChatMessage] = messages.dropLast().map { item in
      ChatMessage(
        role: item.role == .user ? "user" : "assistant",
        content: item.content)
    }

    streamTask = Task { [weak self] in
      guard let self else { return }
      // bufferSize: nil disambiguates from the blocking overload —
      // the streaming variant returns AsyncThrowingStream while
      // the blocking one returns CompletionResult.
      let stream: AsyncThrowingStream<CompletionChunk, Error> =
        spawned.client.completion(
          modelId: modelId, history: history, bufferSize: nil)
      do {
        for try await chunk in stream {
          if Task.isCancelled { break }
          if case .token(let token) = chunk {
            await self.appendToken(token, to: assistantId)
          }
        }
      } catch let err as QVACError {
        await self.captureError(err)
      } catch {
        // Cancellation lands here too — silent.
      }
      await self.finishStreaming(messageId: assistantId)
    }
  }

  /// Cancel the consumer side; the streaming task's
  /// `Task.isCancelled` check stops further appends.
  func cancel() {
    streamTask?.cancel()
    streamTask = nil
    isStreaming = false
    if let i = messages.indices.last, messages[i].isStreaming {
      messages[i].isStreaming = false
    }
  }

  /// Reset the chat. Keeps the loaded model — only clears the
  /// message history.
  func reset() {
    cancel()
    messages.removeAll()
    input = ""
    error = nil
  }

  // MARK: - Private mutations

  private func appendToken(_ token: String, to id: UUID) {
    guard let i = messages.firstIndex(where: { $0.id == id })
    else { return }
    messages[i].content += token
  }

  private func captureError(_ err: QVACError) {
    error = err
  }

  private func finishStreaming(messageId id: UUID) {
    isStreaming = false
    streamTask = nil
    if let i = messages.firstIndex(where: { $0.id == id }) {
      messages[i].isStreaming = false
    }
  }

  // MARK: - Fixture paths

  /// Resolves the bare binary + worker.mjs from the repo's test
  /// fixture. A real production app would ship its own worker
  /// bundle; the example reuses the YK-208 fixture so cloning the
  /// repo is all the setup that's needed.
  private static func fixturePaths() throws -> (URL, URL) {
    let env = ProcessInfo.processInfo.environment
    if let bare = env["QVAC_BARE_BIN"], let worker = env["QVAC_WORKER_MJS"] {
      return (URL(fileURLWithPath: bare), URL(fileURLWithPath: worker))
    }
    // Walk up from this source file to the repo root.
    let here = URL(fileURLWithPath: #filePath)
    let repoRoot = here
      .deletingLastPathComponent()  // QVACChat/
      .deletingLastPathComponent()  // Sources/
      .deletingLastPathComponent()  // QVACChat/
      .deletingLastPathComponent()  // Examples/
    let fixture = repoRoot
      .appendingPathComponent("Tests/Fixtures/qvac-worker")
    let bare = fixture.appendingPathComponent("node_modules/.bin/bare")
    let worker = fixture.appendingPathComponent("worker.mjs")
    return (bare, worker)
  }
}

extension QVACError {
  fileprivate var errorDescription: String? {
    switch self {
    case .client(let code, let msg):
      return "Client error \(code.wireName): \(msg)"
    case .server(let code, let msg):
      return "Server error \(code.wireName): \(msg)"
    case .transport(let t):
      return "Transport error: \(t.message)"
    case .unknown(_, let name, let msg):
      return "Unknown SDK error \(name ?? "?"): \(msg)"
    }
  }
}

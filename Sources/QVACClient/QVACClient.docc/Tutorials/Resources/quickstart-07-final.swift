import Foundation
import QVACClient

let bareBinary = URL(fileURLWithPath:
  ".build/checkouts/qvac-sdk-swift/Tests/Fixtures/qvac-worker/node_modules/.bin/bare")
let workerScript = URL(fileURLWithPath:
  ".build/checkouts/qvac-sdk-swift/Tests/Fixtures/qvac-worker/worker.mjs")

do {
  let spawned = try await QVACClient.spawning(
    bareBinary: bareBinary,
    workerScript: workerScript)
  // Ensures the subprocess is reaped even on crash.
  defer { Task { await spawned.close() } }

  let modelId = try await spawned.client.loadModel(
    modelId: "llamacpp:Llama-3.2-1B-Inst-Q4_0",
    modelType: "llm",
    modelSrc: "https://huggingface.co/.../Llama-3.2-1B-Instruct-Q4_0.gguf")

  let stream = spawned.client.completion(
    modelId: modelId,
    history: [.user("Hello, who are you?")])

  for try await chunk in stream {
    if case .token(let token) = chunk { print(token, terminator: "") }
  }
  print()

  try await spawned.client.unloadModel(modelId)
} catch let err as QVACError {
  switch err {
  case .client(let code, let msg):
    print("Worker rejected request: \(code) \(msg)")
  case .server(let code, let msg):
    print("Inference failed: \(code) \(msg)")
  case .transport(.transportClosed):
    print("Worker disconnected.")
  case .transport(let t):
    print("Transport: \(t)")
  case .unknown(let code, let name, let msg):
    print("Unknown SDK error: \(name ?? "?") \(code.map(String.init) ?? "") \(msg)")
  }
}

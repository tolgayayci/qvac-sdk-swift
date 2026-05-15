import Foundation
import QVACClient

let bareBinary = URL(fileURLWithPath:
  ".build/checkouts/qvac-sdk-swift/Tests/Fixtures/qvac-worker/node_modules/.bin/bare")
let workerScript = URL(fileURLWithPath:
  ".build/checkouts/qvac-sdk-swift/Tests/Fixtures/qvac-worker/worker.mjs")

let spawned = try await QVACClient.spawning(
  bareBinary: bareBinary,
  workerScript: workerScript)

let modelId = try await spawned.client.loadModel(
  modelId: "llamacpp:Llama-3.2-1B-Inst-Q4_0",
  modelType: "llm",
  modelSrc: "https://huggingface.co/lmstudio-community/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_0.gguf")

let stream = spawned.client.completion(
  modelId: modelId,
  history: [.user("Hello, who are you?")])

for try await chunk in stream {
  if case .token(let token) = chunk { print(token, terminator: "") }
}
print()

try await spawned.client.unloadModel(modelId)
await spawned.close()

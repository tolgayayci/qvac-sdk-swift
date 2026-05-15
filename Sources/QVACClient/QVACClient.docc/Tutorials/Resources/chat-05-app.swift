import SwiftUI
import QVACClient

@main
struct ChatApp: App {
  @State private var vm: ChatViewModel?

  var body: some Scene {
    WindowGroup {
      Group {
        if let vm {
          ChatView(vm: vm)
        } else {
          ProgressView("Loading model…")
            .task { await bootstrap() }
        }
      }
    }
  }

  private func bootstrap() async {
    do {
      // macOS / Linux: spawn factory. On iOS, use embedded(...)
      // once YK-207 v2's worker bundle ships.
      let spawned = try await QVACClient.spawning(
        bareBinary: URL(fileURLWithPath: bareBinaryPath),
        workerScript: URL(fileURLWithPath: workerScriptPath))
      let modelId = try await spawned.client.loadModel(
        modelId: "llamacpp:Llama-3.2-1B-Inst-Q4_0",
        modelType: "llm",
        modelSrc: "https://huggingface.co/.../Llama-3.2-1B-Instruct-Q4_0.gguf")
      vm = ChatViewModel(client: spawned.client, modelId: modelId)
    } catch {
      print("Failed to bootstrap chat: \(error)")
    }
  }

  private var bareBinaryPath: String { /* … */ "" }
  private var workerScriptPath: String { /* … */ "" }
}

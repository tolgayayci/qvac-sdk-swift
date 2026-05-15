import Foundation
import QVACClient
import Observation

struct Message: Identifiable, Equatable {
  enum Role: String, Equatable { case user, assistant }
  let id = UUID()
  let role: Role
  var content: String
}

@Observable
@MainActor
final class ChatViewModel {
  var messages: [Message] = []
  var input: String = ""
  var isStreaming: Bool = false
  var error: QVACError?

  private let client: QVACClient
  private let modelId: String
  private var streamTask: Task<Void, Never>?

  init(client: QVACClient, modelId: String) {
    self.client = client
    self.modelId = modelId
  }
}

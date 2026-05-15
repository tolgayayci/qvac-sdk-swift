extension ChatViewModel {
  func send() {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isStreaming else { return }

    messages.append(Message(role: .user, content: text))
    input = ""

    // Reserve an empty assistant message — tokens append into it.
    messages.append(Message(role: .assistant, content: ""))
    let assistantIndex = messages.count - 1
    isStreaming = true

    let history = messages.dropLast().map { msg in
      ChatMessage(
        role: msg.role == .user ? "user" : "assistant",
        content: msg.content)
    }

    streamTask = Task { [client, modelId] in
      let stream = await client.completion(
        modelId: modelId, history: Array(history))
      do {
        for try await chunk in stream {
          if case .token(let token) = chunk {
            await MainActor.run { messages[assistantIndex].content += token }
          }
        }
      } catch let err as QVACError {
        await MainActor.run { error = err }
      } catch {
        // Other errors (e.g. Task cancellation): silent.
      }
      await MainActor.run {
        isStreaming = false
        streamTask = nil
      }
    }
  }
}

extension ChatViewModel {
  /// Consumer-side cancel only. The view shows a Cancel button
  /// while `isStreaming == true`; tapping it calls this.
  func cancel() {
    streamTask?.cancel()
    streamTask = nil
    isStreaming = false
  }

  /// Hard cancel — also tells the worker to abort the inference.
  /// Use this when the user explicitly wants to free the worker
  /// (e.g. about to start a new long completion).
  func hardCancel() {
    cancel()
    Task { [client, modelId] in
      try? await client.cancel(AnyCodable(.object([
        "operation": .string("inference"),
        "modelId": .string(modelId),
      ])))
    }
  }
}

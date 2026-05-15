extension ChatViewModel {
  var errorBannerText: String? {
    guard let error else { return nil }
    switch error {
    case .client(let code, let msg):
      return "Request rejected (\(code.wireName)): \(msg)"
    case .server(let code, let msg):
      return "Inference failed (\(code.wireName)): \(msg)"
    case .transport(.transportClosed):
      return "Worker disconnected. Restart the app."
    case .transport(let t):
      return "Transport error: \(t.message)"
    case .unknown(_, let name, let msg):
      return "Unknown error \(name ?? "?"): \(msg)"
    }
  }

  func dismissError() { error = nil }
}

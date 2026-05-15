import SwiftUI

struct ContentView: View {
  @Bindable var session: ChatSession

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
      Divider()
      inputRow
    }
    .task { await session.bootstrap() }
  }

  // MARK: - Sections

  private var header: some View {
    HStack {
      Text("QVAC Chat")
        .font(.headline)
      Spacer()
      statusBadge
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private var statusBadge: some View {
    switch session.bootstrapState {
    case .notStarted, .starting:
      Label("Booting…", systemImage: "hourglass")
        .foregroundStyle(.secondary)
    case .loadingModel(let modelId):
      Label("Loading \(modelId)…", systemImage: "arrow.down.circle")
        .foregroundStyle(.secondary)
    case .ready(let modelId):
      Label("Ready — \(modelId)", systemImage: "checkmark.seal.fill")
        .foregroundStyle(.green)
    case .failed(let msg):
      Label(msg, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .lineLimit(1)
    }
  }

  @ViewBuilder
  private var content: some View {
    if let bannerText = session.error?.bannerText {
      errorBanner(bannerText)
    }

    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(session.messages) { msg in
            MessageBubble(message: msg).id(msg.id)
          }
        }
        .padding()
      }
      .onChange(of: session.messages.count) { _, _ in
        if let last = session.messages.last {
          withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
      }
    }
  }

  private func errorBanner(_ text: String) -> some View {
    HStack {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
      Text(text)
        .font(.callout)
      Spacer()
      Button("Dismiss") { session.error = nil }
        .buttonStyle(.bordered)
    }
    .padding(10)
    .background(Color.red.opacity(0.12))
  }

  private var inputRow: some View {
    HStack(spacing: 10) {
      TextField("Message…", text: $session.input, axis: .vertical)
        .lineLimit(1...5)
        .textFieldStyle(.roundedBorder)
        .onSubmit(handleSubmit)
        .disabled(!isReady || session.isStreaming)

      if session.isStreaming {
        Button("Cancel") { session.cancel() }
          .buttonStyle(.borderedProminent)
          .tint(.red)
      } else {
        Button("Send") { session.send() }
          .buttonStyle(.borderedProminent)
          .disabled(!isReady || session.input.isEmpty)
      }
    }
    .padding(12)
  }

  private var isReady: Bool {
    if case .ready = session.bootstrapState { return true }
    return false
  }

  private func handleSubmit() {
    if isReady && !session.isStreaming && !session.input.isEmpty {
      session.send()
    }
  }
}

// MARK: - Message bubble

struct MessageBubble: View {
  let message: ChatMessageItem

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      if message.role == .assistant {
        Image(systemName: "sparkles")
          .frame(width: 24, height: 24)
          .foregroundStyle(.purple)
      } else {
        Spacer().frame(width: 24)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(message.role == .user ? "You" : "Assistant")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(message.content + (message.isStreaming ? "▍" : ""))
          .textSelection(.enabled)
          .padding(10)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill(message.role == .user ? Color.blue.opacity(0.12) : Color.gray.opacity(0.08))
          )
      }
      if message.role == .user {
        Image(systemName: "person.crop.circle.fill")
          .frame(width: 24, height: 24)
          .foregroundStyle(.blue)
      } else {
        Spacer().frame(width: 24)
      }
    }
  }
}

// MARK: - QVACError → banner copy

import QVACClient

extension QVACError {
  fileprivate var bannerText: String {
    switch self {
    case .client(let code, let msg):
      return "Request rejected (\(code.wireName)): \(msg)"
    case .server(let code, let msg):
      return "Inference failed (\(code.wireName)): \(msg)"
    case .transport(.transportClosed):
      return "Worker disconnected. Restart the app."
    case .transport(let t):
      return "Transport: \(t.message)"
    case .unknown(_, let name, let msg):
      return "Unknown error \(name ?? "?"): \(msg)"
    }
  }
}

// MARK: - Previews

#Preview("Empty") {
  ContentView(session: ChatSession())
    .frame(width: 540, height: 600)
}

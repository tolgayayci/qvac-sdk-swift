import SwiftUI
import QVACClient

struct ChatView: View {
  @Bindable var vm: ChatViewModel

  var body: some View {
    VStack(spacing: 0) {
      messageList
      Divider()
      inputRow
    }
  }

  private var messageList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(vm.messages) { msg in
            HStack {
              if msg.role == .assistant { Spacer().frame(width: 24) }
              Text(msg.content)
                .padding(10)
                .background(msg.role == .user ? .blue.opacity(0.2) : .gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
              if msg.role == .user { Spacer().frame(width: 24) }
            }
            .id(msg.id)
          }
        }
        .padding()
      }
      .onChange(of: vm.messages.count) { _, _ in
        if let last = vm.messages.last {
          withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
      }
    }
  }

  private var inputRow: some View {
    HStack {
      TextField("Message…", text: $vm.input)
        .textFieldStyle(.roundedBorder)
        .onSubmit { vm.send() }
        .disabled(vm.isStreaming)

      if vm.isStreaming {
        Button("Cancel") { vm.cancel() }
          .buttonStyle(.borderedProminent)
          .tint(.red)
      } else {
        Button("Send") { vm.send() }
          .buttonStyle(.borderedProminent)
          .disabled(vm.input.isEmpty)
      }
    }
    .padding()
  }
}

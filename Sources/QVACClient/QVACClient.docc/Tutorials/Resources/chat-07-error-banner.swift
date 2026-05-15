// In ChatView's body, above the message list:

if let bannerText = vm.errorBannerText {
  HStack {
    Image(systemName: "exclamationmark.triangle.fill")
    Text(bannerText)
    Spacer()
    Button("Dismiss") { vm.dismissError() }
      .buttonStyle(.bordered)
  }
  .padding()
  .background(.red.opacity(0.15))
}

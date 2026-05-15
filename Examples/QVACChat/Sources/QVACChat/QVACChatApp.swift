import SwiftUI

@main
struct QVACChatApp: App {
  /// Singleton chat state owned for the lifetime of the app.
  /// The view model bootstraps the QVACClient asynchronously on
  /// first appearance; the UI shows a loading state until ready.
  @State private var session = ChatSession()

  var body: some Scene {
    WindowGroup("QVAC Chat") {
      ContentView(session: session)
        .frame(minWidth: 480, minHeight: 600)
    }
    .commands {
      CommandGroup(after: .newItem) {
        Button("New Chat") { session.reset() }
          .keyboardShortcut("n", modifiers: [.command])
      }
    }
  }
}

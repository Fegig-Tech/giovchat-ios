import GiovChat
import GiovChatCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var chat: SampleChat
    @State private var showChat = false

    init(chat: SampleChat) {
        _chat = ObservedObject(wrappedValue: chat)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Your app")
                    .font(.largeTitle.weight(.bold))
                Button {
                    showChat = true
                } label: {
                    Label("Chat with us", systemImage: "bubble.left.and.bubble.right")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .overlay(alignment: .topTrailing) {
                    if chat.unread > 0 {
                        Text("\(chat.unread)")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 8, y: -8)
                            .accessibilityLabel("\(chat.unread) unread replies")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The controller outlives the chat sheet, so the app forwards foreground / background itself.
        .giovLifecycle(chat.controller)
        .sheet(isPresented: $showChat) {
            GiovChatView(
                controller: chat.controller,
                forwardLifecycle: false,   // done above
                onClose: { showChat = false }
            )
            // .giovChatStyle(GiovChatStyle(primaryColor: .indigo, theme: .auto))
        }
    }
}

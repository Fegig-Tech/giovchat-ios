#if canImport(SwiftUI)
import GiovChatCore
import SwiftUI

/// Forwards the scene's foreground / background changes to a controller.
@MainActor
struct GiovLifecycleModifier: ViewModifier {
    let controller: GiovChatController
    let enabled: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(controller: GiovChatController, enabled: Bool) {
        self.controller = controller
        self.enabled = enabled
    }

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { phase in
            guard enabled else { return }
            switch phase {
            case .active: controller.onForeground()
            case .background: controller.onBackground()
            default: break
            }
        }
    }
}

extension View {
    /// Forwards the scene's foreground / background changes to `controller` (`onForeground()` / `onBackground()`)
    /// while this view is on screen. ``GiovChatView`` does this itself; use it for a controller that outlives the
    /// chat screen, such as a `keepConnected` one that counts unread replies, and pass `forwardLifecycle: false` to
    /// the chat view.
    public func giovLifecycle(_ controller: GiovChatController) -> some View {
        modifier(GiovLifecycleModifier(controller: controller, enabled: true))
    }
}
#endif

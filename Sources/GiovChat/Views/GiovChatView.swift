#if canImport(SwiftUI) && canImport(ImageIO)
import GiovChatCore
import SwiftUI

/// The full Giov chat screen. Present it in a sheet, push it in a navigation stack or give it a whole window; it
/// fills the space it is given and keeps clear of the safe areas and the keyboard.
///
/// ```swift
/// .sheet(isPresented: $showChat) {
///     GiovChatView(tenantKey: "YOUR_WORKSPACE_KEY", onClose: { showChat = false })
/// }
/// ```
///
/// It draws every phase of the session (loading, pre-chat form, greeting, connecting, active conversation, error
/// with "Try again"), forwards the scene's foreground / background changes to the controller and tells it whether the
/// chat is on screen. Opening it never creates an empty conversation: the first message (or the pre-chat form) starts
/// one. The dashboard's colour and theme apply unless overridden with ``SwiftUI/View/giovChatStyle(_:)``.
///
/// Links and attachments open through the environment's `openURL` action, so set
/// `.environment(\.openURL, OpenURLAction { ... })` to open them in-app. Only http(s) and mailto links are tappable.
@MainActor
public struct GiovChatView: View {
    private enum Source {
        case owned(GiovOwnedOptions)
        case external(GiovChatController, autoStart: Bool, forwardLifecycle: Bool, initialContact: GiovContact?)
    }

    private let source: Source
    private let onClose: (() -> Void)?

    /// A chat screen that creates its own ``GiovChatController``, starts it when it appears and closes it when the
    /// view goes away. The arguments are read when the controller is created; changing the connection arguments
    /// (`tenantKey`, `baseURL`, `contact`, `sessionKey`, `keepConnected`, `locale`) creates a new one.
    ///
    /// - Parameters:
    ///   - tenantKey: the workspace key (public; Settings > Chat widget in the dashboard).
    ///   - baseURL: the API origin; leave the default for Giov Cloud.
    ///   - contact: what you know about the visitor (see ``GiovContact`` for the signed `userId` + `userHash`); it
    ///     also pre-fills the pre-chat form.
    ///   - sessionKey: separates stored conversations of the same visitor, e.g. per account.
    ///   - sessionStore: where the session secret lives between launches; the Keychain by default.
    ///   - keepConnected: stay connected while the chat is hidden (app in the foreground) to count unread replies.
    ///   - locale: BCP 47 language of the interface text; defaults to the device language.
    ///   - strings: replaces interface strings, e.g. `{ $0.withOverrides(sendMessage: "Enviar") }`.
    ///   - onClose: shows a close button in the header when set.
    ///   - onError, onConversationStart, onConnectionStatusChange, onUnreadCountChange: the controller's callbacks.
    public init(
        tenantKey: String,
        baseURL: String = giovDefaultBaseURL,
        contact: GiovContact? = nil,
        sessionKey: String? = nil,
        sessionStore: (any GiovSessionStore)? = nil,
        keepConnected: Bool = false,
        locale: String? = nil,
        strings: ((GiovChatStrings) -> GiovChatStrings)? = nil,
        onClose: (() -> Void)? = nil,
        onError: ((GiovChatError) -> Void)? = nil,
        onConversationStart: ((String) -> Void)? = nil,
        onConnectionStatusChange: ((GiovConnectionStatus) -> Void)? = nil,
        onUnreadCountChange: ((Int) -> Void)? = nil
    ) {
        source = .owned(GiovOwnedOptions(
            tenantKey: tenantKey,
            baseURL: baseURL,
            contact: contact,
            sessionKey: sessionKey,
            sessionStore: sessionStore,
            keepConnected: keepConnected,
            locale: locale,
            strings: strings,
            onError: onError,
            onConversationStart: onConversationStart,
            onConnectionStatusChange: onConnectionStatusChange,
            onUnreadCountChange: onUnreadCountChange
        ))
        self.onClose = onClose
    }

    /// A chat screen on a controller you own. The view never closes it; when the view goes away the chat is marked
    /// not visible, so a `keepConnected` controller keeps counting unread replies.
    ///
    /// - Parameters:
    ///   - controller: the controller to show.
    ///   - autoStart: start the controller when the screen first appears. Safe for a controller that is already
    ///     started (a shared `keepConnected` one): ``GiovChatController/start()`` then does nothing.
    ///   - forwardLifecycle: forward the scene's foreground / background changes. Pass false when you use
    ///     ``SwiftUI/View/giovLifecycle(_:)`` yourself for a controller that outlives this screen.
    ///   - initialContact: pre-fills the pre-chat form.
    ///   - onClose: shows a close button in the header when set.
    public init(
        controller: GiovChatController,
        autoStart: Bool = true,
        forwardLifecycle: Bool = true,
        initialContact: GiovContact? = nil,
        onClose: (() -> Void)? = nil
    ) {
        source = .external(controller, autoStart: autoStart, forwardLifecycle: forwardLifecycle, initialContact: initialContact)
        self.onClose = onClose
    }

    public var body: some View {
        switch source {
        case .owned(let options):
            GiovOwnedChatView(options: options, onClose: onClose)
                .id(options.identity)
        case .external(let controller, let autoStart, let forwardLifecycle, let initialContact):
            GiovChatScreen(
                controller: controller,
                autoStart: autoStart,
                forwardLifecycle: forwardLifecycle,
                initialContact: initialContact,
                onClose: onClose
            )
        }
    }
}

/// What the view-owned controller is created from.
struct GiovOwnedOptions {
    var tenantKey: String
    var baseURL: String
    var contact: GiovContact?
    var sessionKey: String?
    var sessionStore: (any GiovSessionStore)?
    var keepConnected: Bool
    var locale: String?
    var strings: ((GiovChatStrings) -> GiovChatStrings)?
    var onError: ((GiovChatError) -> Void)?
    var onConversationStart: ((String) -> Void)?
    var onConnectionStatusChange: ((GiovConnectionStatus) -> Void)?
    var onUnreadCountChange: ((Int) -> Void)?

    /// Changes when a new controller is needed.
    var identity: String {
        let parts: [String?] = [
            tenantKey, baseURL, sessionKey, keepConnected ? "keep" : "", locale,
            contact?.userId, contact?.userHash, contact?.email, contact?.phone, contact?.firstName, contact?.lastName,
        ]
        return parts.map { $0 ?? "\u{0}" }.joined(separator: "\u{1}")
    }
}

/// Holds the controller a ``GiovChatView`` created and closes it when the view's state is released.
final class GiovControllerHolder: ObservableObject {
    let controller: GiovChatController

    @MainActor
    init(options: GiovOwnedOptions) {
        controller = GiovChatController(
            tenantKey: options.tenantKey,
            baseURL: options.baseURL,
            contact: options.contact,
            sessionKey: options.sessionKey,
            sessionStore: options.sessionStore,
            keepConnected: options.keepConnected,
            visible: true,
            locale: options.locale,
            overrideStrings: options.strings,
            onError: options.onError,
            onConversationStart: options.onConversationStart,
            onConnectionStatusChange: options.onConnectionStatusChange,
            onUnreadCountChange: options.onUnreadCountChange
        )
    }

    deinit {
        let controller = controller
        Task { @MainActor in controller.close() }
    }
}

@MainActor
struct GiovOwnedChatView: View {
    let options: GiovOwnedOptions
    let onClose: (() -> Void)?
    @StateObject private var holder: GiovControllerHolder

    init(options: GiovOwnedOptions, onClose: (() -> Void)?) {
        self.options = options
        self.onClose = onClose
        _holder = StateObject(wrappedValue: GiovControllerHolder(options: options))
    }

    var body: some View {
        GiovChatScreen(
            controller: holder.controller,
            autoStart: true,
            forwardLifecycle: true,
            initialContact: options.contact,
            onClose: onClose
        )
    }
}

/// The screen itself, on any controller.
@MainActor
struct GiovChatScreen: View {
    @ObservedObject var controller: GiovChatController
    let autoStart: Bool
    let forwardLifecycle: Bool
    let initialContact: GiovContact?
    let onClose: (() -> Void)?

    @StateObject private var draft = GiovDraftModel()
    @State private var started = false
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.giovChatStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        controller: GiovChatController,
        autoStart: Bool,
        forwardLifecycle: Bool,
        initialContact: GiovContact?,
        onClose: (() -> Void)?
    ) {
        _controller = ObservedObject(wrappedValue: controller)
        self.autoStart = autoStart
        self.forwardLifecycle = forwardLifecycle
        self.initialContact = initialContact
        self.onClose = onClose
    }

    var body: some View {
        let state = controller.state
        let strings = controller.strings
        let look = GiovLook(
            style: style,
            config: state.config,
            systemDark: systemScheme == .dark,
            strings: strings,
            reduceMotion: reduceMotion
        )
        let content = GiovScreenContent(state, strings: strings)
        VStack(spacing: 0) {
            GiovHeaderView(
                model: GiovHeaderModel(state, strings: strings),
                look: look,
                privacyURL: giovPrivacyPolicyURL(state.config),
                onClose: onClose
            )
            Group {
                switch content {
                case .skeleton:
                    GiovSkeletonView(look: look)
                case .error(let message):
                    GiovErrorView(message: message, look: look) {
                        Task { await controller.retry() }
                    }
                case .preChat:
                    GiovPreChatForm(fields: state.requiredFields, initial: initialContact, look: look) { contact in
                        Task { await controller.submitContact(contact) }
                    }
                case .conversation:
                    GiovConversationView(controller: controller, state: state, draft: draft, look: look)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if state.config?.showBranding != false {
                GiovBrandingView()
            }
        }
        .background(look.background.ignoresSafeArea())
        .environment(\.colorScheme, look.dark ? .dark : .light)
        .tint(look.primary)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .modifier(GiovLifecycleModifier(controller: controller, enabled: forwardLifecycle))
        .onAppear {
            controller.setVisible(true)
            if autoStart && !started {
                started = true
                Task { await controller.start() }
            }
        }
        .onDisappear {
            controller.setVisible(false)
        }
    }
}

/// What the visitor is composing, kept while the screen shows another phase (an error, a reconnect).
@MainActor
final class GiovDraftModel: ObservableObject {
    @Published var text = ""
    @Published var files: [GiovPickedFile] = []
    /// Why the last pick was refused, as a sentence.
    @Published var problem: String?
    /// A send is in flight.
    @Published var busy = false
}
#endif

#if canImport(SwiftUI)
import GiovChatCore
import SwiftUI

/// Look overrides for ``GiovChatView``. Every field is optional: the dashboard's brand colour and light / dark /
/// auto theme apply wherever one is not set. Layout, sizes and the "Powered by GiovChat" footer stay
/// SDK-controlled, as in the other SDKs.
///
/// ```swift
/// GiovChatView(tenantKey: "ws_123")
///     .giovChatStyle(GiovChatStyle(primaryColor: .indigo, theme: .dark))
/// ```
///
/// Text drawn on a coloured surface (header, visitor bubbles, buttons) is near-black or white, whichever reads on it.
public struct GiovChatStyle: Sendable, Equatable {
    /// The brand colour: header, visitor bubbles and buttons. Default: the dashboard's.
    public var primaryColor: Color?
    /// `light`, `dark` or `auto` (follow the device). Default: the dashboard's.
    public var theme: GiovThemeMode?
    /// Background of the chat surface.
    public var backgroundColor: Color?
    /// Header background; default: the brand colour.
    public var headerColor: Color?
    /// The visitor's bubbles; default: the brand colour.
    public var visitorBubbleColor: Color?
    /// Agent, greeting and typing bubbles.
    public var agentBubbleColor: Color?

    public init(
        primaryColor: Color? = nil,
        theme: GiovThemeMode? = nil,
        backgroundColor: Color? = nil,
        headerColor: Color? = nil,
        visitorBubbleColor: Color? = nil,
        agentBubbleColor: Color? = nil
    ) {
        self.primaryColor = primaryColor
        self.theme = theme
        self.backgroundColor = backgroundColor
        self.headerColor = headerColor
        self.visitorBubbleColor = visitorBubbleColor
        self.agentBubbleColor = agentBubbleColor
    }
}

private struct GiovChatStyleKey: EnvironmentKey {
    static let defaultValue = GiovChatStyle()
}

extension EnvironmentValues {
    /// The style ``GiovChatView`` draws with; set it with ``SwiftUI/View/giovChatStyle(_:)``.
    public var giovChatStyle: GiovChatStyle {
        get { self[GiovChatStyleKey.self] }
        set { self[GiovChatStyleKey.self] = newValue }
    }
}

extension View {
    /// Overrides the look of the ``GiovChatView`` inside this view.
    public func giovChatStyle(_ style: GiovChatStyle) -> some View {
        environment(\.giovChatStyle, style)
    }
}
#endif

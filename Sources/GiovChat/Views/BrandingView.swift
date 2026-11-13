#if canImport(SwiftUI) && canImport(ImageIO)
import GiovChatCore
import SwiftUI

/// The "Powered by GiovChat" footer as a component, for apps that build their own chat UI on ``GiovChatController``.
///
/// It follows ``GiovChatStyle/branding`` (and ``GiovChatStyle/fontName``) from the environment (set it with
/// ``SwiftUI/View/giovChatStyle(_:)``), and shows unless the workspace removed the branding (Business and Advanced
/// plans). The style cannot hide it: colours are used only while they stay readable (4.5:1), the size and layout are
/// fixed.
///
/// ```swift
/// VStack {
///     MyMessages()
///     GiovBrandingView(controller: chat)   // or GiovBrandingView(showBranding: config.showBranding)
/// }
/// ```
@MainActor
public struct GiovBrandingView: View {
    private enum Source {
        case fixed(Bool)
        case controller(GiovChatController)
    }

    private let source: Source

    /// Follows the controller: shown unless its configuration says `showBranding: false`. While the configuration is
    /// loading nothing is drawn, unless the chat failed (then the footer shows).
    public init(controller: GiovChatController) {
        source = .controller(controller)
    }

    /// Shown or not as given (for example your own copy of the workspace's `showBranding`).
    public init(showBranding: Bool) {
        source = .fixed(showBranding)
    }

    public var body: some View {
        switch source {
        case .fixed(let shown):
            if shown { GiovBrandingFooter() }
        case .controller(let controller):
            GiovControllerBranding(controller: controller)
        }
    }
}

@MainActor
private struct GiovControllerBranding: View {
    @ObservedObject var controller: GiovChatController

    var body: some View {
        let state = controller.state
        if giovShowsBranding(explicit: nil, config: state.config, phase: state.phase) {
            GiovBrandingFooter()
        }
    }
}

/// The footer itself.
@MainActor
struct GiovBrandingFooter: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.giovChatStyle) private var style

    var body: some View {
        let colors = giovResolveBranding(
            text: giovComponents(style.branding?.textColor),
            brand: giovComponents(style.branding?.brandColor),
            background: giovComponents(style.branding?.backgroundColor)
        )
        let fontName = style.branding?.fontName ?? style.fontName
        let font: Font = fontName.map { Font.custom($0, size: 12, relativeTo: .caption) } ?? .caption
        Button {
            openURL(giovBrandingURL)
        } label: {
            (Text(verbatim: "Powered by ") + Text(verbatim: "GiovChat").bold().foregroundColor(Color(colors.brand)))
                .font(font)
                .foregroundColor(Color(colors.text))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "Powered by GiovChat"))
        .background(Color(colors.background).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(colors.customBackground ? Color.gray.opacity(0.3) : Color(GiovRGB(rgb: 0xEBEBEB)))
                .frame(height: 0.5)
        }
        .onAppear {
            #if DEBUG
            for warning in colors.warnings { print("[GiovChat] \(warning)") }
            #endif
        }
    }
}
#endif

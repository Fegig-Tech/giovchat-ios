import Foundation

/// The push service a device token belongs to (docs/protocol/README.md, "Push notifications").
public enum GiovPushPlatform: String, Sendable, Equatable {
    /// Apple Push Notification service: the hex device token from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    case apns
    /// Firebase Cloud Messaging, for apps that receive pushes through Firebase.
    case fcm
}

/// Which APNs environment issued the token.
public enum GiovPushEnvironment: String, Sendable, Equatable {
    /// Development builds (Xcode, `aps-environment = development`).
    case sandbox
    /// App Store and TestFlight builds.
    case production

    /// `sandbox` for a DEBUG build of the app, `production` otherwise. Pass it explicitly when your release
    /// configuration differs.
    public static var current: GiovPushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

/// What a push registration carries besides the token.
public struct GiovPushOptions: Sendable, Equatable {
    /// APNs only: ``GiovPushEnvironment/sandbox`` for development builds, production for the App Store.
    public var environment: GiovPushEnvironment?
    /// The bundle id.
    public var appId: String?
    /// BCP 47 language for the generic notification text; defaults to the chat's locale.
    public var locale: String?

    public init(environment: GiovPushEnvironment? = nil, appId: String? = nil, locale: String? = nil) {
        self.environment = environment
        self.appId = appId
        self.locale = locale
    }
}

/// Why a push registration did not happen.
public enum GiovPushFailure: String, Sendable, Equatable {
    /// The server has no visitor push (404, 405 or 501); the client stops asking.
    case unsupported
    case noConversation
    case failed
}

/// The outcome of ``GiovChatController/registerPushToken(_:platform:environment:appId:locale:)``; it never throws.
public struct GiovPushResult: Sendable, Equatable, CustomStringConvertible {
    public let failure: GiovPushFailure?

    public var registered: Bool { failure == nil }

    public var description: String { registered ? "GiovPushResult.registered" : "GiovPushResult(\(failure!.rawValue))" }

    static let registered = GiovPushResult(failure: nil)

    static func notRegistered(_ failure: GiovPushFailure) -> GiovPushResult { GiovPushResult(failure: failure) }
}

/// An APNs device token as the lowercase hex string the server expects.
public func giovAPNsTokenString(_ deviceToken: Data) -> String {
    deviceToken.map { String(format: "%02x", $0) }.joined()
}

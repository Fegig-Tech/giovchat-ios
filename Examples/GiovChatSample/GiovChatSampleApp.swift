import GiovChat
import GiovChatCore
import SwiftUI

@main
struct GiovChatSampleApp: App {
    // Push notifications: uncomment the delegate below and this line.
    // @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(chat: SampleChat.shared)
        }
    }
}

/// One chat for the whole app: it stays connected while the app is in the foreground so the badge can count
/// replies, and the chat sheet shows it.
@MainActor
final class SampleChat: ObservableObject {
    static let shared = SampleChat()

    let controller: GiovChatController
    @Published private(set) var unread = 0
    private var observation: GiovObservation?

    private init() {
        let controller = GiovChatController(
            tenantKey: "YOUR_WORKSPACE_KEY",   // Settings > Chat widget in the dashboard (public)
            // contact: GiovContact(userId: account.id, userHash: hashFromYourServer, email: account.email),
            keepConnected: true,
            visible: false
        )
        self.controller = controller
        observation = GiovUnread.observe { [weak self] count in
            self?.unread = count
        }
        Task { await controller.start() }
    }
}

/*
 // APNs: enable the Push Notifications capability, upload your APNs key in the dashboard
 // (Settings > Chat widget > Push notifications), then register the device token with the chat.

 import UIKit
 import UserNotifications

 final class AppDelegate: NSObject, UIApplicationDelegate {
     func application(
         _ application: UIApplication,
         didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
     ) -> Bool {
         UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
             guard granted else { return }
             Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
         }
         return true
     }

     func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
         Task { @MainActor in
             // Registers now when connected, otherwise as soon as the conversation connects. Never throws.
             let result = await SampleChat.shared.controller.registerPushToken(deviceToken: deviceToken)
             print("Giov push:", result)
         }
     }

     func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
         print("APNs registration failed:", error)
     }
 }

 // Using Firebase Cloud Messaging instead? Register the FCM token:
 //     await SampleChat.shared.controller.registerPushToken(fcmToken, platform: .fcm)
 */

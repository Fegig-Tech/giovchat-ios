# Giov chat for iOS

Add the Giov visitor chat to an iOS app: the same conversations, bot (GiovBot) and team inbox as the web widget and
the React Native, Flutter and Android SDKs.

| Product | What it is |
| --- | --- |
| `GiovChatCore` | Pure Swift: config, sessions (Keychain), realtime socket, outbox, streaming replies, attachments, unread counts, push registration and the chat markdown parser. No UI. |
| `GiovChat` | SwiftUI chat screen on top of the core: `GiovChatView(...)`. |
| `Examples/GiovChatSample` | Sources for a sample app: an unread badge, the chat in a sheet, and commented APNs registration. |

Requires iOS 16 or newer (macOS 13 for the core and the screen on the Mac) and Xcode 16 or newer (Swift 6). No
third-party dependencies. The behaviour follows the Giov visitor protocol, so it matches the other SDKs. Guides and
the dashboard settings it relies on are at [giovchat.app/docs](https://giovchat.app/docs).

## Install

The package is installed with Swift Package Manager from `https://github.com/Fegig-Tech/giovchat-ios`.

- **Xcode:** File > Add Package Dependencies…, paste `https://github.com/Fegig-Tech/giovchat-ios` in the search
  field, choose the dependency rule (for example **Up to Next Major Version** from `0.1.0`) and click Add Package.
  Add **GiovChat** to your app target (it brings `GiovChatCore`); choose only **GiovChatCore** if you build your own
  UI.
- **Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/Fegig-Tech/giovchat-ios", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "GiovChat", package: "giovchat-ios"),          // the screen; brings GiovChatCore
        // .product(name: "GiovChatCore", package: "giovchat-ios"),   // only the controller, for your own UI
    ]),
]
```

While the version is 0.x, minor versions may contain breaking changes; `.upToNextMinor(from: "0.1.0")` pins you to
0.1.x if you prefer to upgrade by hand. Changes are listed in [CHANGELOG.md](CHANGELOG.md).

No `Info.plist` keys are needed: photos are picked with the system photo picker and files with the Files picker,
which ask for no permission.

## Quick start

```swift
import GiovChat

struct SupportButton: View {
    @State private var showChat = false

    var body: some View {
        Button("Chat with us") { showChat = true }
            .sheet(isPresented: $showChat) {
                GiovChatView(
                    tenantKey: "YOUR_WORKSPACE_KEY",   // Settings > Chat widget in the dashboard (public)
                    onClose: { showChat = false }
                )
            }
    }
}
```

`GiovChatView` fills the space it is given, so it works in a sheet, a navigation destination, a tab or a whole
window. It draws every phase (loading skeleton, pre-chat form, greeting, connecting, active conversation, error with
"Try again"), forwards the scene's foreground/background changes to the controller, and tells it whether the chat is
on screen. Opening the screen never creates an empty conversation: the first message (or the pre-chat form) starts
one.

The dashboard decides the brand colour, the light/dark/auto theme, the greeting, the composer placeholder, the
pre-chat fields and whether "Powered by GiovChat" shows. You can override colour and theme in code (see Theming).

## Controller vs view

There are two ways in, and both end up in the same screen.

**Let the view own the controller.** `GiovChatView(tenantKey: ...)` creates a `GiovChatController`, starts it when it
appears and closes it when the view goes away. Pass the connection options straight to it: `baseURL`, `contact`,
`sessionKey`, `sessionStore`, `keepConnected`, `locale`, `strings` and the `onError` / `onConversationStart` /
`onConnectionStatusChange` / `onUnreadCountChange` callbacks. Changing `tenantKey`, `baseURL`, `contact`,
`sessionKey`, `keepConnected` or `locale` creates a new controller.

**Own the controller yourself** when something else needs it (push registration, sign-out, an unread badge, a chat
that must keep counting replies while the screen is closed):

```swift
@MainActor
final class Support: ObservableObject {
    static let shared = Support()
    let chat = GiovChatController(tenantKey: "YOUR_WORKSPACE_KEY", keepConnected: true, visible: false)
    private init() { Task { [chat] in await chat.start() } }
}

// In a view:
GiovChatView(controller: Support.shared.chat, forwardLifecycle: false, onClose: { ... })

// Once, high in the view tree, for a controller that outlives the chat screen:
RootView().giovLifecycle(Support.shared.chat)       // onForeground / onBackground from the scene phase
```

The view never closes a controller you pass in; when it goes away it marks the chat not visible, so a
`keepConnected` controller keeps counting unread replies. Call `close()` when you no longer need the controller.

Using no SwiftUI? `GiovChatCore` is the same engine: read `controller.state` (a `GiovChatUiState`), subscribe with
`controller.observe { state in ... }` (or `@ObservedObject`, it is an `ObservableObject`) and call `send`,
`submitContact`, `retry`, `reset`, `retryMessage`, `discardMessage`, `notifyTyping`, `checkFiles`,
`registerPushToken`. Everything runs on the main actor.

### `GiovChatView` parameters

| Parameter | Purpose |
| --- | --- |
| `onClose` | Shows a close button in the header when set (both initialisers). The header menu always links to the workspace's privacy policy (`privacyPolicyUrl`, else Giov's), as in the web widget. |
| `controller` | A controller you own; the view never closes it. |
| `autoStart` | Start that controller when the screen first appears (default `true`). Safe for a controller that is already started: `start()` then does nothing, so the socket and a reply being written are kept. |
| `forwardLifecycle` | Forward the scene's foreground/background changes (default `true`). Turn off when you use `.giovLifecycle(_:)`. |
| `initialContact` | Pre-fills the pre-chat form (the `tenantKey` initialiser uses `contact`). |

`GiovChatView(tenantKey: ...)` also takes `baseURL`, `contact`, `sessionKey`, `sessionStore`, `keepConnected`,
`locale`, `strings` and the four callbacks.

Links and attachments open through SwiftUI's `openURL` environment action (Safari or the mail app by default). To
open them in-app, set your own action around the chat:

```swift
GiovChatView(tenantKey: "...")
    .environment(\.openURL, OpenURLAction { url in
        router.showInAppBrowser(url)
        return .handled
    })
```

Only `http(s)` and `mailto:` links are tappable; anything else stays plain text.

## Session storage

The session token is a bearer secret that proves the device owns the conversation. By default it is kept in the
**Keychain** (`KeychainGiovSessionStore`: a generic password, readable after the first unlock, never synced or moved
to another device), so visitors resume their conversation across launches. Pass
`KeychainGiovSessionStore(accessGroup: "TEAMID.group.example")` to share it with an app extension, or implement
`GiovSessionStore` (three async methods) to keep it somewhere else; `InMemoryGiovSessionStore` forgets it when the
process ends. On macOS the item goes to the data protection keychain when the app has a keychain entitlement (signed
with a team), else to the login keychain.

The store is keyed by API, workspace, `userId` and `sessionKey` (not by name, email or phone, so filling in the
pre-chat form keeps the conversation), so signing in as someone else never resumes the previous person's conversation. Call `await controller.reset()` on sign-out to forget the conversation,
the stored session and the outbox. Storage failures are reported through `onError` (a `GiovChatError` of kind
`.storage`) and never crash the chat. A read that fails (the Keychain refuses reads until the device is first
unlocked after a restart, e.g. for an app woken by a push) is tried again before a new conversation is started, so
the stored one is never replaced by mistake.

## Identity (`userId` + `userHash`)

Tell the chat who the visitor is so the team sees the right customer across devices:

```swift
GiovChatView(
    tenantKey: "YOUR_WORKSPACE_KEY",
    contact: GiovContact(
        userId: account.id,
        userHash: account.giovUserHash,   // HMAC-SHA256(identity secret, userId), lowercase hex
        email: account.email,
        firstName: account.firstName
    )
)
```

`userHash` must be computed **on your server** with the identity secret from the dashboard and sent to the app after
sign-in. Never put the identity secret in the app. A `userId` without a matching `userHash` is treated like any other
untrusted detail. Details you supply also pre-fill the pre-chat form, which asks only for the fields the workspace
requires and you did not provide (and that are valid).

## Attachments

Attachments need nothing from you. Once a conversation exists (uploads need one) and the bot's policy allows any file
type, the composer shows an attach button that offers the system photo picker (`PhotosPicker`) and the Files picker
(`fileImporter`), limited to the types the bot accepts. Neither asks for a permission. The screen checks what was
picked against the policy (`controller.checkFiles`), shows the problems as a sentence and the files as removable
chips, and uploads with progress when the visitor sends.

Photos in formats the server does not take (HEIC) are re-encoded as JPEG, and every image gets its size and a tiny
blurred placeholder (`GiovImagePlaceholder`) so other viewers see its shape before it loads. Files must be one of the
supported types (images, PDF, text/CSV, Office documents, audio), within the bot's size limit (at most 10 MB) and at
most 5 per message. Messages show an image box of its final shape immediately, the blurred placeholder while the
picture loads, and other files as tappable rows. Downloads carry exactly one credential
(`controller.attachmentURL`).

## Unread badge

A controller created with `keepConnected: true` stays connected while the chat is closed (and the app is in the
foreground), counts replies the visitor has not seen and never starts a conversation. Read the total anywhere:

```swift
@MainActor
final class Badge: ObservableObject {
    @Published var unread = 0
    private var observation: GiovObservation?
    init() {
        observation = GiovUnread.observe { [weak self] count in self?.unread = count }   // all chats
        // GiovUnread.observe(tenantKey: "YOUR_WORKSPACE_KEY") { ... } for one workspace
    }
}
```

Opening the chat (the view appearing) clears the count.

## Push notifications

When the chat is closed and the app is in the background, replies arrive as push notifications.

1. In the dashboard, under **Settings -> Chat widget -> Push notifications**, upload your APNs authentication key (or
   your Firebase service account if your app receives pushes through Firebase).
2. Add the **Push Notifications** capability to the app and register the device token with the controller:

```swift
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            _ = await Support.shared.chat.registerPushToken(deviceToken: deviceToken)   // never throws
        }
    }
}

// In your App: @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
// and call UIApplication.shared.registerForRemoteNotifications() after the notification permission is granted.
```

APNs is the default platform. The environment defaults to `sandbox` in DEBUG builds and `production` otherwise; pass
`environment:` when your configurations differ. Apps that use Firebase Cloud Messaging register the FCM token instead:
`registerPushToken(fcmToken, platform: .fcm)`.

`registerPushToken` registers at once when the conversation is connected and otherwise as soon as it connects, so you
can call it right at start-up and again whenever the system hands out a new token. Called before the visitor has a
conversation, it waits for the first one (it returns `.notRegistered(.noConversation)` if the controller is closed or
reset first). The token is remembered and registered again by itself for each new conversation of the same visitor;
`reset()` forgets it. `unregisterPushToken(deviceToken:)` stops pushes on sign-out; it works while the chat is closed
or disconnected (it uses the stored session), so call it before `reset()`. Registrations carry the chat's language.

The push carries data you can use to open the chat when the visitor taps the notification:

```
{ "type": "giov.message", "tenantId": "...", "conversationId": "...", "messageId": "..." }
```

Handle it in `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)` and
present `GiovChatView` when `type == "giov.message"`. The sample app has the APNs wiring as comments.

## Languages and text

The interface text ships in English, French, Spanish, Portuguese and German and follows the device language. Pick one,
or replace individual strings:

```swift
GiovChatView(
    tenantKey: "...",
    locale: "pt-BR",                                              // "fr", "es", "de", ...
    strings: { $0.withOverrides(sendMessage: "Enviar", composerPlaceholder: "Escreva aqui…") }
)
```

For a controller you own, pass `locale:` and `overrideStrings:` to `GiovChatController`. Text the business writes in
the dashboard (greeting, placeholder, bot name) is shown as written and is not translated.

## Theming

The look comes from the dashboard (brand colour, light/dark/auto). Override it with a style:

```swift
GiovChatView(tenantKey: "...")
    .giovChatStyle(GiovChatStyle(
        primaryColor: Color(red: 0.05, green: 0.65, blue: 0.91),
        theme: .dark,                       // .light, .dark or .auto (device)
        backgroundColor: nil,
        headerColor: .black,
        visitorBubbleColor: nil,
        agentBubbleColor: nil
    ))
```

Every field is optional. Text on coloured surfaces (header, visitor bubbles, buttons) is near-black or white,
whichever reads. Layout, sizes, spacing, fonts (the system font with Dynamic Type) and the "Powered by GiovChat"
footer stay SDK-controlled, like the other SDKs.

### Accessibility

Targets are at least 44 pt, controls have VoiceOver labels in the chosen language, the header title is a heading,
errors are announced, the typing indicator says who is typing, and text follows Dynamic Type (up to the third
accessibility size so the layout holds). The typing dots stand still when Reduce Motion is on.

## Behaviour worth knowing

- A message you send shows at once as "Sending…", is queued in the outbox and goes out when a socket is open, so text
  typed while reconnecting is never lost. A message that cannot be delivered shows "Not sent · Tap to retry" and
  **Discard**.
- GiovBot replies stream in as a draft that is replaced in place by the saved reply (same list identity, nothing
  jumps).
- The list follows new messages while the visitor is at the bottom and keeps its place while they read older ones.
- The header shows the teammate once one has written, else the bot, else the team (name and photo from the dashboard).

## Privacy manifest

`GiovChatCore` ships a `PrivacyInfo.xcprivacy`, so it applies whether you use the screen or only the core. It
declares no tracking and no tracking domains, and no required-reason
APIs (the SDK does not use `UserDefaults`, file timestamps, system boot time, disk space or the active keyboards). It
declares the data the SDK sends to Giov so the business can provide support, all linked to the visitor, none used
for tracking, purpose App Functionality:

| Data type | When |
| --- | --- |
| Customer Support | Every chat message. |
| Photos or Videos / Other User Content | Images and files the visitor attaches. |
| Name, Email Address, Phone Number | When your app passes them in `GiovContact` or the visitor fills in the pre-chat form. |
| User ID | When your app passes `userId`. |
| Device ID | The push token, when your app registers one. |

Xcode merges it into your app's privacy report. Your App Store privacy answers should cover the same data; leave out
what your integration never sends (for example, no `userId` or no push).

## App size

Not measured yet. Expect a few hundred kilobytes for both products together: the SDK uses only system frameworks
(Foundation, SwiftUI, PhotosUI, ImageIO, Security), ships one 4 KB image and SF Symbols for icons, and has no
third-party dependencies. Only `GiovChatCore` is needed for a custom UI.

## What the SDK never does

- It never ships or asks for your identity secret, and never shows server error text to visitors.
- It never tracks visitors, collects analytics or contacts anything but your Giov API (and the image URLs messages
  carry).
- It never asks for photo library, camera, contacts or notification permission; your app decides about notifications.
- It never stores the session token outside the Keychain (unless you supply another `GiovSessionStore`), and never
  logs it.
- It never opens links other than `http(s)` and `mailto:`.
- It never creates a conversation until the visitor writes or submits the pre-chat form.

## Build and test

From a clone of the repository:

```
swift test
xcodebuild test -scheme GiovChat-Package -destination 'platform=iOS Simulator,name=iPhone 16'
```

The core tests and the screen's presentation tests (colours, header, bubbles, markdown, composer rules, attachments,
pre-chat validation) also run on Linux. The markdown parser is checked against the shared conformance vectors that
every Giov SDK runs (`Tests/GiovChatCoreTests/Fixtures/markdown-vectors.json`). CI
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs `swift test` on macOS and Linux, builds the package for
the iOS Simulator with warnings as errors and runs the tests on a simulator.

## Support and licence

Documentation: [giovchat.app/docs](https://giovchat.app/docs). Report problems in this repository's issues.

Released under the MIT licence; see [LICENSE](LICENSE).

# GiovChat sample app

A small SwiftUI app: a button with an unread badge (from a `keepConnected` controller) that opens the chat in a
sheet, plus commented APNs registration. The folder holds only Swift sources; create the Xcode app around them:

1. In Xcode, **File > New > Project > iOS > App**. Name it `GiovChatSample`, interface **SwiftUI**, language
   **Swift**, and save it anywhere (for example next to this folder).
2. Delete the generated `ContentView.swift` and `<Name>App.swift`, then drag `GiovChatSampleApp.swift` and
   `ContentView.swift` from this folder into the project (check "Copy items if needed" if you saved the project
   elsewhere).
3. **File > Add Package Dependencies…**, paste `https://github.com/Fegig-Tech/giovchat-ios` and add the
   **GiovChat** library to the app target (it brings `GiovChatCore`). To try local changes to the SDK instead, use
   **Add Local…** and pick the root of your clone (the folder with `Package.swift`).
4. Set the deployment target to iOS 16 or newer.
5. Replace `YOUR_WORKSPACE_KEY` in `GiovChatSampleApp.swift` with your workspace key (Settings > Chat widget in the
   dashboard) and run.

Push notifications: add the **Push Notifications** capability, upload your APNs key in the dashboard under
**Settings > Chat widget > Push notifications**, then uncomment the `AppDelegate` and the `@UIApplicationDelegateAdaptor`
line in `GiovChatSampleApp.swift`.

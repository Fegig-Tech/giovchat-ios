# Changelog

All notable changes to the Giov iOS SDK. The format follows Keep a Changelog; versions follow semantic versioning.

## [Unreleased]

## [0.2.0] - 2026-11-13

### Added

- The "Powered by GiovChat" footer follows the app's style: `GiovChatStyle.fontName` and
  `GiovChatStyle.branding` (`GiovBrandingStyle(fontName:textColor:brandColor:backgroundColor:)`). Colours are used only
  while they stay readable (opaque, 4.5:1 against the footer background), otherwise the defaults apply; the footer
  cannot be hidden by a style (only the workspace's `showBranding: false` removes it). `GiovBrandingView` is now public
  with `GiovBrandingView(controller:)` and `GiovBrandingView(showBranding:)` for custom UIs built on
  `GiovChatController`.

- Conversation ratings and answer feedback. The chat draws the rating card a teammate (or GiovBot) sends: five
  faces, an optional comment, "Thanks" with the chosen face afterwards, changes until the card closes, replaced and
  closed cards handled. GiovBot answers get thumbs up / down with an optional reason. Core API on
  `GiovChatController`: `submitRating(score:comment:requestId:)`, `submitAnswerFeedback(messageId:vote:reason:)`,
  `pendingRating` / `GiovChatUiState.ratingRequest`, `presentRating()` / `dismissRating()`, the callbacks
  `onRatingRequested`, `onRatingSubmitted` and `onAnswerFeedback`, and `showsRatingCard` / `showsAnswerFeedback` to
  turn the built-in UI off. Refusals are typed (`GiovChatError.ratingFailure`). Strings in all five languages
  (`GiovChatStrings.rating`). Older servers without the routes: the controls are hidden.
- Closed conversations stay on screen read-only (history, an open rating card) instead of being forgotten; the
  composer gives way to "Start a new conversation" (`GiovChatController.startNewConversation()`,
  `GiovChatUiState.conversationClosed`, `GiovChatStrings.startNewConversation`). A conversation that answers a resume
  with 409 is loaded read-only when the token allows.

## [0.1.0]

### Added

- `GiovChatCore`: the visitor protocol client in Swift 6 for iOS 16 and macOS 13: widget configuration, resumable
  sessions stored in the Keychain by default (pluggable `GiovSessionStore`), realtime socket with reconnect and
  history catch-up, the outbox (sending / sent / failed, retry, discard), GiovBot streaming drafts, typing, identity
  (`userId` + `userHash`), attachment policy checks, uploads with progress, image placeholders and authenticated
  downloads, unread counts (`GiovUnread`), APNs and FCM push registration, five languages and the chat markdown
  parser. `GiovChatController` runs on the main actor and is an `ObservableObject`. Ships the SDK's privacy
  manifest.
- `GiovChat`: `GiovChatView`, a SwiftUI chat screen on top of the core, with a `tenantKey` initialiser that owns its
  controller and a `controller` initialiser that never closes yours, plus `.giovLifecycle(_:)` and
  `.giovChatStyle(_:)`. Draws every phase (loading skeleton, pre-chat form, greeting, connecting, active, error with
  "Try again"), the header identity (person, bot, team) with avatars, markdown bubbles with http(s) / mailto links,
  sender labels, failed-message retry and discard, a streaming draft replaced in place by the saved reply, the typing
  indicator (still with Reduce Motion), attachments through the system photo and Files pickers (policy problems,
  upload progress, image placeholders, file rows), a multiline composer, the "Powered by GiovChat" footer when the
  workspace shows it, light / dark / auto from the dashboard with the brand colour, style overrides, locale and string
  overrides, keyboard and safe-area handling, and accessibility (44 pt targets, VoiceOver labels, Dynamic Type).
- `Examples/GiovChatSample`: sources for a SwiftUI app with an unread badge, the chat in a sheet and commented APNs
  registration.
- Swift Testing suites for the core and for the screen's presentation logic (both also run on Linux), including the
  shared markdown conformance vectors bundled as a test resource, and CI that tests on macOS and Linux, builds for
  the iOS Simulator with warnings as errors and runs the tests on a simulator.
- Distribution through Swift Package Manager from `https://github.com/Fegig-Tech/giovchat-ios`, under the MIT
  licence, with Swift Package Index documentation for both products.

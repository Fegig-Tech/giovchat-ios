import Foundation
#if canImport(Combine)
import Combine
#endif

/// How long after the last keystroke the agent stops seeing "typing" (the widget's value).
private let typingIdleMs = 2500

/// The state holder the chat UI observes. It runs the whole visitor session on top of the protocol client: it loads
/// the configuration, resumes a stored conversation, starts one when the visitor writes, keeps the socket up, catches
/// up on history after every reconnect, resends the outbox, shows streaming replies, counts unread replies and
/// registers push tokens.
///
/// ```swift
/// let chat = GiovChatController(tenantKey: "ws_123", contact: GiovContact(userId: id, userHash: hash))
/// Task { await chat.start() }
/// let observation = chat.observe { state in render(state) }   // or @ObservedObject / @StateObject in SwiftUI
/// await chat.send("Hello")
/// ```
///
/// Forward the app's lifecycle with ``onForeground()`` / ``onBackground()`` (scene phase changes), tell it whether
/// the chat screen is showing with ``setVisible(_:)``, and call ``close()`` when the controller is no longer needed.
///
/// **Threading.** The controller lives on the main actor: every method, ``state`` and every callback (`onError`,
/// `onConversationStart`, `onConnectionStatusChange`, `onUnreadCountChange`, observers) run there. `async` methods
/// return when their work is done; the others return at once and do their work in the background.
@MainActor
public final class GiovChatController {
    /// The workspace key (public; it is in every embed snippet).
    public let tenantKey: String
    /// The API origin in use, without a trailing slash.
    public let baseURL: String
    /// Stay connected while the chat is not visible (app in the foreground) to count unread replies. Never starts a
    /// conversation.
    public let keepConnected: Bool
    /// How long the app may be in the background before the socket is closed (so pushes arrive).
    public let backgroundGraceMs: Int
    /// The interface text for the resolved language.
    public let strings: GiovChatStrings
    /// The BCP 47 language the chat resolved to (one of ``giovLocales``).
    public let locale: String

    /// A failure worth knowing about (also shown in ``GiovChatUiState/error`` when the visitor should see it).
    public var onError: ((GiovChatError) -> Void)?
    /// A new conversation was created; its id.
    public var onConversationStart: ((String) -> Void)?
    public var onConnectionStatusChange: ((GiovConnectionStatus) -> Void)?
    /// Replies not seen while the chat was hidden; 0 while it is visible.
    public var onUnreadCountChange: ((Int) -> Void)?

    /// Everything the chat screen draws. A new value is published after every change.
    public private(set) var state: GiovChatUiState

    private let store: any GiovSessionStore
    private let scopeKey: String
    private let baseContact: GiovContact?
    private let clock: any GiovClock
    private let outbox: Outbox
    private let client: GiovChatClient
    private var outboxStop: (() -> Void)?
    /// The last session-store call; the next one waits for it (see ``storeOperation(_:)``).
    private var storeQueue: Task<Void, Never>?

    private var contact: GiovContact
    private var session: GiovSession?
    private var loadedStore = false
    private var startNow = false
    private var started = false
    private var disposed = false
    private var visible: Bool
    private var foreground = true
    private var wanted = false
    private var generation = 0
    private var forgottenGeneration = -1
    private var graceTask: Task<Void, Never>?
    private var typingTask: Task<Void, Never>?
    private var typingSent = false
    private var catchUpGeneration: Int?
    private var openedOnce = false
    private var pushRequest: PushRequest?
    /// The device token the host registered last; registered again for every new conversation of this visitor.
    private var pushToken: (token: String, platform: GiovPushPlatform, options: GiovPushOptions)?
    /// A new conversation started: register ``pushToken`` once its socket opens.
    private var pushOnConnect = false
    /// The first ``start()`` pass, which later calls wait for instead of restarting.
    private var firstPass: Task<Void, Never>?
    /// Failed first connections so far, for the backoff; reset once a socket opens.
    private var connectAttempt = 0
    /// A retry of a failed first connection is waiting for its backoff.
    private var connectRetryPending = false
    private let random: @Sendable () -> Double
    private var localFiles: [String: GiovAttachment] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextTask = 0
    private var observers: [Int: (GiovChatUiState) -> Void] = [:]
    private var nextObserver = 0
    #if canImport(Combine)
    private let willChange = WillChangePublisher()
    #endif

    private var phase: GiovChatPhase = .loading
    private var config: GiovWidgetConfig?
    private var messages: [GiovMessage] = []
    private var drafts: [(streamId: String, draft: GiovDraft)] = []
    private var agentTyping = false
    private var agentTypingIsBot: Bool?
    private var agentName: String?
    private var agentAvatar: String?
    private var access: GiovAttachmentAccess?
    private var unread = 0
    private var error: GiovChatError?
    private var sending = false
    private var uploads: [GiovUploadProgress] = []
    private var requiredFields = GiovRequestUserInfo()
    private var hasConversation = false
    private var status: GiovConnectionStatus = .disconnected
    private var conversationIdValue: String?
    private var reconnecting = false

    private struct PushRequest {
        let token: String
        let platform: GiovPushPlatform
        let options: GiovPushOptions
        let continuation: CheckedContinuation<GiovPushResult, Never>
    }

    /// Creates a controller. Nothing happens until ``start()``.
    ///
    /// - Parameters:
    ///   - tenantKey: the workspace key (public; it is in every embed snippet).
    ///   - baseURL: the API origin; leave the default for Giov Cloud. Must be an http(s) URL without credentials,
    ///     query or fragment (a programming error otherwise).
    ///   - contact: what the host knows about the visitor; see ``GiovContact`` for the signed identity.
    ///   - sessionKey: separates stored conversations of the same visitor, e.g. per account.
    ///   - sessionStore: where the session secret lives between launches. Defaults to the Keychain on Apple
    ///     platforms (``KeychainGiovSessionStore``), memory elsewhere.
    ///   - keepConnected: stay connected while the chat is not visible (app in the foreground) to count unread
    ///     replies. Never starts a conversation.
    ///   - visible: whether the chat screen is showing now.
    ///   - locale: BCP 47 language for the SDK's text and push notifications; defaults to the device language.
    ///   - overrideStrings: replaces individual interface strings, e.g. `{ $0.withOverrides(sendMessage: "Mandar") }`.
    ///   - backgroundGraceMs: how long the app may be in the background before the socket is closed.
    ///   - http, socketFactory, clock, random: seams for tests and special networking needs.
    public init(
        tenantKey: String,
        baseURL: String = giovDefaultBaseURL,
        contact: GiovContact? = nil,
        sessionKey: String? = nil,
        sessionStore: (any GiovSessionStore)? = nil,
        keepConnected: Bool = false,
        visible: Bool = true,
        locale: String? = nil,
        overrideStrings: ((GiovChatStrings) -> GiovChatStrings)? = nil,
        backgroundGraceMs: Int = 5_000,
        onError: ((GiovChatError) -> Void)? = nil,
        onConversationStart: ((String) -> Void)? = nil,
        onConnectionStatusChange: ((GiovConnectionStatus) -> Void)? = nil,
        onUnreadCountChange: ((Int) -> Void)? = nil,
        http: any GiovHTTP = URLSessionGiovHTTP(),
        socketFactory: any GiovSocketFactory = URLSessionGiovSocketFactory(),
        clock: any GiovClock = GiovSystemClock(),
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        let normalized: String
        do {
            normalized = try normalizeBaseURL(baseURL)
        } catch {
            preconditionFailure("GiovChatController: use an HTTP(S) API URL without credentials, query parameters or fragments.")
        }
        self.tenantKey = tenantKey
        self.baseURL = normalized
        self.keepConnected = keepConnected
        self.backgroundGraceMs = backgroundGraceMs
        let resolvedLocale = giovResolveLocale(locale ?? giovDeviceLocale())
        self.locale = resolvedLocale
        self.strings = giovResolveStrings(resolvedLocale, override: overrideStrings)
        self.onError = onError
        self.onConversationStart = onConversationStart
        self.onConnectionStatusChange = onConnectionStatusChange
        self.onUnreadCountChange = onUnreadCountChange
        self.store = sessionStore ?? GiovChatController.defaultSessionStore()
        self.baseContact = contact
        self.contact = contact ?? GiovContact()
        self.scopeKey = giovSessionScope(baseURL: normalized, tenantKey: tenantKey, contact: contact ?? GiovContact(), sessionKey: sessionKey)
        self.visible = visible
        self.clock = clock
        self.random = random
        self.state = GiovChatUiState(visible: visible)
        let outbox = Outbox(now: { clock.now() })
        self.outbox = outbox
        self.client = GiovChatClient(
            tenantKey: tenantKey,
            baseURL: normalized,
            outbox: outbox,
            flushOnOpen: false,
            locale: resolvedLocale,
            http: http,
            socketFactory: socketFactory,
            clock: clock,
            random: random
        )
        self.outboxStop = outbox.subscribe { [weak self] in self?.changed() }
    }

    private static func defaultSessionStore() -> any GiovSessionStore {
        #if canImport(Security)
        return KeychainGiovSessionStore()
        #else
        return InMemoryGiovSessionStore()
        #endif
    }

    // MARK: - Observing

    /// Calls `onChange` with the current state now and after every change, until the returned observation is
    /// cancelled or released. Runs on the main actor.
    public func observe(_ onChange: @escaping @MainActor (GiovChatUiState) -> Void) -> GiovObservation {
        let id = nextObserver
        nextObserver += 1
        observers[id] = onChange
        onChange(state)
        return GiovObservation { [weak self] in
            onMainActor { self?.observers[id] = nil }
        }
    }

    // MARK: - Lifecycle

    private var wantConnection: Bool { foreground && (visible || keepConnected) }

    /// Loads the configuration, resumes a stored conversation (connecting at once) and otherwise waits for the
    /// visitor. Returns when that first pass has settled.
    ///
    /// Calling it again on a started controller does nothing (it waits for that first pass): the socket, a streaming
    /// reply and the outbox are left alone, so a chat screen can call it every time it appears. Use ``retry()`` to
    /// force a fresh connection.
    public func start() async {
        if started {
            await firstPass?.value
            return
        }
        started = true
        let pass = restart()
        firstPass = pass
        await pass?.value
    }

    /// Shows or hides the chat. Showing clears unread replies; a hidden chat that is not `keepConnected` disconnects.
    public func setVisible(_ value: Bool) {
        guard value != visible, !disposed else { return }
        visible = value
        if value {
            unread = 0
            publishUnread()
            if keepConnected && phase == .idle && started {
                restart()
                return
            }
        }
        sync()
        changed()
    }

    /// The app went to the background. The socket is closed after ``backgroundGraceMs`` so the server can push
    /// replies (a socket that keeps pinging counts as watching).
    public func onBackground() {
        guard !disposed, foreground, graceTask == nil else { return }
        let clock = self.clock
        let grace = backgroundGraceMs
        graceTask = Task { [weak self] in
            do { try await clock.sleep(ms: grace) } catch { return }
            guard let self else { return }
            self.graceTask = nil
            self.foreground = false
            self.sync()
        }
    }

    /// The app returned to the foreground: reconnects if the socket was closed, otherwise reloads the history so
    /// nothing sent meanwhile is missed.
    public func onForeground() {
        guard !disposed else { return }
        graceTask?.cancel()
        graceTask = nil
        if !foreground {
            foreground = true
            sync()
            return
        }
        if phase == .active {
            if let generation = catchUpGeneration {
                launch { controller in
                    do {
                        try await controller.refreshHistory(generation)
                    } catch {
                        // Anything but a dead session is caught up by the next reconnect.
                        await controller.catchUpFailed(error, generation, show: false)
                    }
                }
            }
        } else if connectRetryPending {
            // A failed first connection is waiting for its backoff: try again now.
            restart()
        } else {
            client.reconnectNow()
        }
    }

    /// Starts over after an error (``GiovChatPhase/error``) or to force a fresh connection.
    public func retry() async {
        connectAttempt = 0
        await restart()?.value
    }

    /// Forgets the conversation, the stored session and the outbox (sign-out, "new chat").
    public func reset() async {
        guard !disposed else { return }
        generation += 1
        stopTyping()
        cancelSubscriptions()
        client.disconnect()
        session = nil
        conversationIdValue = nil
        contact = baseContact ?? GiovContact()
        loadedStore = true
        outbox.clear()
        localFiles.removeAll()
        startNow = false
        hasConversation = false
        messages = []
        drafts.removeAll()
        agentTyping = false
        agentTypingIsBot = nil
        agentName = nil
        agentAvatar = nil
        access = nil
        unread = 0
        publishUnread()
        error = nil
        reconnecting = false
        connectAttempt = 0
        connectRetryPending = false
        // Sign-out: the device token belongs to the previous visitor.
        pushToken = nil
        pushOnConnect = false
        pushRequest?.continuation.resume(returning: .notRegistered(.noConversation))
        pushRequest = nil
        do {
            try await storeOperation { [scopeKey = self.scopeKey] store in try await store.delete(scope: scopeKey) }
        } catch {
            report(.storage("Saved chat session could not be cleared.", underlying: error))
        }
        if started { await restart()?.value }
    }

    /// The pre-chat form was submitted: stores the contact details and starts the conversation.
    public func submitContact(_ info: GiovContact) async {
        guard !disposed else { return }
        contact = contact.merging(info)
        startNow = true
        await restart()?.value
    }

    /// Stops the controller and releases its connection. Unsent messages are lost. The controller cannot be used
    /// afterwards.
    public func close() {
        guard !disposed else { return }
        disposed = true
        generation += 1
        graceTask?.cancel()
        typingTask?.cancel()
        cancelSubscriptions()
        pushRequest?.continuation.resume(returning: .notRegistered(.noConversation))
        pushRequest = nil
        outboxStop?()
        outboxStop = nil
        GiovUnread.forget(owner: self)
        client.dispose()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        observers.removeAll()
    }

    // MARK: - The session

    private func alive(_ generation: Int) -> Bool { !disposed && generation == self.generation }

    /// Runs `body` as a task the controller cancels when it closes.
    @discardableResult
    private func launch(_ body: @escaping @MainActor (GiovChatController) async -> Void) -> Task<Void, Never> {
        let id = nextTask
        nextTask += 1
        let task = Task { [weak self] in
            guard let self else { return }
            await body(self)
            self.tasks[id] = nil
        }
        tasks[id] = task
        return task
    }

    private func sync() {
        guard started, !disposed else { return }
        if wantConnection != wanted { restart() }
    }

    @discardableResult
    private func restart() -> Task<Void, Never>? {
        guard !disposed else { return nil }
        generation += 1
        let generation = self.generation
        stopTyping()
        cancelSubscriptions()
        client.disconnect()
        wanted = wantConnection
        connectRetryPending = false
        if !wanted {
            agentTyping = false
            agentTypingIsBot = nil
            reconnecting = false
            drafts.removeAll()
            setStatus(.disconnected)
            changed()
            return nil
        }
        return launch { controller in await controller.run(generation) }
    }

    private func run(_ generation: Int) async {
        do {
            try await begin(generation)
        } catch {
            guard alive(generation), !(error is CancellationError) else { return }
            cancelSubscriptions()
            client.disconnect()
            let failure = error.asGiovError
            if failure.kind == .conversationClosed {
                await forget(generation)
                return
            }
            if failure.kind == .sessionExpired { await clearSession() }
            guard alive(generation) else { return }
            report(failure)
            if config != nil && retriesFirstConnection(failure) {
                // As the web widget does: a connection that could not be made is tried again with the protocol's
                // backoff, showing "Reconnecting", instead of stopping at "Try again".
                reconnecting = true
                self.error = failure.kind == .workspaceBusy || failure.kind == .rateLimited ? failure : nil
                phase = .connecting
                setStatus(.connecting)
                scheduleConnectRetry(generation, after: failure)
                changed()
                return
            }
            reconnecting = false
            self.error = failure
            phase = .error
            setStatus(.disconnected)
            changed()
        }
    }

    /// Failures a later attempt can get past: the network, the server, a rate limit, a busy workspace.
    private func retriesFirstConnection(_ failure: GiovChatError) -> Bool {
        switch failure.kind {
        case .network, .server, .rateLimited, .workspaceBusy: return true
        default: return false
        }
    }

    private func scheduleConnectRetry(_ generation: Int, after failure: GiovChatError) {
        var wait = giovReconnectDelayMs(attempt: connectAttempt, jitter: random())
        connectAttempt += 1
        if let seconds = failure.retryAfterSeconds { wait = max(wait, seconds * 1000) }
        connectRetryPending = true
        let clock = self.clock
        launch { controller in
            do { try await clock.sleep(ms: wait) } catch { return }
            guard controller.alive(generation) else { return }
            controller.connectRetryPending = false
            controller.restart()
        }
    }

    /// The history reload after a (re)connect failed. A dead session ends the chat and forgets the stored pair;
    /// anything else leaves the socket up, sends the outbox on it and waits for the next reconnect to catch up.
    private func catchUpFailed(_ error: Error, _ generation: Int, show: Bool) async {
        guard alive(generation), !(error is CancellationError) else { return }
        let failure = error.asGiovError
        switch failure.kind {
        case .sessionExpired:
            report(failure)
            cancelSubscriptions()
            client.disconnect()
            reconnecting = false
            drafts.removeAll()
            agentTyping = false
            agentTypingIsBot = nil
            self.error = failure
            phase = .error
            setStatus(.disconnected)
            await clearSession()
            changed()
        case .conversationClosed:
            await forget(generation)
        default:
            if show {
                report(failure)
                self.error = failure
                changed()
            }
            client.flush()
        }
    }

    /// Runs one session-store call once the earlier ones have finished. Store calls are not ordered otherwise (the
    /// Keychain store runs on the global executor): a reset's delete could overtake the write of the conversation it
    /// forgets, leaving that session stored for the next launch.
    private func storeOperation<T: Sendable>(_ operation: @escaping @Sendable (any GiovSessionStore) async throws -> T) async throws -> T {
        let previous = storeQueue
        let store = self.store
        let task = Task<T, Error> {
            await previous?.value
            return try await operation(store)
        }
        storeQueue = Task { _ = try? await task.value }
        return try await task.value
    }

    private func clearSession() async {
        session = nil
        conversationIdValue = nil
        hasConversation = false
        messages = []
        do {
            try await storeOperation { [scopeKey = self.scopeKey] store in try await store.delete(scope: scopeKey) }
        } catch {
            report(.storage("Chat session could not be saved or restored.", underlying: error))
        }
    }

    /// The conversation was closed or deleted: forget it; the visitor's next message starts a new one.
    private func forget(_ generation: Int) async {
        guard alive(generation), forgottenGeneration != generation else { return }
        forgottenGeneration = generation
        cancelSubscriptions()
        client.disconnect()
        await clearSession()
        guard alive(generation) else { return }
        agentName = nil
        agentAvatar = nil
        drafts.removeAll()
        agentTyping = false
        agentTypingIsBot = nil
        reconnecting = false
        phase = .ready
        setStatus(.disconnected)
        error = .conversationClosed()
        changed()
    }

    private func begin(_ generation: Int) async throws {
        phase = config == nil ? .loading : (session != nil ? .connecting : .ready)
        error = nil
        agentTyping = false
        agentTypingIsBot = nil
        sending = false
        setStatus(.connecting)
        changed()
        let loaded: GiovWidgetConfig
        if let config {
            loaded = config
        } else {
            loaded = try await client.fetchWidgetConfig()
        }
        guard alive(generation) else { return }
        config = loaded
        changed()
        if !loadedStore {
            do {
                let stored = try await storeOperation { [scopeKey = self.scopeKey] store in try await store.read(scope: scopeKey) }
                guard alive(generation) else { return }
                loadedStore = true
                if isValidStoredSession(stored) { session = stored }
            } catch {
                // Not "nothing stored": the Keychain refuses reads before the first unlock after a reboot (an app
                // woken by a push), so the read is tried again on the next pass, at the latest when the visitor
                // writes, instead of starting a new conversation over the stored one.
                guard alive(generation) else { return }
                report(.storage("Chat session could not be saved or restored.", underlying: error))
            }
        }
        guard alive(generation) else { return }
        if let existing = session {
            do {
                let resumed = try await client.resumeConversation(existing, contact: contact)
                // A reset (or close) while the request ran must not bring the forgotten conversation back.
                guard alive(generation) else { return }
                session = resumed
            } catch let failure as GiovChatError {
                guard alive(generation) else { return }
                guard failure.kind == .sessionExpired || failure.kind == .conversationClosed || failure.status == 404 else { throw failure }
                await clearSession()
            }
        }
        guard alive(generation) else { return }
        // Hidden and nothing to resume: wait until the chat is opened instead of starting a conversation.
        if !visible && session == nil {
            phase = .idle
            setStatus(.disconnected)
            changed()
            return
        }
        requiredFields = missingContactFields(loaded.requestUserInfo, contact: contact)
        if session == nil && requiredFields.any {
            phase = .preChat
            setStatus(.disconnected)
            changed()
            return
        }
        if session == nil && !startNow {
            phase = .ready
            setStatus(.disconnected)
            changed()
            return
        }
        phase = .connecting
        changed()
        if session == nil {
            let created = try await client.startConversation(contact: contact)
            guard alive(generation) else { return }
            startNow = false
            session = created
            do {
                try await storeOperation { [scopeKey = self.scopeKey] store in try await store.write(scope: scopeKey, session: created) }
            } catch {
                report(.storage("Chat session could not be saved or restored.", underlying: error))
            }
            guard alive(generation) else { return }
            // The device token the host registered for the previous conversation also covers this one.
            if pushToken != nil { pushOnConnect = true }
            onConversationStart?(created.conversationId)
        }
        guard alive(generation), let current = session else { return }
        hasConversation = true
        conversationIdValue = current.conversationId
        changed()

        openedOnce = false
        client.events = events(generation)
        catchUpGeneration = generation
        try await client.connect(current)
        guard alive(generation) else { return }
        try await refreshHistory(generation)
    }

    /// Catch-up: history merged by id with what arrived meanwhile, then the outbox is resent.
    private func refreshHistory(_ generation: Int) async throws {
        let history: GiovHistory
        do {
            history = try await client.fetchHistory()
        } catch let failure as GiovChatError where failure.status == 404 {
            await forget(generation)
            return
        }
        guard alive(generation) else { return }
        if history.closed {
            await forget(generation)
            return
        }
        captureAccess(history.attachmentAccess)
        agentName = history.assignedAgentName
        agentAvatar = history.assignedAgentAvatar
        messages = mergeMessages(messages, history.messages)
        changed()
        client.flush()
    }

    private func events(_ generation: Int) -> ClientEvents {
        var events = ClientEvents()
        events.message = { [weak self] message in
            guard let self, self.alive(generation) else { return }
            self.messages = mergeMessages(self.messages, [message])
            if message.role == .agent {
                self.agentTyping = false
                self.agentTypingIsBot = nil
                if message.isFromPerson, let name = message.senderName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    self.agentName = name
                    self.agentAvatar = message.senderAvatar
                }
                if !self.visible {
                    self.unread += 1
                    self.publishUnread()
                }
            }
            self.changed()
        }
        events.ack = { [weak self] clientMessageId, message in
            guard let self, self.alive(generation) else { return }
            var stored = message
            stored.clientMessageId = clientMessageId
            self.messages = mergeMessages(self.messages, [stored])
            self.changed()
        }
        events.stream = { [weak self] event in
            guard let self, self.alive(generation) else { return }
            switch event {
            case .end(let streamId):
                guard let index = self.drafts.firstIndex(where: { $0.streamId == streamId }) else { return }
                self.drafts.remove(at: index)
            case .update(let streamId, let content):
                if let index = self.drafts.firstIndex(where: { $0.streamId == streamId }) {
                    self.drafts[index].draft = GiovDraft(content: content, createdAt: self.drafts[index].draft.createdAt)
                } else {
                    self.drafts.append((streamId, GiovDraft(content: content, createdAt: self.clock.now())))
                }
                if !content.isEmpty { self.agentTyping = false }
            }
            self.changed()
        }
        events.attachmentAccess = { [weak self] access in
            guard let self, self.alive(generation) else { return }
            self.captureAccess(access)
        }
        events.typing = { [weak self] active, isBot in
            guard let self, self.alive(generation) else { return }
            // A `typing_end` that names the other kind (a person's end while the bot types) is ignored.
            if !active, let isBot, self.agentTyping, let shown = self.agentTypingIsBot, shown != isBot { return }
            self.agentTyping = active
            self.agentTypingIsBot = active ? isBot : nil
            self.changed()
        }
        events.error = { [weak self] error in
            guard let self, self.alive(generation) else { return }
            self.report(error)
            if error.kind == .conversationClosed {
                self.launch { controller in await controller.forget(generation) }
                return
            }
            self.error = error
            if error.kind == .sessionExpired {
                self.phase = .error
                self.reconnecting = false
                self.launch { controller in await controller.clearSession() }
            }
            self.changed()
        }
        events.connection = { [weak self] connected in
            guard let self, self.alive(generation) else { return }
            if !connected {
                self.agentTyping = false
                self.agentTypingIsBot = nil
                // A reply being written is lost with the socket; the saved copy arrives with the catch-up.
                self.drafts.removeAll()
                if self.openedOnce { self.reconnecting = true }
            } else {
                self.reconnecting = false
                self.connectAttempt = 0
            }
            self.setStatus(connected ? .connected : (self.openedOnce ? .disconnected : .connecting))
            self.phase = connected ? .active : .connecting
            if connected {
                self.error = nil
                // Catch up on whatever arrived while the socket was down.
                if self.openedOnce {
                    self.launch { controller in
                        do {
                            try await controller.refreshHistory(generation)
                        } catch {
                            await controller.catchUpFailed(error, generation, show: true)
                        }
                    }
                }
                self.openedOnce = true
                if let push = self.pushRequest {
                    self.pushRequest = nil
                    self.pushOnConnect = false
                    self.launch { controller in
                        let result = await controller.client.registerPushToken(push.token, platform: push.platform, options: push.options)
                        push.continuation.resume(returning: result)
                    }
                } else if self.pushOnConnect, let push = self.pushToken {
                    self.pushOnConnect = false
                    self.launch { controller in
                        // Never throws; a failure is retried when the host registers again.
                        _ = await controller.client.registerPushToken(push.token, platform: push.platform, options: push.options)
                    }
                }
            }
            self.changed()
        }
        return events
    }

    private func cancelSubscriptions() {
        client.events = nil
        catchUpGeneration = nil
    }

    // MARK: - Sending

    /// What a file picked now may be: the answering bot's policy against the server's limits.
    public func checkFiles(_ files: [GiovPickedFile], alreadyAttached: Int = 0) -> GiovAttachmentCheck {
        giovValidateAttachments(files, policy: (state.config ?? GiovWidgetConfig(title: "")).attachmentPolicy, existingCount: alreadyAttached)
    }

    /// Sends text and files. Files upload first (they need the conversation); the message then waits in the outbox
    /// until a socket takes it, so text typed while reconnecting is never lost. Several files go as one message each
    /// after the text, as in the widget. Returns false when nothing was queued (empty, wrong phase, a message over
    /// 2000 characters, or an upload failed; see ``GiovChatUiState/error``).
    @discardableResult
    public func send(_ text: String, files: [GiovPickedFile] = []) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !disposed, !trimmed.isEmpty || !files.isEmpty else { return false }
        guard phase == .active || phase == .connecting || phase == .ready else { return false }
        // Uploads need a live conversation; the attach button only appears once one exists.
        if !files.isEmpty && session == nil { return false }
        let generation = self.generation
        stopTyping()
        error = nil
        var urls: [String] = []
        if !files.isEmpty {
            if !client.isConnected && client.session == nil {
                error = .network("Chat is reconnecting. Please try again.")
                changed()
                return false
            }
            sending = true
            uploads = files.map { GiovUploadProgress(name: $0.name, progress: 0) }
            changed()
            var failed: GiovChatError?
            for (index, file) in files.enumerated() {
                do {
                    let result = try await client.uploadAttachment(file) { [weak self] progress in
                        guard let self, self.generation == generation, !self.disposed, index < self.uploads.count else { return }
                        self.uploads[index].progress = progress
                        self.changed()
                    }
                    let preview = result.preview ?? ((file.width != nil && file.height != nil) ? GiovAttachmentPreview(width: file.width, height: file.height) : nil)
                    localFiles[result.url] = GiovAttachment(
                        url: result.url,
                        filename: result.filename.isEmpty ? file.name : result.filename,
                        preview: preview,
                        contentType: file.mimeType
                    )
                    urls.append(result.url)
                } catch {
                    failed = error is CancellationError ? .disconnected() : error.asGiovError
                    break
                }
            }
            if self.generation == generation && !disposed {
                sending = false
                uploads = []
                if let failed, failed.kind != .disconnected {
                    report(failed)
                    switch failed.kind {
                    case .conversationClosed:
                        // The conversation is gone (404): forget it like a closed one; the next message starts anew.
                        launch { controller in await controller.forget(generation) }
                    case .sessionExpired:
                        error = failed
                        phase = .error
                        launch { controller in await controller.clearSession() }
                    default:
                        // The visitor sees "File upload failed"; the kind, status, code and Retry-After stay as they
                        // came so the host can tell a refused file from a network or rate-limit failure.
                        error = failed.kind == .attachmentRejected ? failed : GiovChatError(
                            .attachmentRejected,
                            "File upload failed.",
                            status: failed.status,
                            code: failed.code,
                            timedOut: failed.timedOut,
                            retryAfterSeconds: failed.retryAfterSeconds,
                            underlying: failed.underlying ?? failed.message
                        )
                    }
                }
                changed()
            }
            if failed != nil || self.generation != generation { return false }
        }
        var parts: [(String, [String])] = []
        if urls.count > 1 {
            if !trimmed.isEmpty { parts.append((trimmed, [])) }
            for url in urls { parts.append(("", [url])) }
        } else {
            parts.append((trimmed, urls))
        }
        do {
            for (content, attachments) in parts {
                try outbox.enqueue(content, attachments: attachments, now: clock.now())
            }
        } catch {
            report(error)
            self.error = error
            changed()
            return false
        }
        if session != nil {
            client.flush()
        } else if !startNow {
            // The first message starts the conversation; it goes out once the socket is open.
            startNow = true
            restart()
        }
        changed()
        return true
    }

    /// Tries a failed message again ("tap to retry"); it is sent in its original place in the queue.
    public func retryMessage(_ clientMessageId: String) {
        guard !disposed else { return }
        if outbox.retry(clientMessageId) { client.flush() }
    }

    /// Removes a failed message the visitor does not want to retry.
    public func discardMessage(_ clientMessageId: String) {
        guard !disposed else { return }
        outbox.remove(clientMessageId)
    }

    /// Call on every keystroke: the agent sees "typing" once per burst and it ends after a pause.
    public func notifyTyping() {
        guard !disposed, client.isConnected else { return }
        if !typingSent {
            client.sendTyping()
            typingSent = true
        }
        typingTask?.cancel()
        let clock = self.clock
        typingTask = Task { [weak self] in
            do { try await clock.sleep(ms: typingIdleMs) } catch { return }
            guard let self else { return }
            self.typingTask = nil
            self.typingSent = false
            self.client.sendTypingEnd()
        }
    }

    private func stopTyping() {
        typingTask?.cancel()
        typingTask = nil
        if typingSent { client.sendTypingEnd() }
        typingSent = false
    }

    /// A download URL for an attachment with exactly one credential (the attachment access token, else the visitor
    /// token). Load files from here with the app's image loader.
    public func attachmentURL(_ url: String) -> String {
        let usable = access.flatMap { $0.usable(at: clock.now()) ? $0.token : nil }
        return giovAttachmentDisplayURL(url, accessToken: usable, visitorToken: client.visitorToken)
    }

    /// Registers the device for push now when connected, or as soon as the conversation connects. Never throws. Call
    /// again whenever the platform hands out a new token; a request still waiting is superseded (it reports
    /// ``GiovPushFailure/failed``).
    ///
    /// Called before any conversation exists, it waits for the visitor's first conversation and registers then; it
    /// returns ``GiovPushFailure/noConversation`` if the controller is closed (or ``reset()``) first. The token is
    /// remembered and registered again, without another call, for every new conversation of the same visitor (after
    /// the team closed the previous one); ``reset()`` and ``unregisterPushToken(_:)`` forget it.
    ///
    /// - Parameters:
    ///   - token: the APNs device token as lowercase hex (see ``registerPushToken(deviceToken:environment:appId:locale:)``)
    ///     or an FCM registration token.
    ///   - platform: ``GiovPushPlatform/apns`` (default) or ``GiovPushPlatform/fcm`` for apps using Firebase.
    ///   - environment: APNs only; ``GiovPushEnvironment/sandbox`` for development builds.
    ///   - appId: the bundle id; defaults to the main bundle's.
    ///   - locale: the language of generic notification text; defaults to the chat's.
    public func registerPushToken(
        _ token: String,
        platform: GiovPushPlatform = .apns,
        environment: GiovPushEnvironment? = nil,
        appId: String? = Bundle.main.bundleIdentifier,
        locale: String? = nil
    ) async -> GiovPushResult {
        guard !disposed else { return .notRegistered(.noConversation) }
        let options = GiovPushOptions(environment: platform == .apns ? environment : nil, appId: appId, locale: locale)
        pushToken = (token, platform, options)
        pushOnConnect = false
        if client.isConnected {
            return await client.registerPushToken(token, platform: platform, options: options)
        }
        pushRequest?.continuation.resume(returning: .notRegistered(.failed))
        pushRequest = nil
        return await withCheckedContinuation { continuation in
            pushRequest = PushRequest(token: token, platform: platform, options: options, continuation: continuation)
        }
    }

    /// Registers an APNs device token (the `Data` from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`), hex-encoded. `environment` defaults to
    /// sandbox in DEBUG builds and production otherwise.
    public func registerPushToken(
        deviceToken: Data,
        environment: GiovPushEnvironment = .current,
        appId: String? = Bundle.main.bundleIdentifier,
        locale: String? = nil
    ) async -> GiovPushResult {
        await registerPushToken(giovAPNsTokenString(deviceToken), platform: .apns, environment: environment, appId: appId, locale: locale)
    }

    /// Stops push notifications about this conversation on this device (sign-out, notifications off). Never throws;
    /// true when the server confirmed. Works while the chat is hidden or disconnected too: it then uses the stored
    /// session to get a fresh visitor token. Call it before ``reset()``, which forgets that session.
    public func unregisterPushToken(_ token: String) async -> Bool {
        guard !disposed else { return false }
        if pushToken?.token == token {
            pushToken = nil
            pushOnConnect = false
        }
        if let pending = pushRequest, pending.token == token {
            pushRequest = nil
            pending.continuation.resume(returning: .notRegistered(.noConversation))
        }
        var target = session
        if target == nil && !loadedStore {
            // Not started yet (or the read failed): the stored session still names the conversation.
            let stored = try? await storeOperation { [scopeKey = self.scopeKey] store in try await store.read(scope: scopeKey) }
            if isValidStoredSession(stored) { target = stored }
        }
        guard !disposed else { return false }
        return await client.unregisterPushToken(token, session: target)
    }

    /// ``unregisterPushToken(_:)`` for an APNs device token.
    public func unregisterPushToken(deviceToken: Data) async -> Bool {
        await unregisterPushToken(giovAPNsTokenString(deviceToken))
    }

    // MARK: - Plumbing

    private func captureAccess(_ incoming: GiovAttachmentAccess?) {
        let next = GiovAttachmentAccess.newer(access, incoming)
        if next != access {
            access = next
            changed()
        }
    }

    private func publishUnread() {
        let count = visible ? 0 : unread
        GiovUnread.publish(owner: self, tenantKey: tenantKey, count: count)
        onUnreadCountChange?(count)
    }

    private func setStatus(_ value: GiovConnectionStatus) {
        status = value
        onConnectionStatusChange?(value)
    }

    private func report(_ failure: GiovChatError) {
        onError?(failure)
    }

    private func changed() {
        guard !disposed else { return }
        var next = GiovChatUiState(visible: visible)
        next.phase = phase
        next.config = config
        next.messages = displayMessages(saved: messages, pending: outbox.list(), drafts: drafts, describe: { [localFiles] url in
            localFiles[url] ?? GiovAttachment(url: url)
        })
        next.header = config.map { giovHeaderIdentity($0, agentName: agentName, agentAvatar: agentAvatar) }
        next.agentName = agentName
        next.agentAvatar = agentAvatar
        next.agentTyping = agentTyping
        next.agentTypingIsBot = agentTypingIsBot
        next.unreadCount = visible ? 0 : unread
        next.error = error
        next.sending = sending
        next.uploads = uploads
        next.requiredFields = requiredFields
        next.hasConversation = hasConversation
        next.connectionStatus = status
        next.reconnecting = reconnecting
        next.conversationId = conversationIdValue
        guard next != state else { return }
        #if canImport(Combine)
        willChange.publisher.send()
        #endif
        state = next
        for key in observers.keys.sorted() {
            observers[key]?(next)
        }
    }
}

#if canImport(Combine)
/// Holds the `objectWillChange` publisher so it can be read from any context.
private final class WillChangePublisher: @unchecked Sendable {
    let publisher = ObservableObjectPublisher()
}

extension GiovChatController: ObservableObject {
    /// Fires before every change of ``state``, for SwiftUI's `@ObservedObject` / `@StateObject`.
    public nonisolated var objectWillChange: ObservableObjectPublisher { willChange.publisher }
}
#endif

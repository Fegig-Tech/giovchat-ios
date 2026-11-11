#if canImport(SwiftUI) && canImport(ImageIO) && canImport(PhotosUI) && canImport(UniformTypeIdentifiers)
import GiovChatCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The greeting, the messages, the typing row, picked files and the composer.
@MainActor
struct GiovConversationView: View {
    @ObservedObject var controller: GiovChatController
    let state: GiovChatUiState
    @ObservedObject var draft: GiovDraftModel
    let look: GiovLook

    @State private var stick = true
    @State private var announcer = GiovMessageAnnouncer()
    @FocusState private var composerFocused: Bool

    private let bottomID = "giov-bottom"

    init(controller: GiovChatController, state: GiovChatUiState, draft: GiovDraftModel, look: GiovLook) {
        _controller = ObservedObject(wrappedValue: controller)
        self.state = state
        _draft = ObservedObject(wrappedValue: draft)
        self.look = look
    }

    var body: some View {
        let strings = look.strings
        let canSend = GiovComposerRules.canSend(
            phase: state.phase,
            sending: state.sending,
            busy: draft.busy,
            text: draft.text,
            fileCount: draft.files.count
        )
        VStack(spacing: 0) {
            if let text = giovBannerText(state, strings: strings) {
                Text(text)
                    .font(.subheadline)
                    .foregroundColor(state.error == nil ? look.secondaryText : look.error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .onAppear { giovAnnounce(text) }
                    .onChange(of: text) { giovAnnounce($0) }
            }
            messageList
            if !draft.files.isEmpty || draft.problem != nil {
                GiovPendingFiles(
                    files: draft.files,
                    uploads: state.uploads,
                    sending: state.sending,
                    problem: draft.problem,
                    look: look,
                    onRemove: { index in
                        if draft.files.indices.contains(index) { draft.files.remove(at: index) }
                    }
                )
            }
            GiovComposer(
                text: $draft.text,
                focused: $composerFocused,
                placeholder: state.config?.textArea ?? strings.composerPlaceholder,
                enabled: GiovComposerRules.textEditable(state.phase),
                canSend: canSend,
                attach: GiovComposerRules.canAttach(state) ? attachOptions : nil,
                attachEnabled: GiovComposerRules.attachEnabled(sending: state.sending, fileCount: draft.files.count),
                look: look,
                onSend: send,
                onTyping: { controller.notifyTyping() },
                onPicked: { files in accept(files) }
            )
        }
        // New replies are read out to VoiceOver users as they arrive.
        .onAppear { _ = announcer.update(state, strings: strings) }
        .onChange(of: state.messages) { _ in
            if let sentence = announcer.update(state, strings: strings) { giovAnnounce(sentence) }
        }
    }

    private var attachOptions: GiovPickerOptions {
        GiovPickerOptions(policy: state.config?.attachmentPolicy ?? .default, alreadyAttached: draft.files.count)
    }

    private var messageList: some View {
        GeometryReader { geometry in
            let maxBubble = max(120, (geometry.size.width - 32) * 0.78)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let config = state.config {
                            GiovGreetingBubble(text: config.greetingText, look: look, maxWidth: maxBubble)
                                .id("giov-greeting")
                        }
                        ForEach(state.messages, id: \.key) { message in
                            GiovMessageBubble(
                                model: GiovBubbleModel(
                                    message,
                                    strings: look.strings,
                                    botName: giovBotName(state),
                                    agentName: state.agentName,
                                    time: { giovTimeLabel($0) }
                                ),
                                look: look,
                                maxWidth: maxBubble,
                                attachmentURL: { controller.attachmentURL($0) },
                                onRetry: { controller.retryMessage($0) },
                                onDiscard: { controller.discardMessage($0) }
                            )
                            .id(message.key)
                        }
                        if state.agentTyping {
                            GiovTypingIndicator(
                                label: giovTypingLabel(isBot: state.agentTypingIsBot, botName: giovBotName(state), strings: look.strings),
                                isBot: state.agentTypingIsBot == true,
                                look: look,
                                maxWidth: maxBubble
                            )
                            .id("giov-typing")
                        }
                        Color.clear
                            .frame(height: 12)
                            .id(bottomID)
                            .onAppear { stick = true }
                            .onDisappear { stick = false }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
                .onChange(of: GiovScrollSignature(state)) { _ in
                    guard stick else { return }
                    let streaming = state.messages.last?.isStreaming == true
                    scrollToBottom(proxy, animated: !streaming)
                }
                .onChange(of: geometry.size.height) { _ in
                    // The keyboard (or the picked-files row) changed the room; keep the newest message in view.
                    if stick || composerFocused { scrollToBottom(proxy, animated: false) }
                }
                .onChange(of: draft.busy) { busy in
                    if busy { scrollToBottom(proxy, animated: true) }
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated && !look.reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    private func send() {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = draft.files
        guard GiovComposerRules.canSend(phase: state.phase, sending: state.sending, busy: draft.busy, text: text, fileCount: files.count) else { return }
        stick = true
        draft.busy = true
        let chat = controller
        let model = draft
        Task {
            let sent = await chat.send(text, files: files)
            model.busy = false
            guard sent else { return }
            if model.text.trimmingCharacters(in: .whitespacesAndNewlines) == text { model.text = "" }
            if model.files == files { model.files = [] }
            model.problem = nil
        }
    }

    private func accept(_ picked: [GiovPickedFile]) {
        guard !picked.isEmpty else { return }
        let checked = controller.checkFiles(picked, alreadyAttached: draft.files.count)
        draft.files.append(contentsOf: checked.accepted)
        draft.problem = giovProblemText(checked.problems, strings: look.strings)
    }
}

/// The composer row: attach, multiline input and send.
@MainActor
struct GiovComposer: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let placeholder: String
    let enabled: Bool
    let canSend: Bool
    /// What the attach button offers; nil hides it.
    let attach: GiovPickerOptions?
    let attachEnabled: Bool
    let look: GiovLook
    let onSend: () -> Void
    let onTyping: () -> Void
    let onPicked: ([GiovPickedFile]) -> Void

    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []

    init(
        text: Binding<String>,
        focused: FocusState<Bool>.Binding,
        placeholder: String,
        enabled: Bool,
        canSend: Bool,
        attach: GiovPickerOptions?,
        attachEnabled: Bool,
        look: GiovLook,
        onSend: @escaping () -> Void,
        onTyping: @escaping () -> Void,
        onPicked: @escaping ([GiovPickedFile]) -> Void
    ) {
        _text = text
        self.focused = focused
        self.placeholder = placeholder
        self.enabled = enabled
        self.canSend = canSend
        self.attach = attach
        self.attachEnabled = attachEnabled
        self.look = look
        self.onSend = onSend
        self.onTyping = onTyping
        self.onPicked = onPicked
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let attach {
                attachButton(attach)
            }
            TextField(look.strings.messageInput, text: $text, prompt: Text(placeholder), axis: .vertical)
                .lineLimit(1...5)
                .font(.subheadline)
                .foregroundColor(look.text)
                .focused(focused)
                .disabled(!enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 22).fill(look.inputFill))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(look.inputBorder, lineWidth: 1))
                .onChange(of: text) { value in
                    let limited = GiovComposerRules.clamp(value)
                    if limited != value { text = limited }
                    if !limited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onTyping() }
                }
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(look.onButton)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(look.button))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.35)
            .accessibilityLabel(look.strings.sendMessage)
        }
        .padding(10)
        .background(look.composer.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(look.divider).frame(height: 0.5) }
        .photosPicker(
            isPresented: $showPhotos,
            selection: $photoItems,
            maxSelectionCount: attach?.maxPhotos ?? 1,
            matching: .images,
            preferredItemEncoding: .compatible
        )
        .fileImporter(
            isPresented: $showFiles,
            allowedContentTypes: giovContentTypes(forMIMETypes: allowedTypes),
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            let limited = Array(urls.prefix(GiovAttachmentLimits.maxFiles))
            let picked = onPicked
            Task {
                let files = await giovReadImportedFiles(limited)
                picked(files)
            }
        }
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            photoItems = []
            let picked = onPicked
            Task {
                var files: [GiovPickedFile] = []
                for (index, item) in items.enumerated() {
                    guard let data = await giovLoadPhotoData(item) else { continue }
                    if let file = await giovPreparePhotoInBackground(data, index: index) { files.append(file) }
                }
                picked(files)
            }
        }
    }

    private var allowedTypes: [String] {
        attach?.allowedTypes ?? []
    }

    @ViewBuilder
    private func attachButton(_ options: GiovPickerOptions) -> some View {
        let label = attachLabel
        if options.photos && options.files {
            Menu {
                Button {
                    showPhotos = true
                } label: {
                    Label(look.strings.image, systemImage: "photo.on.rectangle")
                }
                Button {
                    showFiles = true
                } label: {
                    Label(look.strings.attachment, systemImage: "doc")
                }
            } label: {
                label
            }
            .menuIndicator(.hidden)
            .disabled(!attachEnabled)
            .opacity(attachEnabled ? 1 : 0.4)
            .accessibilityLabel(look.strings.attachFile)
        } else {
            Button {
                if options.photos { showPhotos = true } else { showFiles = true }
            } label: {
                label
            }
            .buttonStyle(.plain)
            .disabled(!attachEnabled)
            .opacity(attachEnabled ? 1 : 0.4)
            .accessibilityLabel(look.strings.attachFile)
        }
    }

    private var attachLabel: some View {
        Image(systemName: "plus")
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(look.secondaryText)
            .frame(width: 44, height: 44)
            .overlay(Circle().stroke(look.inputBorder, lineWidth: 1))
            .contentShape(Circle())
    }
}

/// Prepares a library photo off the main actor.
func giovPreparePhotoInBackground(_ data: Data, index: Int) async -> GiovPickedFile? {
    giovPreparePhoto(data, index: index)
}

/// The bytes of a photo picked in the library, or nil when it cannot be loaded.
@MainActor
func giovLoadPhotoData(_ item: PhotosPickerItem) async -> Data? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
        _ = item.loadTransferable(type: Data.self) { result in
            continuation.resume(returning: try? result.get())
        }
    }
}
#endif

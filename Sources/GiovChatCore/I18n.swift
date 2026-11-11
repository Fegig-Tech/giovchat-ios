import Foundation

// The SDK's own interface text in the five languages the Giov dashboard ships (en, fr, es, pt, de). Text the
// business writes (greeting, placeholder, bot name) comes from the widget configuration and is not translated. Pick
// the language with `giovResolveStrings` (default: the device language) and replace any string with
// `GiovChatStrings.withOverrides`. Same wording as the React Native, Flutter and Android SDKs.

/// Languages the SDK ships.
public let giovLocales: [String] = ["en", "fr", "es", "pt", "de"]

private func n(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
}

/// The SDK's interface text for one language.
public struct GiovChatStrings: Sendable {
    /// Shown while the configuration loads.
    public var loading: String
    /// Button after a failure that needs a fresh start.
    public var tryAgain: String
    /// Button on a message that was not sent.
    public var retry: String
    /// Accessible label of the close button.
    public var closeChat: String
    /// Shown while the first connection is made.
    public var connecting: String
    /// Banner while the connection is being restored.
    public var reconnecting: String
    /// Header status while a person has the conversation.
    public var statusPerson: String
    /// Header status while GiovBot answers.
    public var statusBot: String
    /// Header status before anyone has answered.
    public var statusTeam: String
    /// Default composer placeholder (the workspace may set its own).
    public var composerPlaceholder: String
    public var messageInput: String
    public var sendMessage: String
    public var attachFile: String
    public var removeAttachment: @Sendable (String) -> String
    public var you: String
    public var agent: String
    public var automated: String
    public var botTyping: @Sendable (String) -> String
    public var teamTyping: String
    /// Under a message that has not been confirmed yet.
    public var sending: String
    /// Under a message that failed.
    public var notSent: String
    /// Hint on a failed message.
    public var tapToRetry: String
    /// Button on a message that was not sent, to drop it.
    public var discard: String
    public var uploading: @Sendable (Int) -> String
    public var uploadFailed: String
    /// Error: the stored session is gone.
    public var sessionExpired: String
    /// Error: the conversation was closed or deleted.
    public var conversationEnded: String
    /// Error: the server could not be reached.
    public var unavailable: String
    /// Error: a message could not be delivered.
    public var sendFailed: String
    /// Error: the workspace is at its plan's limit of open conversations.
    public var busy: String
    public var attachmentsOff: String
    public var typeNotAllowed: @Sendable (String) -> String
    public var fileTooLarge: @Sendable (String, Double) -> String
    public var tooManyFiles: @Sendable (Int) -> String
    public var openAttachment: @Sendable (String) -> String
    public var attachment: String
    public var image: String
    public var preChatTitle: String
    public var firstName: String
    public var lastName: String
    public var email: String
    public var phone: String
    public var required: @Sendable (String) -> String
    public var startChat: String
    /// The header menu's link to the privacy policy.
    public var privacyPolicy: String
    /// Accessible label of the header menu button.
    public var moreOptions: String

    /// These strings with the given ones replaced. Blank strings are ignored.
    public func withOverrides(
        loading: String? = nil,
        tryAgain: String? = nil,
        retry: String? = nil,
        closeChat: String? = nil,
        connecting: String? = nil,
        reconnecting: String? = nil,
        statusPerson: String? = nil,
        statusBot: String? = nil,
        statusTeam: String? = nil,
        composerPlaceholder: String? = nil,
        messageInput: String? = nil,
        sendMessage: String? = nil,
        attachFile: String? = nil,
        removeAttachment: (@Sendable (String) -> String)? = nil,
        you: String? = nil,
        agent: String? = nil,
        automated: String? = nil,
        botTyping: (@Sendable (String) -> String)? = nil,
        teamTyping: String? = nil,
        sending: String? = nil,
        notSent: String? = nil,
        tapToRetry: String? = nil,
        discard: String? = nil,
        uploading: (@Sendable (Int) -> String)? = nil,
        uploadFailed: String? = nil,
        sessionExpired: String? = nil,
        conversationEnded: String? = nil,
        unavailable: String? = nil,
        sendFailed: String? = nil,
        busy: String? = nil,
        attachmentsOff: String? = nil,
        typeNotAllowed: (@Sendable (String) -> String)? = nil,
        fileTooLarge: (@Sendable (String, Double) -> String)? = nil,
        tooManyFiles: (@Sendable (Int) -> String)? = nil,
        openAttachment: (@Sendable (String) -> String)? = nil,
        attachment: String? = nil,
        image: String? = nil,
        preChatTitle: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        required: (@Sendable (String) -> String)? = nil,
        startChat: String? = nil,
        privacyPolicy: String? = nil,
        moreOptions: String? = nil
    ) -> GiovChatStrings {
        func keep(_ value: String?, _ fallback: String) -> String {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
            return value
        }
        var copy = self
        copy.loading = keep(loading, self.loading)
        copy.tryAgain = keep(tryAgain, self.tryAgain)
        copy.retry = keep(retry, self.retry)
        copy.closeChat = keep(closeChat, self.closeChat)
        copy.connecting = keep(connecting, self.connecting)
        copy.reconnecting = keep(reconnecting, self.reconnecting)
        copy.statusPerson = keep(statusPerson, self.statusPerson)
        copy.statusBot = keep(statusBot, self.statusBot)
        copy.statusTeam = keep(statusTeam, self.statusTeam)
        copy.composerPlaceholder = keep(composerPlaceholder, self.composerPlaceholder)
        copy.messageInput = keep(messageInput, self.messageInput)
        copy.sendMessage = keep(sendMessage, self.sendMessage)
        copy.attachFile = keep(attachFile, self.attachFile)
        copy.removeAttachment = removeAttachment ?? self.removeAttachment
        copy.you = keep(you, self.you)
        copy.agent = keep(agent, self.agent)
        copy.automated = keep(automated, self.automated)
        copy.botTyping = botTyping ?? self.botTyping
        copy.teamTyping = keep(teamTyping, self.teamTyping)
        copy.sending = keep(sending, self.sending)
        copy.notSent = keep(notSent, self.notSent)
        copy.tapToRetry = keep(tapToRetry, self.tapToRetry)
        copy.discard = keep(discard, self.discard)
        copy.uploading = uploading ?? self.uploading
        copy.uploadFailed = keep(uploadFailed, self.uploadFailed)
        copy.sessionExpired = keep(sessionExpired, self.sessionExpired)
        copy.conversationEnded = keep(conversationEnded, self.conversationEnded)
        copy.unavailable = keep(unavailable, self.unavailable)
        copy.sendFailed = keep(sendFailed, self.sendFailed)
        copy.busy = keep(busy, self.busy)
        copy.attachmentsOff = keep(attachmentsOff, self.attachmentsOff)
        copy.typeNotAllowed = typeNotAllowed ?? self.typeNotAllowed
        copy.fileTooLarge = fileTooLarge ?? self.fileTooLarge
        copy.tooManyFiles = tooManyFiles ?? self.tooManyFiles
        copy.openAttachment = openAttachment ?? self.openAttachment
        copy.attachment = keep(attachment, self.attachment)
        copy.image = keep(image, self.image)
        copy.preChatTitle = keep(preChatTitle, self.preChatTitle)
        copy.firstName = keep(firstName, self.firstName)
        copy.lastName = keep(lastName, self.lastName)
        copy.email = keep(email, self.email)
        copy.phone = keep(phone, self.phone)
        copy.required = required ?? self.required
        copy.startChat = keep(startChat, self.startChat)
        copy.privacyPolicy = keep(privacyPolicy, self.privacyPolicy)
        copy.moreOptions = keep(moreOptions, self.moreOptions)
        return copy
    }

    /// The sentence a person sees for a failure; the SDK never shows server text.
    public func describeError(_ error: Error) -> String {
        guard let error = error as? GiovChatError else { return unavailable }
        switch error.kind {
        case .sessionExpired: return sessionExpired
        case .conversationClosed: return conversationEnded
        case .workspaceBusy: return busy
        case .attachmentRejected: return uploadFailed
        case .sendFailed: return sendFailed
        default: return unavailable
        }
    }

    /// A problem from ``GiovChatController/checkFiles(_:alreadyAttached:)`` as a sentence.
    public func describeProblem(_ problem: GiovAttachmentProblem) -> String {
        switch problem {
        case .disabled: return attachmentsOff
        case .typeNotAllowed(let name): return typeNotAllowed(name)
        case .tooLarge(let name, let maxSizeMb): return fileTooLarge(name, maxSizeMb)
        case .tooMany(let max): return tooManyFiles(max)
        }
    }

    /// Every shipped language, by code.
    public static let all: [String: GiovChatStrings] = ["en": .en, "fr": .fr, "es": .es, "pt": .pt, "de": .de]

    public static let en = GiovChatStrings(
        loading: "Loading…",
        tryAgain: "Try again",
        retry: "Retry",
        closeChat: "Close chat",
        connecting: "Connecting…",
        reconnecting: "Connection lost. Reconnecting…",
        statusPerson: "Live agent",
        statusBot: "AI assistant · Online",
        statusTeam: "We'll be with you shortly",
        composerPlaceholder: "Type a message…",
        messageInput: "Message",
        sendMessage: "Send message",
        attachFile: "Attach file",
        removeAttachment: { "Remove \($0)" },
        you: "You",
        agent: "Agent",
        automated: "Automated",
        botTyping: { "\($0) is typing" },
        teamTyping: "Support team is typing",
        sending: "Sending…",
        notSent: "Not sent",
        tapToRetry: "Tap to retry",
        discard: "Discard",
        uploading: { "Uploading \($0)%" },
        uploadFailed: "File upload failed",
        sessionExpired: "Chat session expired. Please start a new chat.",
        conversationEnded: "This conversation has ended.",
        unavailable: "Chat is unavailable. Please try again.",
        sendFailed: "Message could not be sent.",
        busy: "The team is busy right now. Please try again in a moment.",
        attachmentsOff: "File attachments are turned off for this chat.",
        typeNotAllowed: { "\($0): this file type is not allowed." },
        fileTooLarge: { "\($0): files must be \(n($1)) MB or smaller." },
        tooManyFiles: { "You can attach up to \($0) files at a time." },
        openAttachment: { "Open \($0)" },
        attachment: "Attachment",
        image: "Image",
        preChatTitle: "Before we start…",
        firstName: "First name",
        lastName: "Last name",
        email: "Email",
        phone: "Phone",
        required: { "\($0) *" },
        startChat: "Start chat",
        privacyPolicy: "GDPR and privacy",
        moreOptions: "More options"
    )

    public static let fr = GiovChatStrings(
        loading: "Chargement…",
        tryAgain: "Réessayer",
        retry: "Réessayer",
        closeChat: "Fermer le chat",
        connecting: "Connexion…",
        reconnecting: "Connexion perdue. Reconnexion…",
        statusPerson: "Conseiller en ligne",
        statusBot: "Assistant IA · En ligne",
        statusTeam: "Nous vous répondons très vite",
        composerPlaceholder: "Écrivez un message…",
        messageInput: "Message",
        sendMessage: "Envoyer le message",
        attachFile: "Joindre un fichier",
        removeAttachment: { "Retirer \($0)" },
        you: "Vous",
        agent: "Conseiller",
        automated: "Automatique",
        botTyping: { "\($0) écrit" },
        teamTyping: "L'équipe écrit",
        sending: "Envoi…",
        notSent: "Non envoyé",
        tapToRetry: "Touchez pour réessayer",
        discard: "Supprimer",
        uploading: { "Envoi \($0) %" },
        uploadFailed: "Échec de l'envoi du fichier",
        sessionExpired: "La session de chat a expiré. Démarrez un nouveau chat.",
        conversationEnded: "Cette conversation est terminée.",
        unavailable: "Le chat est indisponible. Réessayez.",
        sendFailed: "Le message n'a pas pu être envoyé.",
        busy: "L'équipe est très occupée. Réessayez dans un instant.",
        attachmentsOff: "Les pièces jointes sont désactivées pour ce chat.",
        typeNotAllowed: { "\($0) : ce type de fichier n'est pas autorisé." },
        fileTooLarge: { "\($0) : les fichiers doivent faire \(n($1)) Mo maximum." },
        tooManyFiles: { "Vous pouvez joindre jusqu'à \($0) fichiers à la fois." },
        openAttachment: { "Ouvrir \($0)" },
        attachment: "Pièce jointe",
        image: "Image",
        preChatTitle: "Avant de commencer…",
        firstName: "Prénom",
        lastName: "Nom",
        email: "E-mail",
        phone: "Téléphone",
        required: { "\($0) *" },
        startChat: "Démarrer le chat",
        privacyPolicy: "RGPD et confidentialité",
        moreOptions: "Plus d’options"
    )

    public static let es = GiovChatStrings(
        loading: "Cargando…",
        tryAgain: "Reintentar",
        retry: "Reintentar",
        closeChat: "Cerrar chat",
        connecting: "Conectando…",
        reconnecting: "Conexión perdida. Reconectando…",
        statusPerson: "Agente en vivo",
        statusBot: "Asistente de IA · En línea",
        statusTeam: "Te atenderemos en breve",
        composerPlaceholder: "Escribe un mensaje…",
        messageInput: "Mensaje",
        sendMessage: "Enviar mensaje",
        attachFile: "Adjuntar archivo",
        removeAttachment: { "Quitar \($0)" },
        you: "Tú",
        agent: "Agente",
        automated: "Automático",
        botTyping: { "\($0) está escribiendo" },
        teamTyping: "El equipo está escribiendo",
        sending: "Enviando…",
        notSent: "No enviado",
        tapToRetry: "Toca para reintentar",
        discard: "Descartar",
        uploading: { "Subiendo \($0) %" },
        uploadFailed: "No se pudo subir el archivo",
        sessionExpired: "La sesión de chat caducó. Inicia un chat nuevo.",
        conversationEnded: "Esta conversación ha terminado.",
        unavailable: "El chat no está disponible. Inténtalo de nuevo.",
        sendFailed: "No se pudo enviar el mensaje.",
        busy: "El equipo está ocupado ahora. Inténtalo de nuevo en un momento.",
        attachmentsOff: "Los archivos adjuntos están desactivados en este chat.",
        typeNotAllowed: { "\($0): este tipo de archivo no está permitido." },
        fileTooLarge: { "\($0): los archivos deben pesar \(n($1)) MB o menos." },
        tooManyFiles: { "Puedes adjuntar hasta \($0) archivos a la vez." },
        openAttachment: { "Abrir \($0)" },
        attachment: "Archivo adjunto",
        image: "Imagen",
        preChatTitle: "Antes de empezar…",
        firstName: "Nombre",
        lastName: "Apellido",
        email: "Correo electrónico",
        phone: "Teléfono",
        required: { "\($0) *" },
        startChat: "Iniciar chat",
        privacyPolicy: "RGPD y privacidad",
        moreOptions: "Más opciones"
    )

    public static let pt = GiovChatStrings(
        loading: "Carregando…",
        tryAgain: "Tentar novamente",
        retry: "Tentar novamente",
        closeChat: "Fechar chat",
        connecting: "Conectando…",
        reconnecting: "Conexão perdida. Reconectando…",
        statusPerson: "Atendente ao vivo",
        statusBot: "Assistente de IA · Online",
        statusTeam: "Responderemos em breve",
        composerPlaceholder: "Digite uma mensagem…",
        messageInput: "Mensagem",
        sendMessage: "Enviar mensagem",
        attachFile: "Anexar arquivo",
        removeAttachment: { "Remover \($0)" },
        you: "Você",
        agent: "Atendente",
        automated: "Automático",
        botTyping: { "\($0) está digitando" },
        teamTyping: "A equipe está digitando",
        sending: "Enviando…",
        notSent: "Não enviada",
        tapToRetry: "Toque para tentar novamente",
        discard: "Descartar",
        uploading: { "Enviando \($0)%" },
        uploadFailed: "Falha ao enviar o arquivo",
        sessionExpired: "A sessão do chat expirou. Inicie um novo chat.",
        conversationEnded: "Esta conversa foi encerrada.",
        unavailable: "O chat está indisponível. Tente novamente.",
        sendFailed: "Não foi possível enviar a mensagem.",
        busy: "A equipe está ocupada agora. Tente novamente em instantes.",
        attachmentsOff: "Os anexos estão desativados neste chat.",
        typeNotAllowed: { "\($0): este tipo de arquivo não é permitido." },
        fileTooLarge: { "\($0): os arquivos devem ter até \(n($1)) MB." },
        tooManyFiles: { "Você pode anexar até \($0) arquivos por vez." },
        openAttachment: { "Abrir \($0)" },
        attachment: "Anexo",
        image: "Imagem",
        preChatTitle: "Antes de começar…",
        firstName: "Nome",
        lastName: "Sobrenome",
        email: "E-mail",
        phone: "Telefone",
        required: { "\($0) *" },
        startChat: "Iniciar chat",
        privacyPolicy: "RGPD e privacidade",
        moreOptions: "Mais opções"
    )

    public static let de = GiovChatStrings(
        loading: "Wird geladen…",
        tryAgain: "Erneut versuchen",
        retry: "Erneut versuchen",
        closeChat: "Chat schließen",
        connecting: "Verbindung wird hergestellt…",
        reconnecting: "Verbindung unterbrochen. Neuer Versuch…",
        statusPerson: "Live-Support",
        statusBot: "KI-Assistent · Online",
        statusTeam: "Wir sind gleich für dich da",
        composerPlaceholder: "Nachricht schreiben…",
        messageInput: "Nachricht",
        sendMessage: "Nachricht senden",
        attachFile: "Datei anhängen",
        removeAttachment: { "\($0) entfernen" },
        you: "Du",
        agent: "Support",
        automated: "Automatisch",
        botTyping: { "\($0) schreibt" },
        teamTyping: "Das Team schreibt",
        sending: "Wird gesendet…",
        notSent: "Nicht gesendet",
        tapToRetry: "Tippen zum Wiederholen",
        discard: "Verwerfen",
        uploading: { "Wird hochgeladen: \($0) %" },
        uploadFailed: "Datei konnte nicht hochgeladen werden",
        sessionExpired: "Die Chat-Sitzung ist abgelaufen. Starte einen neuen Chat.",
        conversationEnded: "Diese Unterhaltung ist beendet.",
        unavailable: "Der Chat ist nicht verfügbar. Bitte versuche es erneut.",
        sendFailed: "Die Nachricht konnte nicht gesendet werden.",
        busy: "Das Team ist gerade ausgelastet. Bitte versuche es gleich noch einmal.",
        attachmentsOff: "Dateianhänge sind in diesem Chat deaktiviert.",
        typeNotAllowed: { "\($0): Dieser Dateityp ist nicht erlaubt." },
        fileTooLarge: { "\($0): Dateien dürfen höchstens \(n($1)) MB groß sein." },
        tooManyFiles: { "Du kannst bis zu \($0) Dateien auf einmal anhängen." },
        openAttachment: { "\($0) öffnen" },
        attachment: "Anhang",
        image: "Bild",
        preChatTitle: "Bevor es losgeht…",
        firstName: "Vorname",
        lastName: "Nachname",
        email: "E-Mail",
        phone: "Telefon",
        required: { "\($0) *" },
        startChat: "Chat starten",
        privacyPolicy: "DSGVO und Datenschutz",
        moreOptions: "Weitere Optionen"
    )
}

/// "fr-CA" becomes "fr", "pt_BR" becomes "pt"; anything not shipped falls back to English.
public func giovResolveLocale(_ value: String?) -> String {
    let lowered = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let language = lowered.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
    return giovLocales.contains(language) ? language : "en"
}

/// The device's preferred language (BCP 47), or "en".
public func giovDeviceLocale() -> String {
    let tag = Locale.preferredLanguages.first ?? Locale.current.identifier
    return tag.isEmpty ? "en" : tag
}

/// The strings for a locale (default: the device language) with the host's overrides on top.
public func giovResolveStrings(_ locale: String? = nil, override: ((GiovChatStrings) -> GiovChatStrings)? = nil) -> GiovChatStrings {
    let base = GiovChatStrings.all[giovResolveLocale(locale ?? giovDeviceLocale())] ?? .en
    return override?(base) ?? base
}

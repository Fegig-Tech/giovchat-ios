import Foundation
@testable import GiovChatCore
import Testing

@Suite struct JSONTests {
    @Test func parsesAndSerializesTheProtocolsShapes() {
        let value = JSONValue.parse(#"{"a":[1,2.5,-3e2,true,false,null,"x\"yé😀"],"b":{}}"#)
        #expect(value == .object([
            "a": .array([.number(1), .number(2.5), .number(-300), .bool(true), .bool(false), .null, .string("x\"yé😀")]),
            "b": .object([:]),
        ]))
        #expect(value?.serialized == #"{"a":[1,2.5,-300,true,false,null,"x\"yé😀"],"b":{}}"#)
        #expect(JSONValue.string("line\nbreak\u{01}").serialized == #""line\nbreak\u0001""#)
    }

    @Test func rejectsInvalidJSON() {
        for bad in ["", "not json", "{", #"{"a":}"#, "[1,]", "01", "{'a':1}", #""unterminated"#, "1 2", "tru"] {
            #expect(JSONValue.parse(bad) == nil, "\(bad)")
        }
        #expect(parseJSONObject("[1]").isEmpty)
    }

    @Test func booleansAndNumbersStayApart() {
        let map = parse(#"{"t":true,"one":1,"zero":0,"s":"true"}"#)
        #expect(map["t"].isTrue)
        #expect(!map["one"].isTrue)
        #expect(map["one"].number == 1)
        #expect(map["t"].number == nil)
        #expect(!map["s"].isTrue)
        #expect(map["zero"].bool == nil)
    }
}

@Suite struct ModelsTests {
    @Test func messagesParseFromSocketFramesAndDeprecatedHistoryRows() throws {
        let socket = try #require(GiovMessage.fromJSON(.object(json(["id": "m1", "role": "visitor", "content": "Hi", "createdAt": 5]))))
        #expect(socket.role == .visitor)
        let row = try #require(GiovMessage.fromJSON(.object(json([
            "id": "h2", "role": "agent", "content": "Hello", "created_at": 7, "is_bot": 1, "is_automated": 0,
            "attachment_id": #"["https://x.test/a.png"]"#,
        ]))))
        #expect(row.isBot)
        #expect(!row.isAutomated)
        #expect(row.createdAt == 7)
        #expect(row.attachments.map(\.url) == ["https://x.test/a.png"])
        #expect(GiovMessage.fromJSON(.object(json(["id": "u", "role": "user", "content": "x", "createdAt": 1])))?.role == .visitor)
        #expect(GiovMessage.fromJSON(.object(json(["id": "x", "role": "system", "content": "x", "createdAt": 1]))) == nil)
        #expect(GiovMessage.fromJSON(.object(json(["id": "x", "role": "agent", "createdAt": 1]))) == nil)
        #expect(GiovMessage.fromJSON(.object(json(["id": "x", "role": "agent", "content": "x", "createdAt": "now"]))) == nil)
        #expect(GiovMessage.fromJSON(.object(json(["id": " ", "role": "agent", "content": "x", "createdAt": 1]))) == nil)
        #expect(GiovMessage.fromJSON(.string("x")) == nil)
    }

    @Test func aPersonsAvatarMustBeHttp() throws {
        let message = try #require(GiovMessage.fromJSON(.object(json([
            "id": "m", "role": "agent", "content": "x", "createdAt": 1, "senderName": "Ada", "senderAvatar": "javascript:alert(1)",
        ]))))
        #expect(message.senderAvatar == nil)
        #expect(message.isFromPerson)
        let bot = try #require(GiovMessage.fromJSON(.object(json([
            "id": "m", "role": "agent", "content": "x", "createdAt": 1, "isBot": true, "senderName": "Bot", "senderAvatar": "https://x.test/a.png",
        ]))))
        #expect(bot.senderAvatar == nil, "only a person carries a sender photo")
        #expect(!bot.isFromPerson)
    }

    @Test func messageKeysStayStable() {
        #expect(GiovMessage(id: "srv", role: .visitor, content: "x", createdAt: 1, clientMessageId: "c").key == "c")
        #expect(GiovMessage(id: "srv", role: .agent, content: "x", createdAt: 1, isBot: true, streamId: "s").key == "stream:s")
        #expect(GiovMessage(id: "srv", role: .agent, content: "x", createdAt: 1, streamId: "s").key == "srv")
    }

    @Test func previewsKeepOnlySafeParts() throws {
        let good = try #require(GiovAttachmentPreview.sanitize(.object(json(["thumb": "data:image/webp;base64,AAAA", "width": 40, "height": 30]))))
        #expect(good.width == 40)
        #expect(good.thumbBase64 == "AAAA")
        #expect(good.thumbData == Data([0, 0, 0]))
        #expect(GiovAttachmentPreview.sanitize(.object(json(["thumb": "data:text/html;base64,AAAA"])))?.thumb == nil, "a script thumb is dropped")
        #expect(GiovAttachmentPreview.sanitize(.object(json(["thumb": "data:image/png;base64,AAAA"]))) == nil)
        #expect(GiovAttachmentPreview.sanitize(.object(json(["thumb": "data:image/jpeg;base64,AAAA\n"]))) == nil)
        #expect(GiovAttachmentPreview.sanitize(.object(json(["width": 40])))?.width == nil, "a lone dimension is dropped")
        #expect(GiovAttachmentPreview.sanitize(.object(json(["width": 99999, "height": 4]))) == nil)
        #expect(GiovAttachmentPreview.sanitize(.object(json(["thumb": "data:image/jpeg;base64," + String(repeating: "A", count: 6000)]))) == nil)
    }

    @Test func attachmentsParseFromTheJsonEncodedUrlListAlignedWithPreviews() {
        let parsed = parseAttachments(.string(#"["https://x.test/a.png","https://x.test/b.pdf"]"#), previews: jsonValue([nil, ["width": 4, "height": 3]] as [Any?]))
        #expect(parsed.count == 2)
        #expect(parsed[0].preview == nil)
        #expect(parsed[1].preview?.width == 4)
        #expect(parseAttachments(.string("not json")).isEmpty)
        #expect(parseAttachments(.string(#"{"a":1}"#)).isEmpty)
        #expect(parseAttachments(nil).isEmpty)
    }

    @Test func attachmentNamesAndImageDetection() {
        let key = GiovAttachment(url: "https://api.test/conversations/c/attachments/attachments%2Ft%2Fc%2Fphoto%20one.png")
        #expect(key.displayName == "photo one.png")
        #expect(key.isImage)
        #expect(!GiovAttachment(url: "https://x.test/a/report.pdf").isImage)
        #expect(GiovAttachment(url: "https://x.test/a/blob", preview: GiovAttachmentPreview(width: 1, height: 1)).isImage)
        #expect(GiovAttachment(url: "https://x.test/a/blob.bin", contentType: "image/png").isImage)
        #expect(GiovAttachment(url: "https://x.test/a/blob", filename: "mine.pdf").displayName == "mine.pdf")
        #expect(GiovAttachment(url: "https://x.test/a/a+b.PNG").displayName == "a+b.PNG")
        #expect(GiovAttachment(url: "https://x.test/a/a+b.PNG").isImage)
    }

    @Test func attachmentPolicyExpandsWildcardsAgainstTheServerTypesOnly() throws {
        let policy = try #require(GiovAttachmentPolicy.fromJSON(.object(json(["enabled": true, "allowedTypes": ["image/*", "application/pdf"], "maxSizeMb": 2]))))
        #expect(policy.allowedTypes.contains("image/png") && policy.allowedTypes.contains("application/pdf"))
        #expect(!policy.allowedTypes.contains("text/plain"))
        #expect(policy.maxBytes == 2 * 1024 * 1024)
        let star = try #require(GiovAttachmentPolicy.fromJSON(.object(json(["allowedTypes": ["*"]]))))
        #expect(star.allowedTypes.count == GiovAttachmentLimits.supportedTypes.count)
        #expect(!star.allowedTypes.contains("application/x-msdownload"), "a wildcard cannot enable anything the server refuses")
        #expect(GiovAttachmentPolicy.fromJSON(.object(json(["maxSizeMb": 500])))?.maxSizeMb == 10)
        #expect(GiovAttachmentPolicy.fromJSON(.object(json(["maxSizeMb": 0])))?.maxSizeMb == 0.1)
        #expect(GiovAttachmentPolicy.fromJSON(.object(json(["enabled": false])))?.enabled == false)
        #expect(GiovAttachmentPolicy.fromJSON(nil) == nil)
        #expect(Set(GiovAttachmentPolicy.default.allowedTypes) == ["image/jpeg", "image/png", "image/gif", "image/webp"])
    }

    @Test func validateAttachmentsAppliesTypeSizeCountAndTheDisabledSwitch() {
        let policy = GiovAttachmentPolicy(enabled: true, allowedTypes: ["image/png", "application/pdf"], maxSizeMb: 1)
        func file(_ name: String, _ type: String, _ size: Int) -> GiovPickedFile {
            var file = GiovPickedFile(name: name, mimeType: type, data: Data())
            file.size = size
            return file
        }
        #expect(giovValidateAttachments([file("a.png", "IMAGE/PNG", 10)], policy: policy).accepted.count == 1)
        let bad = giovValidateAttachments([file("x.exe", "application/x-msdownload", 1), file("big.pdf", "application/pdf", 2 * 1024 * 1024)], policy: policy)
        #expect(bad.accepted.isEmpty)
        #expect(bad.problems == [.typeNotAllowed(name: "x.exe"), .tooLarge(name: "big.pdf", maxSizeMb: 1)])
        let many = giovValidateAttachments((1...7).map { file("\($0).png", "image/png", 1) }, policy: policy, existingCount: 1)
        #expect(many.accepted.count == 4)
        #expect(many.problems == [.tooMany(max: 5)])
        let off = GiovAttachmentPolicy(enabled: false, allowedTypes: [], maxSizeMb: 1)
        #expect(giovValidateAttachments([file("a.png", "image/png", 1)], policy: off).problems == [.disabled])
        #expect(giovValidateAttachments([], policy: off).problems.isEmpty)
    }

    @Test func pickedFilesReadFromMemoryOrDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("giov-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = GiovPickedFile(name: "a.txt", mimeType: "text/plain", fileURL: url)
        #expect(file.size == 5)
        #expect(try file.readData() == Data("hello".utf8))
        #expect(try GiovPickedFile(name: "b", mimeType: "text/plain", data: Data([1, 2])).readData() == Data([1, 2]))
    }

    @Test func uploadPlaceholdersNeedAllThreeValidFields() {
        let thumb = "data:image/jpeg;base64,AAAA"
        #expect(uploadPreview(GiovPickedFile(name: "a", mimeType: "image/png", data: Data(), width: 4, height: 3, thumbnail: thumb)) == UploadPreview(thumb: thumb, width: 4, height: 3))
        #expect(uploadPreview(GiovPickedFile(name: "a", mimeType: "image/png", data: Data(), width: 4, thumbnail: thumb)) == nil)
        #expect(uploadPreview(GiovPickedFile(name: "a", mimeType: "application/pdf", data: Data(), width: 4, height: 3, thumbnail: thumb)) == nil)
        #expect(uploadPreview(GiovPickedFile(name: "a", mimeType: "image/png", data: Data(), width: 0, height: 3, thumbnail: thumb)) == nil)
        #expect(uploadPreview(GiovPickedFile(name: "a", mimeType: "image/png", data: Data(), width: 4, height: 3, thumbnail: "data:image/png;base64,AA")) == nil)
    }

    @Test func downloadsCarryExactlyOneCredential() {
        #expect(giovAttachmentDisplayURL("https://x.test/a", accessToken: "ACCESS", visitorToken: "V") == "https://x.test/a?at=ACCESS")
        #expect(giovAttachmentDisplayURL("https://x.test/a?k=1", visitorToken: "V+") == "https://x.test/a?k=1&token=V%2B")
        #expect(giovAttachmentDisplayURL("https://x.test/a") == "https://x.test/a")
    }

    @Test func accessTokensAreValidatedAndTheOneThatExpiresLastIsKept() throws {
        #expect(GiovAttachmentAccess.fromJSON(.object(json(["token": "short", "expiresAt": 1]))) == nil)
        #expect(GiovAttachmentAccess.fromJSON(.object(json(["token": "access-token-abcdefgh"]))) == nil)
        let early = try #require(GiovAttachmentAccess.fromJSON(.object(json(["token": "access-token-abcdefgh", "expiresAt": 1_000]))))
        let late = try #require(GiovAttachmentAccess.fromJSON(.object(json(["token": "access-token-zzzzzzzz", "expiresAt": 2_000]))))
        #expect(GiovAttachmentAccess.newer(early, late) == late)
        #expect(GiovAttachmentAccess.newer(late, early) == late)
        #expect(GiovAttachmentAccess.newer(nil, early) == early)
        #expect(GiovAttachmentAccess.newer(early, nil) == early)
        let token = GiovAttachmentAccess(token: "access-token-abcdefgh", expiresAt: 10 * 60_000)
        #expect(token.usable(at: 4 * 60_000))
        #expect(!token.usable(at: 5 * 60_000 + 1), "stops 5 minutes early")
        #expect(!String(describing: token).contains("abcdefgh"))
    }

    @Test func visitorTokenExpiryIsInSecondsAndRenewedWithinAMinute() throws {
        let token = try #require(VisitorToken.fromJSON(json(["token": "jwt", "expiresAt": 1_000]), now: epoch))
        #expect(token.expiresAt == 1_000_000)
        #expect(token.usable(at: 1_000_000 - 61_000))
        #expect(!token.usable(at: 1_000_000 - 60_000))
        #expect(VisitorToken.fromJSON(json(["token": "jwt"]), now: epoch)?.expiresAt == epoch + 14 * 60_000)
        #expect(VisitorToken.fromJSON(json(["nope": 1]), now: epoch) == nil)
    }

    @Test func widgetConfigIsParsedDefensively() {
        let config = GiovWidgetConfig.fromJSON(json([
            "title": " Acme ", "theme": "dark", "botEnabled": true, "botName": "Atlas",
            "botAvatarUrl": "javascript:x", "avatarUrl": "https://x.test/a.png", "showBranding": false,
            "requestUserInfo": ["email": true], "launcherStyle": "weird", "unknownField": 1,
            "attachments": ["enabled": false], "privacyPolicyUrl": "https://x.test/p", "textArea": "  ",
        ]))
        #expect(config.title == "Acme")
        #expect(config.theme == .dark)
        #expect(config.botAvatarURL == nil)
        #expect(config.avatarURL == "https://x.test/a.png")
        #expect(config.privacyPolicyURL == "https://x.test/p")
        #expect(config.textArea == nil)
        #expect(!config.showBranding)
        #expect(config.requestUserInfo.email && !config.requestUserInfo.phone)
        #expect(config.launcherStyle == "bubble")
        #expect(!config.attachmentPolicy.enabled)
        let plain = GiovWidgetConfig.fromJSON(json(["title": "x"]))
        #expect(plain.showBranding)
        #expect(plain.primaryColor == GiovWidgetConfig.defaultPrimaryColor)
        #expect(plain.theme == .auto)
        #expect(plain.attachmentPolicy == .default)
        #expect(GiovWidgetConfig.fromJSON(json(["title": "x", "launcherStyle": "pill"])).launcherStyle == "pill")
    }

    @Test func mergeKeepsTheKeyAMessageWasShownUnderAndSortsByTime() {
        let acked = GiovMessage(id: "srv-1", role: .visitor, content: "hi", createdAt: 10, clientMessageId: "c1")
        let fromHistory = GiovMessage(id: "srv-1", role: .visitor, content: "hi", createdAt: 10)
        let reply = GiovMessage(id: "srv-2", role: .agent, content: "yo", createdAt: 5)
        let merged = mergeMessages([acked], [fromHistory, reply])
        #expect(merged.map(\.id) == ["srv-2", "srv-1"])
        #expect(merged.last?.key == "c1")
    }

    @Test func displayShowsSavedThenSendingThenDraftsWithoutDuplicates() throws {
        let saved = [GiovMessage(id: "s1", role: .visitor, content: "a", createdAt: 1, clientMessageId: "c1")]
        let outbox = Outbox()
        try outbox.enqueue("a", now: 1, clientMessageId: "c1")
        try outbox.enqueue("b", now: 2, clientMessageId: "c2")
        let shown = displayMessages(saved: saved, pending: outbox.list(), drafts: [("r1", GiovDraft(content: "typing", createdAt: 3)), ("r2", GiovDraft(content: "", createdAt: 4))])
        #expect(shown.map(\.key) == ["c1", "c2", "stream:r1"])
        #expect(shown[1].delivery == .sending)
        #expect(shown[2].isStreaming && shown[2].isBot)
    }

    @Test func missingContactFieldsHonoursTheFormAndRejectsMalformedEmail() {
        let ask = GiovRequestUserInfo(email: true, firstName: true)
        #expect(missingContactFields(ask, contact: GiovContact()) == ask)
        #expect(missingContactFields(ask, contact: GiovContact(email: "not-an-email", firstName: "Ada")) == GiovRequestUserInfo(email: true))
        #expect(!missingContactFields(ask, contact: GiovContact(email: "ada@acme.co", firstName: "Ada")).any)
    }

    @Test func errorsDescribeThemselvesWithoutSecrets() {
        let error = GiovChatError.server("boom", status: 500, code: "internal")
        #expect(error.description == "GiovChatError.server: boom (500 internal)")
        #expect(KeychainLockedError().asGiovError.kind == .network)
        #expect(GiovChatError.rateLimited("x", retryAfterSeconds: 7).retryAfterSeconds == 7)
    }

    @Test func apnsTokensAreLowercaseHex() {
        #expect(giovAPNsTokenString(Data([0x00, 0xAB, 0x10, 0xff])) == "00ab10ff")
    }
}

private struct KeychainLockedError: Error {}

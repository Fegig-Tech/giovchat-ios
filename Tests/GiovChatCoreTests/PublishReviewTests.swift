import Foundation
@testable import GiovChatCore
import Testing
#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

// Regressions found in the pre-publish review (see each test).

/// A Keychain before the first unlock after a reboot: reads fail until `locked` is cleared.
@MainActor
final class LockedStore: RecordingStore {
    var locked = true

    override func read(scope: String) async throws -> GiovSession? {
        if locked { throw KeychainLocked() }
        return try await super.read(scope: scope)
    }
}

/// A store whose writes wait until ``release()``.
@MainActor
final class SlowWriteStore: RecordingStore {
    private var holding = true
    private var waiting: [CheckedContinuation<Void, Never>] = []

    override func write(scope: String, session: GiovSession) async throws {
        if holding { await withCheckedContinuation { waiting.append($0) } }
        try await super.write(scope: scope, session: session)
    }

    func release() {
        holding = false
        let pending = waiting
        waiting.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

@MainActor
@Suite struct PublishReviewTests {
    @Test func anUnknownErrorFrameCodeRefusesTheOldestMessageLikeInvalidMessage() async {
        // visitor-realtime.asyncapi.yaml, ErrorFrame: "Other codes may be added; treat an unknown one as
        // `invalid_message`". It used to be ignored: the message stayed "sending" until the ack watchdog dropped the
        // socket, and every resend was refused again.
        let rig = ClientRig()
        await rig.connect()
        let socket = rig.sockets.last
        let a = rig.send("a")
        let b = rig.send("b")
        socket.receive(["type": "error", "error": "message_too_spicy"])
        await rig.pump()
        #expect(rig.outbox[a]?.state == .failed)
        #expect(rig.outbox[b]?.state == .sending)
        #expect(rig.recorded.errors.map(\.kind) == [.sendFailed])
        #expect(rig.recorded.errors.map(\.code) == ["message_too_spicy"])
        // A `message_failed` without the id it is about stays ignored.
        socket.receive(["type": "error", "error": "message_failed"])
        await rig.pump()
        #expect(rig.outbox[b]?.state == .sending)
        #expect(rig.recorded.errors.count == 1)
        rig.client.dispose()
    }

    @Test func uploadFailuresThatAreNotAboutTheFileKeepTheirMeaning() async {
        // The upload route answers 404 for a conversation that is gone, 429 when rate limited and 5xx; all of them
        // used to be reported as `attachmentRejected`.
        let rig = ClientRig()
        await rig.connect()
        let file = GiovPickedFile(name: "a.png", mimeType: "image/png", data: Data(count: 4))
        rig.server.uploadStatuses = [429]
        let limited = await rig.failure { _ = try await rig.client.uploadAttachment(file) }
        #expect(limited?.kind == .rateLimited)
        #expect(limited?.retryAfterSeconds == 30)
        rig.server.uploadStatuses = [503]
        #expect(await rig.failure { _ = try await rig.client.uploadAttachment(file) }?.kind == .server)
        rig.server.uploadStatuses = [404]
        let gone = await rig.failure { _ = try await rig.client.uploadAttachment(file) }
        #expect(gone?.kind == .conversationClosed)
        #expect(gone?.status == 404)
        rig.server.uploadStatuses = [413]
        #expect(await rig.failure { _ = try await rig.client.uploadAttachment(file) }?.kind == .attachmentRejected)
        rig.client.dispose()
    }

    @Test func theControllerShowsUploadFailedButReportsTheCauseAndForgetsAConversationThatIsGone() async {
        let rig = CRig()
        await rig.start()
        await rig.begin()
        let file = GiovPickedFile(name: "a.png", mimeType: "image/png", data: Data(count: 8))
        rig.server.uploadStatuses = [429]
        #expect(await !rig.controller.send("", files: [file]))
        #expect(rig.ui.error?.kind == .attachmentRejected, "the visitor reads that the upload failed")
        #expect(rig.ui.error?.retryAfterSeconds == 30)
        #expect(rig.errors.last?.kind == .rateLimited, "the host learns why")
        #expect(rig.ui.hasConversation)

        rig.server.uploadStatuses = [404]
        #expect(await !rig.controller.send("", files: [file]))
        await rig.pump()
        #expect(rig.errors.last?.kind == .conversationClosed)
        #expect(!rig.ui.hasConversation, "the deleted conversation is forgotten")
        #expect(rig.ui.error?.kind == .conversationClosed)
        #expect(rig.phase == .ready)
        #expect(rig.store.log.contains("delete"))
        await rig.dispose()
    }

    @Test func aStoreThatCannotBeReadYetIsReadAgainBeforeANewConversationReplacesTheStoredOne() async {
        // errSecInteractionNotAllowed (an app woken before the first unlock) used to count as "nothing stored": the
        // visitor's next message then started a new conversation and overwrote the stored one.
        let store = LockedStore()
        let rig = CRig(stored: testSession, store: store)
        await rig.start()
        #expect(rig.phase == .ready)
        #expect(rig.errors.contains { $0.kind == .storage })
        #expect(rig.server.count("resumed") == 0)
        store.locked = false
        #expect(await rig.controller.send("Hello again"))
        await rig.pump()
        await rig.open()
        #expect(rig.server.count("resumed") == 1, "the stored conversation is resumed")
        #expect(rig.server.count("created") == 0)
        #expect(!store.log.contains("write"), "and never overwritten")
        #expect(rig.phase == .active)
        #expect(rig.socket.messageFrames().last?["content"].string == "Hello again")
        await rig.dispose()
    }

    @Test func aResetWhileTheNewSessionIsBeingStoredLeavesNothingStored() async {
        // The Keychain store runs on the global executor, so a reset's delete could finish before the write of the
        // conversation it forgets: the session then survived the sign-out.
        let store = SlowWriteStore()
        let rig = CRig(store: store)
        await rig.start()
        #expect(await rig.controller.send("Hi"))
        await rig.pump()
        #expect(rig.server.count("created") == 1, "the session is being written")
        let reset = rig.start { await rig.controller.reset() }
        await rig.pump()
        store.release()
        await rig.pump()
        #expect(reset.isCompleted)
        #expect(store.log == ["write", "delete"])
        let scope = giovSessionScope(baseURL: "https://api.example.test", tenantKey: "t", contact: GiovContact())
        let left = try? await store.read(scope: scope)
        #expect(left == nil)
        #expect(rig.phase == .ready)
        await rig.dispose()
    }

    @Test func pushRegistrationCarriesTheClientMarker() async throws {
        // visitor-api.openapi.yaml, registerPushToken: the server stores `X-Giov-Client` with the device.
        let rig = ClientRig()
        await rig.connect()
        #expect(await rig.client.registerPushToken(String(repeating: "ab", count: 32), platform: .apns).registered)
        let request = try #require(rig.server.to("/conversations/conv-1/push-token", "POST").first)
        #expect(request.headers["X-Giov-Client"] == "ios/\(GiovChatVersion.current)")
        rig.client.dispose()
    }
}

#if canImport(ImageIO) && canImport(CoreGraphics)
@Suite struct ImagePlaceholderTests {
    @Test func aTransparentPNGGetsAWhitePlaceholderNotABlackOne() throws {
        // JPEG has no alpha: the clear pixels of a PNG logo or screenshot used to turn black in the placeholder
        // every viewer sees. The web widget fills white.
        let png = try #require(transparentPNG(width: 8, height: 8))
        let result = try #require(GiovImagePlaceholder.make(from: png))
        #expect(result.width == 8 && result.height == 8)
        let prefix = "data:image/jpeg;base64,"
        #expect(result.thumbnail.hasPrefix(prefix))
        let jpeg = try #require(Data(base64Encoded: String(result.thumbnail.dropFirst(prefix.count))))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixel = try #require(averagePixel(image))
        #expect(pixel.allSatisfy { $0 > 230 }, "white, not black: \(pixel)")
    }
}

private func transparentPNG(width: Int, height: Int) -> Data? {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}

/// The image scaled to one pixel: its average red, green and blue.
private func averagePixel(_ image: CGImage) -> [UInt8]? {
    var pixel = [UInt8](repeating: 0, count: 4)
    let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return true
    }
    return drawn ? Array(pixel.prefix(3)) : nil
}
#endif

#if os(macOS)
@Suite(.serialized) struct KeychainStoreTests {
    @Test func theKeychainStoreRoundTripsWithOrWithoutTheDataProtectionKeychain() async throws {
        // On macOS the store asks for the data protection keychain and falls back to the login keychain when the
        // process has no keychain entitlement (`swift test` has none).
        let store = KeychainGiovSessionStore(service: "app.giovchat.tests.\(UUID().uuidString)")
        let scope = "scope"
        #expect(try await store.read(scope: scope) == nil)
        try await store.write(scope: scope, session: testSession)
        #expect(try await store.read(scope: scope) == testSession)
        let other = GiovSession(conversationId: "conv-2", sessionToken: String(repeating: "c", count: 64))
        try await store.write(scope: scope, session: other)
        #expect(try await store.read(scope: scope) == other)
        try await store.delete(scope: scope)
        #expect(try await store.read(scope: scope) == nil)
        try await store.delete(scope: scope)
    }
}
#endif

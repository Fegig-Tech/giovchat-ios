import Foundation

/// A registration made with ``GiovChatController/observe(_:)`` or ``GiovUnread/observe(tenantKey:_:)``. It stops
/// when ``cancel()`` is called or when it is released; keep it for as long as you want updates.
public final class GiovObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    /// True once cancelled.
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return onCancel == nil
    }

    /// Stops the updates. Safe to call more than once and from any thread.
    public func cancel() {
        lock.lock()
        let action = onCancel
        onCancel = nil
        lock.unlock()
        action?()
    }

    deinit {
        cancel()
    }
}

/// Runs `body` on the main actor: at once when already there, else soon after.
func onMainActor(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        Task { @MainActor in body() }
    }
}

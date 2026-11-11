import Foundation

/// Unread replies per chat controller, so any screen can show a badge without passing the controller around. Each
/// ``GiovChatController`` publishes its own count under its workspace key.
///
/// Counts only while a controller with `keepConnected: true` stays connected; opening the chat clears it. Main
/// actor only.
@MainActor
public enum GiovUnread {
    private struct Entry {
        let tenantKey: String
        let count: Int
    }

    private static var counts: [ObjectIdentifier: Entry] = [:]
    private static var observers: [Int: (tenantKey: String?, last: Int, onChange: @MainActor (Int) -> Void)] = [:]
    private static var nextObserver = 0

    /// Called by the controller; apps do not need it.
    static func publish(owner: AnyObject, tenantKey: String, count: Int) {
        let id = ObjectIdentifier(owner)
        if let current = counts[id], current.tenantKey == tenantKey, current.count == count { return }
        counts[id] = Entry(tenantKey: tenantKey, count: count)
        republish()
    }

    static func forget(owner: AnyObject) {
        if counts.removeValue(forKey: ObjectIdentifier(owner)) != nil { republish() }
    }

    /// Agent replies not seen because the chat was closed, summed over all chats (or one workspace).
    public static func count(tenantKey: String? = nil) -> Int {
        counts.values.filter { tenantKey == nil || $0.tenantKey == tenantKey }.reduce(0) { $0 + $1.count }
    }

    /// Calls `onChange` with the count now and whenever it changes, until the returned observation is cancelled or
    /// released.
    public static func observe(tenantKey: String? = nil, _ onChange: @escaping @MainActor (Int) -> Void) -> GiovObservation {
        let id = nextObserver
        nextObserver += 1
        let current = count(tenantKey: tenantKey)
        observers[id] = (tenantKey, current, onChange)
        onChange(current)
        return GiovObservation {
            onMainActor { GiovUnread.observers[id] = nil }
        }
    }

    private static func republish() {
        for id in observers.keys.sorted() {
            guard let observer = observers[id] else { continue }
            let value = count(tenantKey: observer.tenantKey)
            if value == observer.last { continue }
            observers[id]?.last = value
            observer.onChange(value)
        }
    }
}

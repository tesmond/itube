import Foundation

/// Bounded TTL + LRU cache. An actor, so there are no locks and no main-thread contention (ADR §44, §56).
public actor MetadataCache<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry { var value: Value; var expiry: Date }
    private var storage: [Key: Entry] = [:]
    private var order: [Key] = []   // least-recently-used first
    private let capacity: Int
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    public init(capacity: Int = 64, ttl: TimeInterval = 300, now: @escaping @Sendable () -> Date = { .now }) {
        self.capacity = max(1, capacity); self.ttl = ttl; self.now = now
    }

    public func value(for key: Key) -> Value? {
        guard let entry = storage[key] else { return nil }
        guard entry.expiry > now() else { remove(key); return nil }
        touch(key)
        return entry.value
    }

    public func insert(_ value: Value, for key: Key, ttl override: TimeInterval? = nil) {
        storage[key] = Entry(value: value, expiry: now().addingTimeInterval(override ?? ttl))
        touch(key)
        while storage.count > capacity, let oldest = order.first { remove(oldest) }
    }

    public func remove(_ key: Key) {
        storage[key] = nil
        order.removeAll { $0 == key }
    }

    public func removeAll() { storage.removeAll(); order.removeAll() }
    public var count: Int { storage.count }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

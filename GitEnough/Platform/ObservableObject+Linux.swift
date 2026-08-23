#if !canImport(Combine)
import Foundation

/// A minimal stand-in for the two Combine symbols GitEnough's model layer uses:
/// `ObservableObject` and `@Published`. Combine ships only on Apple platforms,
/// and without these the whole `Model/` layer — the view models that hold every
/// repository's state — would be macOS-only, which is most of what a Linux front
/// end needs to reuse.
///
/// The contract is deliberately the small subset the app actually relies on:
/// setting a `@Published` property fires `objectWillChange` *before* the value
/// changes, and observers are called on whatever thread performed the write
/// (GitEnough always writes model state on main). Nothing here tries to be
/// Combine: there are no operators, no back-pressure, no `Publisher` protocol.
///
/// On macOS this file compiles to nothing and the real Combine types are used.
public protocol ObservableObject: AnyObject {
    var objectWillChange: ObservableObjectPublisher { get }
}

/// Fan-out for "this object is about to change". Thread-safe; observers run
/// outside the lock so an observer may itself observe or cancel.
public final class ObservableObjectPublisher {

    private let lock = NSLock()
    private var observers: [UUID: () -> Void] = [:]

    public init() {}

    public func send() {
        lock.lock()
        let current = Array(observers.values)
        lock.unlock()
        for observer in current { observer() }
    }

    /// Registers `body`, called on every change until the returned token is
    /// cancelled or released.
    public func sink(_ body: @escaping () -> Void) -> AnyCancellable {
        let id = UUID()
        lock.lock()
        observers[id] = body
        lock.unlock()
        return AnyCancellable { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.observers[id] = nil
            self.lock.unlock()
        }
    }
}

/// A subscription token. Cancels on release, like Combine's.
public final class AnyCancellable {

    private var cancelHandler: (() -> Void)?
    private let lock = NSLock()

    public init(_ cancelHandler: @escaping () -> Void) {
        self.cancelHandler = cancelHandler
    }

    public func cancel() {
        lock.lock()
        let handler = cancelHandler
        cancelHandler = nil
        lock.unlock()
        handler?()
    }

    /// Keeps the token alive for as long as `set` lives.
    public func store(in set: inout Set<AnyCancellable>) { set.insert(self) }

    deinit { cancel() }
}

extension AnyCancellable: Hashable {
    public static func == (lhs: AnyCancellable, rhs: AnyCancellable) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

extension ObservableObject {
    /// The default publisher, created on first use and kept in a weak-keyed
    /// side table — the same synthesis Combine does for free.
    public var objectWillChange: ObservableObjectPublisher {
        PublisherRegistry.shared.publisher(for: self)
    }
}

/// Publishers keyed by object identity, holding their owners weakly.
///
/// `ObjectIdentifier` is only unique among *live* objects, so each entry also
/// keeps a weak reference to its owner and is re-created when the identity has
/// been recycled by a later allocation.
private final class PublisherRegistry {

    public static let shared = PublisherRegistry()

    private struct Entry {
        public weak var owner: AnyObject?
        public let publisher: ObservableObjectPublisher
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var sweepCountdown = sweepInterval
    private static let sweepInterval = 64

    public func publisher(for object: AnyObject) -> ObservableObjectPublisher {
        let key = ObjectIdentifier(object)
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[key], entry.owner === object {
            return entry.publisher
        }
        let publisher = ObservableObjectPublisher()
        entries[key] = Entry(owner: object, publisher: publisher)
        // Amortized cleanup: entries whose owner is gone would otherwise
        // accumulate for the lifetime of the process.
        sweepCountdown -= 1
        if sweepCountdown <= 0 {
            entries = entries.filter { $0.value.owner != nil }
            sweepCountdown = Self.sweepInterval
        }
        return publisher
    }
}

/// Announces `objectWillChange` before each write, exactly like Combine's.
///
/// Implemented through the enclosing-instance subscript so the wrapper can
/// reach the owning object; `wrappedValue` exists only to satisfy the property
/// wrapper contract and is never callable.
@propertyWrapper
public struct Published<Value> {

    private var storedValue: Value

    public init(wrappedValue: Value) {
        self.storedValue = wrappedValue
    }

    public init(initialValue: Value) {
        self.storedValue = initialValue
    }

    @available(*, unavailable,
               message: "@Published is only available on properties of classes")
    public var wrappedValue: Value {
        get { fatalError("@Published requires a class instance") }
        set { fatalError("@Published requires a class instance") }
    }

    public static subscript<EnclosingSelf: ObservableObject>(
        _enclosingInstance instance: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Published<Value>>
    ) -> Value {
        get { instance[keyPath: storageKeyPath].storedValue }
        set {
            instance.objectWillChange.send()
            instance[keyPath: storageKeyPath].storedValue = newValue
        }
    }
}
#endif

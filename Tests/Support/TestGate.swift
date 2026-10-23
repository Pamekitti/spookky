/// Explicit coordination for tests that must observe an operation before releasing it.
public actor TestGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    public init() {}
    public func wait() async {
        arrivals += 1
        let ready = observers.filter { arrivals >= $0.0 }
        observers.removeAll { arrivals >= $0.0 }
        for (_, observer) in ready { observer.resume() }
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    public func waitForArrivals(_ count: Int) async {
        if arrivals >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    public func signal() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Explicit coordination for tests that must observe an operation before releasing it.
public actor TestGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    public func signal() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

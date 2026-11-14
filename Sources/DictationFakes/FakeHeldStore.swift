import Dictation

/// A store kept in memory, outliving the rigs built over it as a file outlives the app, and
/// keeping `HeldStoreContract` as `HeldFile` does.
@MainActor
public final class FakeHeldStore: HeldStore {
    public private(set) var state: HoldState
    /// What is held, as kept.
    public var kept: Held? { state.held }
    /// Every write, in order.
    public private(set) var written: [HoldState] = []
    /// What every write throws, when set; `.lost` keeps nothing, `.stale` leaves what was kept.
    public var failing: HeldUnkept?
    /// The record kept could not be read, and the next read throws this.
    private var spoiled: HeldUnreadable?

    public init(keeping kept: Held? = nil, dismissed: Held? = nil) {
        state = HoldState(held: kept, dismissed: dismissed)
    }

    /// The record kept cannot be read back, `why`, and the next read moves it to `aside`, as
    /// `HeldStoreContract` says: that read throws what it returns, and nothing is held after it.
    @discardableResult
    public func spoil(why: String, movedTo aside: String) -> HeldUnreadable {
        let unreadable = HeldUnreadable(why: why, kept: .movedTo(aside))
        spoiled = unreadable
        return unreadable
    }

    public func read() throws(HeldUnreadable) -> HoldState {
        guard let spoiled else { return state }
        self.spoiled = nil
        state = HoldState()
        throw spoiled
    }

    public func write(_ state: HoldState) throws(HeldUnkept) {
        written.append(state)
        switch failing {
        case nil:
            self.state = state
            spoiled = nil
        case .lost?:
            self.state = HoldState()
            spoiled = nil
        case .stale?: break
        }
        if let failing { throw failing }
    }
}

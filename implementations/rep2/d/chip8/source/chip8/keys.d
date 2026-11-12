/// The keypad state over time.
module chip8.keys;

/// A key-state change taking effect immediately before `cycle` executes.
struct KeyEvent
{
    /// 0-based cycle number.
    ulong cycle;
    /// Bit `k` set means key `k` is held down.
    ushort mask;
}

/**
 * An ordered list of key events consumed incrementally: asking for the state
 * at successive cycles is O(1) per cycle.
 */
struct KeySchedule
{
    /// Events in strictly increasing cycle order.
    KeyEvent[] events;

    private size_t next;
    private ushort current;

    /// Creates a schedule from `events` (strictly increasing in `cycle`).
    this(KeyEvent[] events) @safe pure nothrow @nogc
    {
        this.events = events;
    }

    /**
     * Returns the key mask in effect for `cycle`. Must be called with
     * non-decreasing cycle numbers.
     */
    ushort stateAt(ulong cycle) @safe pure nothrow @nogc
    {
        while (next < events.length && events[next].cycle <= cycle)
            current = events[next++].mask;
        return current;
    }
}

@safe pure nothrow unittest
{
    auto s = KeySchedule([KeyEvent(2, 0x0003), KeyEvent(5, 0)]);
    assert(s.stateAt(0) == 0);
    assert(s.stateAt(1) == 0);
    assert(s.stateAt(2) == 3);
    assert(s.stateAt(4) == 3);
    assert(s.stateAt(5) == 0);
    assert(s.stateAt(100) == 0);
}

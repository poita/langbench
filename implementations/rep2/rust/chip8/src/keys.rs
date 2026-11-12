//! Key schedules: timed changes of the 16-bit keypad state.

/// A change of the keypad state taking effect immediately before a cycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyEvent {
    /// Cycle number (0-based) before which the event takes effect.
    pub cycle: u64,
    /// Key state: bit `k` set means key `k` is held down.
    pub mask: u16,
}

/// An ordered list of [`KeyEvent`]s with strictly increasing cycle numbers.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KeySchedule {
    events: Vec<KeyEvent>,
}

impl KeySchedule {
    /// An empty schedule: all keys stay up.
    pub fn new() -> Self {
        Self::default()
    }

    /// Builds a schedule from events, returning `None` unless the cycle
    /// numbers are strictly increasing.
    pub fn from_events(events: Vec<KeyEvent>) -> Option<Self> {
        if events.windows(2).all(|w| w[0].cycle < w[1].cycle) {
            Some(Self { events })
        } else {
            None
        }
    }

    /// The events, in order.
    pub fn events(&self) -> &[KeyEvent] {
        &self.events
    }

    /// Returns `true` if the schedule has no events.
    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }
}

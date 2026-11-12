//! The key schedule: timed changes of the 16-key keypad state.

/// A single key-state change: from `cycle` on, `mask` is the keypad state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyEvent {
    /// Cycle immediately before which the event takes effect.
    pub cycle: u64,
    /// Bit `k` set means key `k` is held down.
    pub mask: u16,
}

/// An ordered list of [`KeyEvent`]s, strictly increasing in `cycle`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KeySchedule {
    events: Vec<KeyEvent>,
}

impl KeySchedule {
    /// Builds a schedule from events, which must be in strictly increasing
    /// cycle order (not checked here; the parser checks it).
    pub fn new(events: Vec<KeyEvent>) -> Self {
        KeySchedule { events }
    }

    /// The events, in order.
    pub fn events(&self) -> &[KeyEvent] {
        &self.events
    }

    /// Returns a cursor for consuming the schedule in order, O(1) per cycle.
    pub fn cursor(&self) -> Cursor<'_> {
        Cursor {
            events: &self.events,
            next: 0,
        }
    }
}

/// Consumes a [`KeySchedule`] cycle by cycle.
#[derive(Debug, Clone)]
pub struct Cursor<'a> {
    events: &'a [KeyEvent],
    next: usize,
}

impl Cursor<'_> {
    /// Cycle of the next pending event, if any.
    pub fn next_cycle(&self) -> Option<u64> {
        self.events.get(self.next).map(|e| e.cycle)
    }

    /// If an event is due at `cycle`, consumes it and returns its mask.
    pub fn poll(&mut self, cycle: u64) -> Option<u16> {
        match self.events.get(self.next) {
            Some(e) if e.cycle == cycle => {
                self.next += 1;
                Some(e.mask)
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_in_order() {
        let s = KeySchedule::new(vec![
            KeyEvent { cycle: 2, mask: 1 },
            KeyEvent { cycle: 5, mask: 0 },
        ]);
        let mut c = s.cursor();
        assert_eq!(c.poll(0), None);
        assert_eq!(c.poll(2), Some(1));
        assert_eq!(c.poll(2), None);
        assert_eq!(c.next_cycle(), Some(5));
        assert_eq!(c.poll(5), Some(0));
        assert_eq!(c.next_cycle(), None);
    }
}

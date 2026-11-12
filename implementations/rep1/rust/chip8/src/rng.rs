//! The specified 32-bit linear congruential generator.

/// Initial state of the generator.
pub const SEED: u32 = 0x1234_5678;

/// A 32-bit LCG: `s = s * 1103515245 + 12345 (mod 2^32)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Lcg {
    state: u32,
}

impl Default for Lcg {
    fn default() -> Self {
        Lcg { state: SEED }
    }
}

impl Lcg {
    /// Creates a generator with an explicit state.
    pub fn with_state(state: u32) -> Self {
        Lcg { state }
    }

    /// Current internal state.
    pub fn state(&self) -> u32 {
        self.state
    }

    /// Advances the generator once and returns bits 16..24 of the new state.
    ///
    /// ```
    /// let mut r = chip8::Lcg::default();
    /// assert_eq!(r.next_byte(), 0x71);
    /// assert_eq!(r.next_byte(), 0x47);
    /// assert_eq!(r.next_byte(), 0x1d);
    /// ```
    pub fn next_byte(&mut self) -> u8 {
        self.state = self
            .state
            .wrapping_mul(1_103_515_245)
            .wrapping_add(12_345);
        (self.state >> 16) as u8
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spec_states() {
        let mut r = Lcg::default();
        r.next_byte();
        assert_eq!(r.state(), 0x0b71_9151);
        r.next_byte();
        assert_eq!(r.state(), 0x6f47_bdb6);
        r.next_byte();
        assert_eq!(r.state(), 0x2e1d_6ab7);
    }
}

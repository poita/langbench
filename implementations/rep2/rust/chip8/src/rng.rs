//! The 32-bit linear congruential generator used by `CXNN`.

/// Initial state of the generator.
pub const SEED: u32 = 0x1234_5678;

/// A 32-bit LCG: `s = s * 1103515245 + 12345 (mod 2^32)`.
///
/// The output byte is bits 16..24 of the *new* state.
///
/// ```
/// let mut rng = chip8::Lcg::new();
/// assert_eq!(rng.next_byte(), 0x71);
/// assert_eq!(rng.next_byte(), 0x47);
/// assert_eq!(rng.next_byte(), 0x1d);
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Lcg {
    state: u32,
}

impl Lcg {
    /// Creates a generator with the specified seed `0x12345678`.
    pub fn new() -> Self {
        Self { state: SEED }
    }

    /// Creates a generator with an arbitrary state.
    pub fn with_state(state: u32) -> Self {
        Self { state }
    }

    /// Returns the current internal state.
    pub fn state(&self) -> u32 {
        self.state
    }

    /// Advances the generator and returns the next random byte.
    #[inline]
    pub fn next_byte(&mut self) -> u8 {
        self.state = self.state.wrapping_mul(1_103_515_245).wrapping_add(12_345);
        (self.state >> 16) as u8
    }
}

impl Default for Lcg {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_specified_states() {
        let mut r = Lcg::new();
        r.next_byte();
        assert_eq!(r.state(), 0x0b71_9151);
        r.next_byte();
        assert_eq!(r.state(), 0x6f47_bdb6);
        r.next_byte();
        assert_eq!(r.state(), 0x2e1d_6ab7);
    }
}

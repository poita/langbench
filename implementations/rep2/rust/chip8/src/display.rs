//! The 64×32 monochrome frame buffer.

/// Display width in pixels.
pub const WIDTH: usize = 64;
/// Display height in pixels.
pub const HEIGHT: usize = 32;

/// A 64×32 one-bit-per-pixel display.
#[derive(Clone, PartialEq, Eq)]
pub struct Display {
    pixels: [bool; WIDTH * HEIGHT],
}

impl Display {
    /// Creates a blank display.
    pub fn new() -> Self {
        Self { pixels: [false; WIDTH * HEIGHT] }
    }

    /// Turns every pixel off.
    pub fn clear(&mut self) {
        self.pixels.fill(false);
    }

    /// Returns whether the pixel at column `x`, row `y` is lit.
    ///
    /// Coordinates wrap modulo the display size.
    pub fn get(&self, x: usize, y: usize) -> bool {
        self.pixels[(y % HEIGHT) * WIDTH + (x % WIDTH)]
    }

    /// XORs a single pixel (coordinates wrap) and returns `true` if it was
    /// turned *off* by the operation (a collision).
    #[inline]
    pub fn toggle(&mut self, x: usize, y: usize) -> bool {
        let p = &mut self.pixels[(y & (HEIGHT - 1)) * WIDTH + (x & (WIDTH - 1))];
        let was_on = *p;
        *p = !was_on;
        was_on
    }

    /// Returns row `y` as a slice of `WIDTH` pixels.
    pub fn row(&self, y: usize) -> &[bool] {
        &self.pixels[y * WIDTH..(y + 1) * WIDTH]
    }

    /// Returns the number of lit pixels.
    pub fn lit_count(&self) -> usize {
        self.pixels.iter().filter(|&&p| p).count()
    }
}

impl Default for Display {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for Display {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Display({} lit)", self.lit_count())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn toggle_reports_collisions_and_wraps() {
        let mut d = Display::new();
        assert!(!d.toggle(65, 33));
        assert!(d.get(1, 1));
        assert!(d.toggle(1, 1));
        assert!(!d.get(1, 1));
        d.toggle(3, 3);
        d.clear();
        assert_eq!(d.lit_count(), 0);
    }
}

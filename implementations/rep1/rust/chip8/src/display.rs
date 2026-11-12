//! The 64×32 monochrome display.

use std::fmt;

/// Display width in pixels.
pub const WIDTH: usize = 64;
/// Display height in pixels.
pub const HEIGHT: usize = 32;

/// A 64×32 frame buffer of 1-bit pixels, indexed `[row][column]`.
#[derive(Clone, PartialEq, Eq)]
pub struct Display {
    pixels: [[bool; WIDTH]; HEIGHT],
}

impl Default for Display {
    fn default() -> Self {
        Display {
            pixels: [[false; WIDTH]; HEIGHT],
        }
    }
}

impl fmt::Debug for Display {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Display(\n{self})")
    }
}

impl Display {
    /// Turns every pixel off.
    pub fn clear(&mut self) {
        self.pixels = [[false; WIDTH]; HEIGHT];
    }

    /// Returns the pixel at column `x`, row `y` (both taken modulo the size).
    pub fn get(&self, x: usize, y: usize) -> bool {
        self.pixels[y % HEIGHT][x % WIDTH]
    }

    /// XORs a pixel on; returns `true` if it was previously lit (a collision).
    /// Coordinates wrap around the edges.
    pub fn toggle(&mut self, x: usize, y: usize) -> bool {
        let p = &mut self.pixels[y % HEIGHT][x % WIDTH];
        let was = *p;
        *p = !was;
        was
    }

    /// Draws `rows` (one byte per row, MSB leftmost) with its origin at
    /// `(x, y)`, wrapping at the edges. Returns `true` if any lit pixel was
    /// turned off.
    pub fn draw_sprite<I: IntoIterator<Item = u8>>(&mut self, x: usize, y: usize, rows: I) -> bool {
        let (sx, sy) = (x & (WIDTH - 1), y & (HEIGHT - 1));
        let mut collision = false;
        for (row, byte) in rows.into_iter().enumerate() {
            let py = (sy + row) & (HEIGHT - 1);
            for bit in 0..8 {
                if (byte >> (7 - bit)) & 1 != 0 {
                    let px = (sx + bit) & (WIDTH - 1);
                    collision |= self.toggle(px, py);
                }
            }
        }
        collision
    }
}

/// Formats as 32 lines of 64 characters (`#` lit, `.` unlit), each
/// terminated by a newline.
impl fmt::Display for Display {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for row in &self.pixels {
            let line: String = row.iter().map(|&p| if p { '#' } else { '.' }).collect();
            writeln!(f, "{line}")?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn toggle_reports_collision() {
        let mut d = Display::default();
        assert!(!d.toggle(3, 4));
        assert!(d.get(3, 4));
        assert!(d.toggle(3, 4));
        assert!(!d.get(3, 4));
    }

    #[test]
    fn sprite_wraps() {
        let mut d = Display::default();
        let hit = d.draw_sprite(63, 31, [0xC0, 0xC0]);
        assert!(!hit);
        assert!(d.get(63, 31) && d.get(0, 31) && d.get(63, 0) && d.get(0, 0));
    }

    #[test]
    fn display_format() {
        let s = Display::default().to_string();
        assert_eq!(s.lines().count(), 32);
        assert!(s.lines().all(|l| l.len() == 64));
    }
}

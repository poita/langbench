//! The module grid: function patterns, data placement, masking and
//! format/version information.

use crate::tables::ALIGNMENT_POSITIONS;
use crate::version::Version;
use crate::Ecl;

/// A square grid of modules (`true` = dark) that remembers which modules are
/// function modules (finder, timing, alignment, format, version, dark module).
#[derive(Debug, Clone)]
pub struct Matrix {
    version: Version,
    size: usize,
    modules: Vec<bool>,
    is_function: Vec<bool>,
}

impl Matrix {
    /// Creates a grid for `version` with every function pattern drawn and the
    /// format information area reserved (light). Data modules are light.
    pub fn new(version: Version) -> Matrix {
        let size = version.size();
        let mut m = Matrix {
            version,
            size,
            modules: vec![false; size * size],
            is_function: vec![false; size * size],
        };
        m.draw_function_patterns();
        m
    }

    /// Side length in modules.
    pub fn size(&self) -> usize {
        self.size
    }

    /// Whether the module at column `x`, row `y` is dark.
    pub fn get(&self, x: usize, y: usize) -> bool {
        self.modules[y * self.size + x]
    }

    /// Whether the module at column `x`, row `y` is a function module.
    pub fn is_function(&self, x: usize, y: usize) -> bool {
        self.is_function[y * self.size + x]
    }

    fn set_function(&mut self, x: usize, y: usize, dark: bool) {
        let i = y * self.size + x;
        self.modules[i] = dark;
        self.is_function[i] = true;
    }

    fn draw_function_patterns(&mut self) {
        let n = self.size;
        // Timing patterns.
        for i in 8..n - 8 {
            self.set_function(i, 6, i % 2 == 0);
            self.set_function(6, i, i % 2 == 0);
        }
        // Finder patterns with separators.
        for &(cx, cy) in &[(3, 3), (n - 4, 3), (3, n - 4)] {
            self.draw_finder(cx, cy);
        }
        // Alignment patterns.
        if self.version.number() >= 2 {
            let pos = ALIGNMENT_POSITIONS[self.version.number() as usize - 2];
            let last = pos.len() - 1;
            for (i, &px) in pos.iter().enumerate() {
                for (j, &py) in pos.iter().enumerate() {
                    if (i == 0 && j == 0) || (i == last && j == 0) || (i == 0 && j == last) {
                        continue;
                    }
                    self.draw_alignment(px as usize, py as usize);
                }
            }
        }
        // Reserve format area, then version information and the dark module.
        self.draw_format(Ecl::Low, 0);
        self.draw_version();
        self.set_function(8, n - 8, true);
    }

    fn draw_finder(&mut self, cx: usize, cy: usize) {
        for dy in -4i32..=4 {
            for dx in -4i32..=4 {
                let (x, y) = (cx as i32 + dx, cy as i32 + dy);
                if x < 0 || y < 0 || x >= self.size as i32 || y >= self.size as i32 {
                    continue;
                }
                let d = dx.abs().max(dy.abs());
                self.set_function(x as usize, y as usize, matches!(d, 0 | 1 | 3));
            }
        }
    }

    fn draw_alignment(&mut self, cx: usize, cy: usize) {
        for dy in -2i32..=2 {
            for dx in -2i32..=2 {
                let d = dx.abs().max(dy.abs());
                self.set_function((cx as i32 + dx) as usize, (cy as i32 + dy) as usize, d != 1);
            }
        }
    }

    /// Writes both copies of the format information for `ecl` and `mask`.
    pub fn draw_format(&mut self, ecl: Ecl, mask: u8) {
        let bits = format_bits(ecl, mask);
        let bit = |i: usize| (bits >> i) & 1 != 0;
        let n = self.size;
        for i in 0..6 {
            self.set_function(8, i, bit(i));
        }
        self.set_function(8, 7, bit(6));
        self.set_function(8, 8, bit(7));
        self.set_function(7, 8, bit(8));
        for i in 9..15 {
            self.set_function(14 - i, 8, bit(i));
        }
        for i in 0..8 {
            self.set_function(n - 1 - i, 8, bit(i));
        }
        for i in 8..15 {
            self.set_function(8, n - 15 + i, bit(i));
        }
    }

    fn draw_version(&mut self) {
        let v = self.version.number() as u32;
        if v < 7 {
            return;
        }
        let mut rem = v;
        for _ in 0..12 {
            rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        }
        let bits = (v << 12) | rem;
        let n = self.size;
        for i in 0..18 {
            let dark = (bits >> i) & 1 != 0;
            let (a, b) = (n - 11 + i % 3, i / 3);
            self.set_function(a, b, dark);
            self.set_function(b, a, dark);
        }
    }

    /// Places `codewords` (MSB first) along the zigzag in non-function
    /// modules. Modules left over stay light.
    pub fn place_codewords(&mut self, codewords: &[u8]) {
        let n = self.size;
        let total_bits = codewords.len() * 8;
        let mut k = 0;
        let mut right = n as i32 - 1;
        while right >= 1 {
            if right == 6 {
                right = 5;
            }
            let upward = ((right + 1) & 2) == 0;
            for step in 0..n {
                let y = if upward { n - 1 - step } else { step };
                for x in [right as usize, right as usize - 1] {
                    if !self.is_function[y * n + x] && k < total_bits {
                        self.modules[y * n + x] = (codewords[k / 8] >> (7 - k % 8)) & 1 != 0;
                        k += 1;
                    }
                }
            }
            right -= 2;
        }
    }

    /// XORs mask pattern `mask` (0..=7) onto all non-function modules.
    /// Applying the same mask twice restores the original grid.
    pub fn apply_mask(&mut self, mask: u8) {
        let n = self.size;
        for y in 0..n {
            for x in 0..n {
                if !self.is_function[y * n + x] && mask_condition(mask, x, y) {
                    self.modules[y * n + x] ^= true;
                }
            }
        }
    }

    /// Renders the grid as `#`/`.` rows, each terminated by `\n`.
    pub fn render(&self) -> String {
        let mut s = String::with_capacity((self.size + 1) * self.size);
        for y in 0..self.size {
            for x in 0..self.size {
                s.push(if self.get(x, y) { '#' } else { '.' });
            }
            s.push('\n');
        }
        s
    }
}

/// The 15 format bits (after XOR with 0x5412) for `ecl` and `mask`.
pub fn format_bits(ecl: Ecl, mask: u8) -> u32 {
    let data = (ecl.format_bits() << 3) | mask as u32;
    let mut rem = data;
    for _ in 0..10 {
        rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    ((data << 10) | rem) ^ 0x5412
}

/// Whether mask pattern `mask` inverts the module at `(x, y)`.
pub fn mask_condition(mask: u8, x: usize, y: usize) -> bool {
    match mask {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (x / 3 + y / 2) % 2 == 0,
        5 => (x * y) % 2 + (x * y) % 3 == 0,
        6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0,
        7 => ((x + y) % 2 + (x * y) % 3) % 2 == 0,
        _ => panic!("mask out of range: {mask}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_bits_known_value() {
        // M / mask 0 -> 101010000010010 (well-known table value).
        assert_eq!(format_bits(Ecl::Medium, 0), 0b101010000010010);
        // L / mask 0 -> 111011111000100.
        assert_eq!(format_bits(Ecl::Low, 0), 0b111011111000100);
    }

    #[test]
    fn function_module_counts() {
        for v in 1..=40u8 {
            let version = Version::new(v).unwrap();
            let m = Matrix::new(version);
            let free = (0..m.size())
                .flat_map(|y| (0..m.size()).map(move |x| (x, y)))
                .filter(|&(x, y)| !m.is_function(x, y))
                .count();
            assert_eq!(free, version.raw_data_modules(), "version {v}");
        }
    }

    #[test]
    fn mask_is_involution() {
        let mut m = Matrix::new(Version::new(3).unwrap());
        let before = m.render();
        m.apply_mask(5);
        assert_ne!(before, m.render());
        m.apply_mask(5);
        assert_eq!(before, m.render());
    }
}

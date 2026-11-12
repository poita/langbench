//! A from-scratch QR Code Model 2 encoder (ISO/IEC 18004).
//!
//! The crate encodes a byte string as a single-segment QR symbol (numeric,
//! alphanumeric or byte mode, chosen automatically) and exposes the resulting
//! module matrix. It has no dependencies.
//!
//! ```
//! use qrcode::{Ecl, MaskChoice, QrCode};
//!
//! let qr = QrCode::encode(b"HELLO WORLD", Ecl::Medium, MaskChoice::Fixed(0)).unwrap();
//! assert_eq!(qr.version().number(), 1);
//! assert_eq!(qr.size(), 21);
//! assert!(qr.get(0, 0)); // top-left finder corner is dark
//! println!("{}", qr.to_text());
//! ```
//!
//! # Modules
//!
//! * [`segment`]: modes and the segment bit stream
//! * [`version`]: versions and capacities
//! * [`codewords`]: padding, block splitting and interleaving
//! * [`reed_solomon`]: GF(2^8) arithmetic and ECC
//! * [`matrix`]: function patterns, placement, masks, format information
//! * [`penalty`]: automatic mask scoring
//! * [`query`]: parsing of the command-line tool's input lines

pub mod bitbuffer;
pub mod codewords;
pub mod error;
pub mod matrix;
pub mod penalty;
pub mod query;
pub mod reed_solomon;
pub mod segment;
mod tables;
pub mod version;

pub use error::Error;
pub use segment::Mode;
pub use version::Version;

use matrix::Matrix;

/// Error correction level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Ecl {
    /// About 7% of codewords can be restored.
    Low,
    /// About 15%.
    Medium,
    /// About 25%.
    Quartile,
    /// About 30%.
    High,
}

impl Ecl {
    /// Index used by the capacity tables (L=0, M=1, Q=2, H=3).
    pub(crate) fn ordinal(self) -> usize {
        match self {
            Ecl::Low => 0,
            Ecl::Medium => 1,
            Ecl::Quartile => 2,
            Ecl::High => 3,
        }
    }

    /// The two-bit indicator written in the format information.
    pub(crate) fn format_bits(self) -> u32 {
        match self {
            Ecl::Low => 1,
            Ecl::Medium => 0,
            Ecl::Quartile => 3,
            Ecl::High => 2,
        }
    }

    /// Parses `L`, `M`, `Q` or `H`.
    pub fn from_letter(c: u8) -> Option<Ecl> {
        match c {
            b'L' => Some(Ecl::Low),
            b'M' => Some(Ecl::Medium),
            b'Q' => Some(Ecl::Quartile),
            b'H' => Some(Ecl::High),
            _ => None,
        }
    }
}

/// How the mask pattern is chosen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MaskChoice {
    /// Use exactly this mask pattern (`0..=7`).
    Fixed(u8),
    /// Score all eight masks and take the lowest penalty (lowest number on a
    /// tie).
    Auto,
}

/// A finished QR Code symbol.
#[derive(Debug, Clone)]
pub struct QrCode {
    version: Version,
    ecl: Ecl,
    mask: u8,
    matrix: Matrix,
}

impl QrCode {
    /// Encodes `data` (treated as raw bytes) at the given level.
    ///
    /// The mode is selected automatically and the smallest version that holds
    /// the data is used. Fails with [`Error::DataTooLong`] if no version fits.
    ///
    /// # Panics
    ///
    /// Panics if `mask` is `MaskChoice::Fixed(m)` with `m > 7`.
    pub fn encode(data: &[u8], ecl: Ecl, mask: MaskChoice) -> Result<QrCode, Error> {
        if let MaskChoice::Fixed(m) = mask {
            assert!(m < 8, "mask must be 0..=7");
        }
        let mode = Mode::select(data);
        let version = choose_version(data.len(), mode, ecl)?;
        let data_cw = codewords::data_codewords(data, mode, version, ecl);
        let all_cw = codewords::add_ecc_and_interleave(&data_cw, version, ecl);

        let mut base = Matrix::new(version);
        base.place_codewords(&all_cw);

        let finish = |m: u8| {
            let mut grid = base.clone();
            grid.apply_mask(m);
            grid.draw_format(ecl, m);
            grid
        };
        let (mask, matrix) = match mask {
            MaskChoice::Fixed(m) => (m, finish(m)),
            MaskChoice::Auto => {
                let mut best: Option<(u32, u8, Matrix)> = None;
                for m in 0..8 {
                    let grid = finish(m);
                    let score = penalty::penalty(&grid);
                    if best.as_ref().is_none_or(|(s, _, _)| score < *s) {
                        best = Some((score, m, grid));
                    }
                }
                let (_, m, grid) = best.expect("eight candidates");
                (m, grid)
            }
        };
        Ok(QrCode {
            version,
            ecl,
            mask,
            matrix,
        })
    }

    /// Convenience wrapper around [`QrCode::encode`] for UTF-8 text.
    pub fn encode_text(text: &str, ecl: Ecl, mask: MaskChoice) -> Result<QrCode, Error> {
        QrCode::encode(text.as_bytes(), ecl, mask)
    }

    /// The symbol's version.
    pub fn version(&self) -> Version {
        self.version
    }

    /// The error correction level.
    pub fn ecl(&self) -> Ecl {
        self.ecl
    }

    /// The mask pattern in use (`0..=7`).
    pub fn mask(&self) -> u8 {
        self.mask
    }

    /// Side length in modules.
    pub fn size(&self) -> usize {
        self.matrix.size()
    }

    /// Whether the module at column `x`, row `y` is dark. Row 0 is the top.
    ///
    /// # Panics
    ///
    /// Panics if `x` or `y` is outside the symbol.
    pub fn get(&self, x: usize, y: usize) -> bool {
        assert!(x < self.size() && y < self.size());
        self.matrix.get(x, y)
    }

    /// The penalty score (SPEC §12: N1..N4) of this symbol as drawn.
    pub fn penalty_score(&self) -> u32 {
        penalty::penalty(&self.matrix)
    }

    /// Renders the symbol as `size` lines of `#` (dark) and `.` (light), each
    /// ending in a newline. No quiet zone is included.
    pub fn to_text(&self) -> String {
        self.matrix.render()
    }
}

/// Smallest version whose capacity holds the segment, using closed-form bit
/// lengths.
fn choose_version(len: usize, mode: Mode, ecl: Ecl) -> Result<Version, Error> {
    let data_bits = mode.data_bits(len);
    for v in 1..=40 {
        let version = Version::new(v)?;
        let cc = mode.count_bits(version);
        let fits_count = (len as u64) < (1u64 << cc);
        if fits_count && 4 + cc + data_bits <= 8 * version.data_codewords(ecl) {
            return Ok(version);
        }
    }
    Err(Error::DataTooLong)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_selection_edges() {
        // v1-L byte capacity is 17, v2-L is 32.
        let q = |n: usize| QrCode::encode(&vec![b'a'; n], Ecl::Low, MaskChoice::Fixed(0)).unwrap();
        assert_eq!(q(17).version().number(), 1);
        assert_eq!(q(18).version().number(), 2);
    }

    #[test]
    fn max_capacity_and_overflow() {
        let digits = vec![b'7'; 7089];
        let qr = QrCode::encode(&digits, Ecl::Low, MaskChoice::Auto).unwrap();
        assert_eq!(qr.version().number(), 40);
        let digits = vec![b'7'; 7090];
        assert_eq!(
            QrCode::encode(&digits, Ecl::Low, MaskChoice::Auto).unwrap_err(),
            Error::DataTooLong
        );
    }
}

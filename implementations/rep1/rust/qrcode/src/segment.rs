//! Encoding modes and the data bit stream of a single segment.

use crate::bitbuffer::BitBuffer;
use crate::version::Version;

/// The character set used by alphanumeric mode; index = character value.
const ALPHANUMERIC: &[u8; 45] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

/// A QR data encoding mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Decimal digits only.
    Numeric,
    /// Digits, upper-case letters and ``space $ % * + - . / :``.
    Alphanumeric,
    /// Arbitrary bytes.
    Byte,
}

fn alnum_value(b: u8) -> Option<u32> {
    ALPHANUMERIC.iter().position(|&c| c == b).map(|p| p as u32)
}

impl Mode {
    /// Picks the most compact applicable mode for `data`: numeric, then
    /// alphanumeric, then byte.
    pub fn select(data: &[u8]) -> Mode {
        if data.iter().all(u8::is_ascii_digit) {
            Mode::Numeric
        } else if data.iter().all(|&b| alnum_value(b).is_some()) {
            Mode::Alphanumeric
        } else {
            Mode::Byte
        }
    }

    /// The 4-bit mode indicator.
    pub fn indicator(self) -> u32 {
        match self {
            Mode::Numeric => 0b0001,
            Mode::Alphanumeric => 0b0010,
            Mode::Byte => 0b0100,
        }
    }

    /// Width in bits of the character count field at `version`.
    pub fn count_bits(self, version: Version) -> usize {
        let idx = match version.number() {
            1..=9 => 0,
            10..=26 => 1,
            _ => 2,
        };
        match self {
            Mode::Numeric => [10, 12, 14][idx],
            Mode::Alphanumeric => [9, 11, 13][idx],
            Mode::Byte => [8, 16, 16][idx],
        }
    }

    /// Number of data bits (excluding mode indicator and count) needed for
    /// `n` characters.
    pub fn data_bits(self, n: usize) -> usize {
        match self {
            Mode::Numeric => 10 * (n / 3) + [0, 4, 7][n % 3],
            Mode::Alphanumeric => 11 * (n / 2) + 6 * (n % 2),
            Mode::Byte => 8 * n,
        }
    }
}

/// Appends mode indicator, character count and data bits of `data` to `out`.
///
/// `data` must be valid for `mode` (see [`Mode::select`]).
pub fn write_segment(out: &mut BitBuffer, mode: Mode, data: &[u8], version: Version) {
    out.push_bits(mode.indicator(), 4);
    out.push_bits(data.len() as u32, mode.count_bits(version));
    match mode {
        Mode::Numeric => {
            for chunk in data.chunks(3) {
                let value = chunk
                    .iter()
                    .fold(0u32, |acc, &d| acc * 10 + (d - b'0') as u32);
                out.push_bits(value, [0, 4, 7, 10][chunk.len()]);
            }
        }
        Mode::Alphanumeric => {
            for chunk in data.chunks(2) {
                let v: Vec<u32> = chunk
                    .iter()
                    .map(|&b| alnum_value(b).expect("alphanumeric data"))
                    .collect();
                if v.len() == 2 {
                    out.push_bits(45 * v[0] + v[1], 11);
                } else {
                    out.push_bits(v[0], 6);
                }
            }
        }
        Mode::Byte => {
            for &b in data {
                out.push_bits(b as u32, 8);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mode_selection() {
        assert_eq!(Mode::select(b"0123"), Mode::Numeric);
        assert_eq!(Mode::select(b"HELLO WORLD"), Mode::Alphanumeric);
        assert_eq!(Mode::select(b"hello"), Mode::Byte);
        assert_eq!(Mode::select("é".as_bytes()), Mode::Byte);
        assert_eq!(Mode::select(b"12a"), Mode::Byte);
    }

    #[test]
    fn bit_lengths() {
        assert_eq!(Mode::Numeric.data_bits(8), 10 * 2 + 7);
        assert_eq!(Mode::Numeric.data_bits(7), 10 * 2 + 4);
        assert_eq!(Mode::Alphanumeric.data_bits(11), 11 * 5 + 6);
        assert_eq!(Mode::Byte.data_bits(6), 48);
    }

    #[test]
    fn numeric_stream() {
        let mut b = BitBuffer::new();
        write_segment(&mut b, Mode::Numeric, b"01234567", Version::MIN);
        // 0001 | 0000001000 | 0000001100 | 0101011001 | 1000011
        assert_eq!(b.len(), 4 + 10 + 27);
        assert_eq!(b.to_bytes()[..2], [0b0001_0000, 0b0010_0000]);
    }
}

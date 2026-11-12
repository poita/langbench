//! Symbol versions and their capacities.

use crate::error::Error;
use crate::tables::{ECC_CODEWORDS_PER_BLOCK, NUM_ERROR_CORRECTION_BLOCKS};
use crate::Ecl;

/// A QR Code version, `1..=40`. Version `v` has a side of `4v + 17` modules.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Version(u8);

impl Version {
    /// The smallest version (21x21 modules).
    pub const MIN: Version = Version(1);
    /// The largest version (177x177 modules).
    pub const MAX: Version = Version(40);

    /// Creates a version, failing if `v` is outside `1..=40`.
    pub fn new(v: u8) -> Result<Version, Error> {
        if (1..=40).contains(&v) {
            Ok(Version(v))
        } else {
            Err(Error::InvalidVersion(v))
        }
    }

    /// The version number, `1..=40`.
    pub fn number(self) -> u8 {
        self.0
    }

    /// Side length of the symbol in modules.
    pub fn size(self) -> usize {
        4 * self.0 as usize + 17
    }

    /// Number of modules that are not function patterns (data + ECC +
    /// remainder bits).
    pub fn raw_data_modules(self) -> usize {
        let v = self.0 as usize;
        let mut raw = (16 * v + 128) * v + 64;
        if v >= 2 {
            let a = v / 7 + 2;
            raw -= (25 * a - 10) * a - 55;
            if v >= 7 {
                raw -= 36;
            }
        }
        raw
    }

    /// Total codewords (data + ECC) in the symbol.
    pub fn total_codewords(self) -> usize {
        self.raw_data_modules() / 8
    }

    /// ECC codewords in each block at the given level.
    pub fn ecc_per_block(self, ecl: Ecl) -> usize {
        ECC_CODEWORDS_PER_BLOCK[ecl.ordinal()][self.0 as usize - 1] as usize
    }

    /// Number of blocks at the given level.
    pub fn num_blocks(self, ecl: Ecl) -> usize {
        NUM_ERROR_CORRECTION_BLOCKS[ecl.ordinal()][self.0 as usize - 1] as usize
    }

    /// Data codewords available at the given level.
    pub fn data_codewords(self, ecl: Ecl) -> usize {
        self.total_codewords() - self.ecc_per_block(ecl) * self.num_blocks(ecl)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn data_codeword_examples() {
        let v = |n| Version::new(n).unwrap();
        assert_eq!(v(1).data_codewords(Ecl::Low), 19);
        assert_eq!(v(1).data_codewords(Ecl::Medium), 16);
        assert_eq!(v(1).data_codewords(Ecl::Quartile), 13);
        assert_eq!(v(1).data_codewords(Ecl::High), 9);
        assert_eq!(v(40).data_codewords(Ecl::Low), 2956);
        assert_eq!(v(40).data_codewords(Ecl::High), 1276);
        assert_eq!(v(40).total_codewords(), 3706);
    }

    #[test]
    fn rejects_out_of_range() {
        assert!(Version::new(0).is_err());
        assert!(Version::new(41).is_err());
    }
}

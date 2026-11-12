//! Constant tables from RFC 1951.

/// Number of literal/length symbols in the fixed code (including 286, 287).
pub const FIXED_LITLEN_SYMBOLS: usize = 288;
/// Number of distance symbols in the fixed code (including 30, 31).
pub const FIXED_DIST_SYMBOLS: usize = 32;
/// The end-of-block symbol.
pub const END_OF_BLOCK: u16 = 256;
/// Longest permitted Huffman code, in bits.
pub const MAX_CODE_LEN: usize = 15;

/// Base length for literal/length symbols 257..=285.
pub const LENGTH_BASE: [u16; 29] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
    131, 163, 195, 227, 258,
];
/// Extra bits for literal/length symbols 257..=285.
pub const LENGTH_EXTRA: [u8; 29] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
/// Base distance for distance symbols 0..=29.
pub const DIST_BASE: [u16; 30] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
];
/// Extra bits for distance symbols 0..=29.
pub const DIST_EXTRA: [u8; 30] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
];
/// Order in which code-length-code lengths are stored in a dynamic header.
pub const CODE_LENGTH_ORDER: [usize; 19] =
    [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

/// Code lengths of the fixed literal/length code.
pub fn fixed_litlen_lengths() -> [u8; FIXED_LITLEN_SYMBOLS] {
    let mut l = [8u8; FIXED_LITLEN_SYMBOLS];
    l[144..256].fill(9);
    l[256..280].fill(7);
    l
}

/// Code lengths of the fixed distance code.
pub fn fixed_dist_lengths() -> [u8; FIXED_DIST_SYMBOLS] {
    [5u8; FIXED_DIST_SYMBOLS]
}

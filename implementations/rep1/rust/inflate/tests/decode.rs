//! Integration tests for the public library API.

use inflate::{hex, inflate, Error};

fn run(h: &str) -> Result<Vec<u8>, Error> {
    inflate(&hex::decode(h.as_bytes()).unwrap())
}

/// Little helper that writes bits LSB-first, for hand-building streams.
#[derive(Default)]
struct BitWriter {
    bytes: Vec<u8>,
    nbits: usize,
}

impl BitWriter {
    fn bits(&mut self, value: u32, n: u32) -> &mut Self {
        for i in 0..n {
            if self.nbits % 8 == 0 {
                self.bytes.push(0);
            }
            *self.bytes.last_mut().unwrap() |= (((value >> i) & 1) as u8) << (self.nbits % 8);
            self.nbits += 1;
        }
        self
    }
    /// Writes a Huffman code MSB-first.
    fn code(&mut self, code: u32, n: u32) -> &mut Self {
        for i in (0..n).rev() {
            self.bits((code >> i) & 1, 1);
        }
        self
    }
}

#[test]
fn spec_examples() {
    assert_eq!(run("0300").unwrap(), b"");
    assert_eq!(run("010100feff41").unwrap(), b"A");
    assert_eq!(run("4b4c4a862000").unwrap(), b"abcabcabc");
    assert_eq!(run("030200"), Err(Error::DistanceTooFar));
}

#[test]
fn empty_stream_is_error() {
    assert_eq!(run(""), Err(Error::UnexpectedEof));
}

#[test]
fn stored_blocks() {
    // Two stored blocks, the first non-final and empty.
    assert_eq!(run("000000ffff010100feff41").unwrap(), b"A");
    // Non-zero discarded padding bits are fine.
    assert_eq!(run("f90100feff41").unwrap(), b"A");
    assert_eq!(run("010100fe0041"), Err(Error::StoredLengthMismatch));
    assert_eq!(run("010200fdff41"), Err(Error::UnexpectedEof));
}

#[test]
fn invalid_block_type() {
    assert_eq!(run("07"), Err(Error::InvalidBlockType));
}

#[test]
fn truncated_and_trailing() {
    // Fixed block missing its last byte, and a valid one with a spare byte.
    assert_eq!(run("4b4c4a8620"), Err(Error::UnexpectedEof));
    assert_eq!(run("030000"), Err(Error::TrailingData));
    assert_eq!(run("0000"), Err(Error::UnexpectedEof));
}

#[test]
fn zlib_fixed_stream() {
    let out = run("cb48cdc9c957c8c020cbf38b725274b0488c4a8f4a93290d00").unwrap();
    assert_eq!(out, b"hello hello hello hello world, ".repeat(20));
}

#[test]
fn zlib_dynamic_stream() {
    let compressed = hex::decode(include_bytes!("data/dynamic_text.hex")).unwrap();
    let expected = include_bytes!("data/dynamic_text.txt");
    assert_eq!(inflate(&compressed).unwrap(), expected);
}

#[test]
fn symbols_286_and_distance_30_are_errors() {
    // Fixed block: 286 is the 8-bit code 11000110 (0xc0 + 6).
    let mut w = BitWriter::default();
    w.bits(1, 1).bits(1, 2).code(0xc0 + 6, 8);
    assert_eq!(inflate(&w.bytes), Err(Error::InvalidSymbol));

    // 'a', then length 3 (257 = 0000001), then distance symbol 30 (11110).
    let mut w = BitWriter::default();
    w.bits(1, 1).bits(1, 2).code(0x30 + 0x61, 8).code(1, 7).code(30, 5);
    assert_eq!(inflate(&w.bytes), Err(Error::InvalidSymbol));
}

#[test]
fn overlapping_copy_replicates_byte() {
    // 'a', then length 258 (symbol 285 = 11000101) at distance 1 (00000), EOB.
    let mut w = BitWriter::default();
    w.bits(1, 1).bits(1, 2).code(0x30 + 0x61, 8).code(0xc5, 8).code(0, 5).code(0, 7);
    assert_eq!(inflate(&w.bytes).unwrap(), vec![b'a'; 259]);
}

/// Writes a dynamic block header whose code-length code has symbol 0 -> `0`,
/// symbol 1 -> `10` and symbol 2 -> `11`, so lengths 0, 1 and 2 are expressible.
fn dynamic_header(w: &mut BitWriter, hlit: u32, hdist: u32) {
    w.bits(1, 1).bits(2, 2).bits(hlit, 5).bits(hdist, 5).bits(14, 4);
    // Order: 16 17 18 0 8 7 9 6 10 5 11 4 12 3 13 2 14 1 15 (18 entries).
    // Give code-length symbol 0 -> 1 bit, symbol 1 -> 2 bits, symbol 2 -> 2 bits.
    let lens = [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2];
    for l in lens {
        w.bits(l, 3);
    }
}

#[test]
fn dynamic_block_single_code_and_empty_distance() {
    // Literal/length: only symbol 256 with length 1; distances: one zero.
    // HLIT = 0 -> 257 lengths: 256 zeros then a 1; HDIST = 0 -> one length 0.
    let mut w = BitWriter::default();
    dynamic_header(&mut w, 0, 0);
    // cl codes: sym0 = "0", sym1 = "10", sym2 = "11".
    for _ in 0..256 {
        w.code(0, 1);
    }
    w.code(0b10, 2); // length 1 for symbol 256
    w.code(0, 1); // distance length 0
    w.code(0, 1); // end-of-block (single code, bit 0)
    assert_eq!(inflate(&w.bytes).unwrap(), b"");

    // A stream whose single code is read as bit 1 is invalid.
    let mut bad = BitWriter::default();
    bad.bytes = w.bytes.clone();
    bad.nbits = w.nbits - 1;
    *bad.bytes.last_mut().unwrap() |= 1 << (bad.nbits % 8);
    assert_eq!(inflate(&bad.bytes), Err(Error::InvalidCode));
}

#[test]
fn dynamic_block_rejections() {
    // Missing end-of-block code: 257 literal lengths all zero except symbol 0.
    let mut w = BitWriter::default();
    dynamic_header(&mut w, 0, 0);
    w.code(0b10, 2);
    for _ in 0..256 {
        w.code(0, 1);
    }
    w.code(0, 1);
    assert_eq!(inflate(&w.bytes), Err(Error::MissingEndOfBlock));

    // HLIT > 29.
    let mut w = BitWriter::default();
    w.bits(1, 1).bits(2, 2).bits(30, 5).bits(0, 5).bits(0, 4);
    assert_eq!(inflate(&w.bytes), Err(Error::TooManyCodes));

    // Incomplete code-length code (single symbol of length 1).
    let mut w = BitWriter::default();
    w.bits(1, 1).bits(2, 2).bits(0, 5).bits(0, 5).bits(0, 4);
    w.bits(0, 3).bits(0, 3).bits(0, 3).bits(1, 3);
    assert_eq!(inflate(&w.bytes), Err(Error::IncompleteCode));

    // Repeat (16) with no previous length: cl symbols 0 -> code 0, 16 -> code 1.
    let mut w = BitWriter::default();
    w.bits(1, 1).bits(2, 2).bits(0, 5).bits(0, 5).bits(0, 4);
    w.bits(1, 3).bits(0, 3).bits(0, 3).bits(1, 3);
    w.code(1, 1).bits(0, 2);
    assert_eq!(inflate(&w.bytes), Err(Error::RepeatWithoutPrevious));
}

#[test]
fn output_larger_than_window_back_references() {
    // Stored 40000 bytes then a fixed block copying length 258 at distance
    // 32768 (symbol 285, distance symbol 29 with extra 8191).
    let data: Vec<u8> = (0..40000u32).map(|i| (i * 7 % 251) as u8).collect();
    // Non-final stored block: header byte 0, LEN = 40000 = 0x9c40, NLEN = 0x63bf.
    let mut s = vec![0x00, 0x40, 0x9c, 0xbf, 0x63];
    s.extend_from_slice(&data);
    let mut w = BitWriter::default();
    w.bits(1, 1).bits(1, 2).code(0xc5, 8).code(29, 5).bits(8191, 13).code(0, 7);
    s.extend_from_slice(&w.bytes);
    let out = inflate(&s).unwrap();
    assert_eq!(out.len(), 40258);
    assert_eq!(&out[40000..], &data[40000 - 32768..40000 - 32768 + 258]);
}

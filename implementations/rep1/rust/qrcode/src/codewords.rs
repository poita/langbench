//! Building the data codeword sequence and the final interleaved
//! data + ECC sequence.

use crate::bitbuffer::BitBuffer;
use crate::reed_solomon::{generator, remainder};
use crate::segment::{write_segment, Mode};
use crate::version::Version;
use crate::Ecl;

/// Builds the padded data codewords for `data` encoded in `mode` at
/// `version`/`ecl`: segment, terminator, byte alignment and `0xEC`/`0x11`
/// padding up to exactly the data capacity.
pub fn data_codewords(data: &[u8], mode: Mode, version: Version, ecl: Ecl) -> Vec<u8> {
    let capacity = version.data_codewords(ecl);
    let capacity_bits = capacity * 8;
    let mut bits = BitBuffer::new();
    write_segment(&mut bits, mode, data, version);
    debug_assert!(bits.len() <= capacity_bits);

    let terminator = 4.min(capacity_bits - bits.len());
    bits.push_bits(0, terminator);
    let align = (8 - bits.len() % 8) % 8;
    bits.push_bits(0, align);

    let mut bytes = bits.to_bytes();
    let mut pad = [0xECu8, 0x11].into_iter().cycle();
    while bytes.len() < capacity {
        bytes.push(pad.next().expect("cycle is infinite"));
    }
    bytes
}

/// Splits `data` into blocks, appends Reed-Solomon ECC to each and
/// interleaves everything into the final codeword sequence.
pub fn add_ecc_and_interleave(data: &[u8], version: Version, ecl: Ecl) -> Vec<u8> {
    debug_assert_eq!(data.len(), version.data_codewords(ecl));
    let num_blocks = version.num_blocks(ecl);
    let ecc_len = version.ecc_per_block(ecl);
    let total = version.total_codewords();
    let num_short = num_blocks - total % num_blocks;
    let short_len = total / num_blocks - ecc_len;
    let divisor = generator(ecc_len);

    let mut data_blocks: Vec<&[u8]> = Vec::with_capacity(num_blocks);
    let mut ecc_blocks: Vec<Vec<u8>> = Vec::with_capacity(num_blocks);
    let mut k = 0;
    for i in 0..num_blocks {
        let len = short_len + usize::from(i >= num_short);
        let block = &data[k..k + len];
        k += len;
        ecc_blocks.push(remainder(block, &divisor));
        data_blocks.push(block);
    }

    let mut out = Vec::with_capacity(total);
    for i in 0..=short_len {
        for b in &data_blocks {
            if let Some(&c) = b.get(i) {
                out.push(c);
            }
        }
    }
    for i in 0..ecc_len {
        for b in &ecc_blocks {
            out.push(b[i]);
        }
    }
    debug_assert_eq!(out.len(), total);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hello_world_data_codewords() {
        let v = Version::MIN;
        let cw = data_codewords(b"HELLO WORLD", Mode::Alphanumeric, v, Ecl::Medium);
        assert_eq!(
            cw,
            vec![32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17]
        );
        let full = add_ecc_and_interleave(&cw, v, Ecl::Medium);
        assert_eq!(full.len(), 26);
        assert_eq!(&full[16..], &[196, 35, 39, 119, 235, 215, 231, 226, 93, 23]);
    }

    #[test]
    fn interleaving_with_unequal_blocks() {
        // Version 5-Q: 4 blocks (2 short with 15 data, 2 long with 16).
        let v = Version::new(5).unwrap();
        let data: Vec<u8> = (0..v.data_codewords(Ecl::Quartile) as u32)
            .map(|i| i as u8)
            .collect();
        let out = add_ecc_and_interleave(&data, v, Ecl::Quartile);
        assert_eq!(out.len(), v.total_codewords());
        // Position 0..4 are the first codewords of the four blocks.
        assert_eq!(&out[..4], &[0, 15, 30, 46]);
        // The last data position (index 60..62) only comes from long blocks.
        assert_eq!(&out[60..62], &[45, 61]);
    }
}

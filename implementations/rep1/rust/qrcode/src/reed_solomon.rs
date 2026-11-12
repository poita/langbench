//! Reed-Solomon error correction over GF(2^8) (polynomial 0x11D).

/// Multiplies two field elements (carry-less multiply reduced mod 0x11D).
pub fn gf_mul(a: u8, b: u8) -> u8 {
    let mut z: u32 = 0;
    for i in (0..8).rev() {
        z = (z << 1) ^ ((z >> 7) * 0x11D);
        z ^= ((b as u32 >> i) & 1) * a as u32;
    }
    z as u8
}

/// Returns the generator polynomial of degree `degree` as `degree`
/// coefficients, highest power first, omitting the leading 1.
pub fn generator(degree: usize) -> Vec<u8> {
    assert!((1..=255).contains(&degree));
    let mut result = vec![0u8; degree];
    result[degree - 1] = 1;
    let mut root = 1u8;
    for _ in 0..degree {
        for j in 0..degree {
            result[j] = gf_mul(result[j], root);
            if j + 1 < degree {
                result[j] ^= result[j + 1];
            }
        }
        root = gf_mul(root, 2);
    }
    result
}

/// Computes the remainder of `data(x) * x^E` divided by the generator of
/// degree `E = divisor.len()`; `divisor` comes from [`generator`].
pub fn remainder(data: &[u8], divisor: &[u8]) -> Vec<u8> {
    let mut result = vec![0u8; divisor.len()];
    for &b in data {
        let factor = b ^ result[0];
        result.rotate_left(1);
        *result.last_mut().expect("non-empty divisor") = 0;
        if factor != 0 {
            for (r, &d) in result.iter_mut().zip(divisor) {
                *r ^= gf_mul(d, factor);
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multiplication() {
        assert_eq!(gf_mul(2, 0x80), 0x1D);
        assert_eq!(gf_mul(0, 77), 0);
        assert_eq!(gf_mul(1, 77), 77);
        assert_eq!(gf_mul(0x53, 0xCA), gf_mul(0xCA, 0x53));
    }

    #[test]
    fn generator_degree_7() {
        // x^7 + a^87 x^6 + a^229 x^5 + ... in integer form.
        assert_eq!(generator(7), vec![127, 122, 154, 164, 11, 68, 117]);
    }

    #[test]
    fn hello_world_ecc() {
        let data = [
            32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17,
        ];
        assert_eq!(
            remainder(&data, &generator(10)),
            vec![196, 35, 39, 119, 235, 215, 231, 226, 93, 23]
        );
    }
}

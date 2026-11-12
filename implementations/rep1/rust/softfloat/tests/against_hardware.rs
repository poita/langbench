//! Randomised comparison against the host's IEEE-754 `f32` arithmetic.
//!
//! The host FPU is used here purely as a test oracle; the library itself never
//! touches floating point.

use softfloat::{add, div, mul, sqrt, sub, QNAN};

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        // xorshift64*
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }

    /// A bit pattern biased towards interesting values: special exponents,
    /// denormals, and exponents close together.
    fn operand(&mut self) -> u32 {
        let r = self.next();
        let bits = (r >> 32) as u32;
        match r % 8 {
            0 => bits & 0x807f_ffff,                            // zero/denormal
            1 => (bits & 0x807f_ffff) | 0x7f80_0000,            // inf/nan
            2 => (bits & 0x8000_0000) | 0x0080_0000 | (bits & 0xff), // near min normal
            3 => (bits & 0x807f_ffff) | 0x7f00_0000,            // near overflow
            4 => (bits & 0x8000_0000) | (0x3f80_0000 + (bits & 0x00ff_ffff)),
            _ => bits,
        }
    }
}

fn canon(bits: u32) -> u32 {
    if f32::from_bits(bits).is_nan() {
        QNAN
    } else {
        bits
    }
}

fn check2(name: &str, soft: fn(u32, u32) -> u32, hard: fn(f32, f32) -> f32, a: u32, b: u32) {
    let want = canon(hard(f32::from_bits(a), f32::from_bits(b)).to_bits());
    let got = soft(a, b);
    assert_eq!(got, want, "{name} {a:08x} {b:08x}: got {got:08x}, want {want:08x}");
}

#[test]
fn binary_ops_random() {
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
    for _ in 0..1_000_000 {
        let (a, b) = (rng.operand(), rng.operand());
        check2("add", add, |x, y| x + y, a, b);
        check2("sub", sub, |x, y| x - y, a, b);
        check2("mul", mul, |x, y| x * y, a, b);
        check2("div", div, |x, y| x / y, a, b);
    }
}

#[test]
fn sqrt_random() {
    let mut rng = Rng(0x1234_5678_9abc_def1);
    for _ in 0..1_000_000 {
        let a = rng.operand();
        let want = canon(f32::from_bits(a).sqrt().to_bits());
        assert_eq!(sqrt(a), want, "sqrt {a:08x}");
    }
}

#[test]
fn sqrt_all_small_denormals_and_exponent_sweep() {
    for frac in 0..0x2_0000u32 {
        for exp in [0u32, 1, 2, 126, 127, 128, 254] {
            let a = (exp << 23) | frac;
            assert_eq!(sqrt(a), f32::from_bits(a).sqrt().to_bits(), "sqrt {a:08x}");
        }
    }
}

#[test]
fn denormal_division_and_multiplication_sweep() {
    for a in (1u32..0x400).chain([0x007f_ffff, 0x0080_0000]) {
        for b in [0x3f00_0000u32, 0x3f80_0001, 0x4000_0000, 0x4040_0000, 0x7f7f_ffff, 0x0000_0001, 0x0000_0003, 0x0040_0000] {
            check2("div", div, |x, y| x / y, a, b);
            check2("div", div, |x, y| x / y, b, a);
            check2("mul", mul, |x, y| x * y, a, b);
            check2("add", add, |x, y| x + y, a, b);
            check2("sub", sub, |x, y| x - y, b, a);
        }
    }
}

#[test]
fn spec_examples() {
    let cases: &[(fn(u32, u32) -> u32, u32, u32, u32)] = &[
        (add, 0x3f80_0000, 0x3f80_0000, 0x4000_0000),
        (sub, 0x3f80_0000, 0x3f80_0000, 0x0000_0000),
        (mul, 0x4040_0000, 0xc040_0000, 0xc110_0000),
        (div, 0x3f80_0000, 0x4040_0000, 0x3eaa_aaab),
        (add, 0x7f80_0000, 0xff80_0000, QNAN),
        (mul, 0x7f80_0000, 0, QNAN),
        (div, 0, 0, QNAN),
        (mul, 0, 0xbf80_0000, 0x8000_0000),
        (add, 0x8000_0000, 0x8000_0000, 0x8000_0000),
        (add, 0x8000_0000, 0, 0),
        (div, 0xbf80_0000, 0, 0xff80_0000),
        (add, 0x7fc1_2345, 0x3f80_0000, QNAN),
        (add, 0x7f7f_ffff, 0x7300_0000, 0x7f80_0000),
        (add, 0x7f7f_ffff, 0x72ff_ffff, 0x7f7f_ffff),
        (div, 1, 0x4000_0000, 0),
        (div, 3, 0x4000_0000, 2),
        (add, 0x3f80_0000, 0x3380_0000, 0x3f80_0000),
        (add, 0x3f80_0001, 0x3380_0000, 0x3f80_0002),
        (mul, 1, 0x3f00_0000, 0),
    ];
    for &(f, a, b, want) in cases {
        assert_eq!(f(a, b), want, "{a:08x} {b:08x}");
    }
}

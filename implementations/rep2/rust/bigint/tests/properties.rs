//! Randomised property tests (deterministic xorshift generator, no
//! external dependencies) cross-checked against `i128` and algebraic
//! identities for large values.

use bigint::BigInt;

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    /// A random integer with up to `max_digits` digits, biased toward
    /// limb-boundary values (runs of 0s and 9s) that stress carries and
    /// quotient estimation.
    fn big(&mut self, max_digits: usize) -> BigInt {
        let len = 1 + self.next() as usize % max_digits;
        let mut s = String::new();
        if self.next() % 2 == 0 {
            s.push('-');
        }
        let mode = self.next() % 4;
        for i in 0..len {
            let d = match mode {
                0 => (self.next() % 10) as u8,
                1 => 9,
                2 => if self.next() % 8 == 0 { (self.next() % 10) as u8 } else { 9 },
                _ => if self.next() % 8 == 0 { (self.next() % 10) as u8 } else if i == 0 { 1 } else { 0 },
            };
            s.push((b'0' + d) as char);
        }
        s.parse().unwrap()
    }
}

fn from_i128(v: i128) -> BigInt {
    v.to_string().parse().unwrap()
}

#[test]
fn matches_i128_on_small_values() {
    let mut rng = Rng(0x9E3779B97F4A7C15);
    for _ in 0..20_000 {
        let a = (rng.next() as i64 >> (rng.next() % 40)) as i128;
        let b = (rng.next() as i64 >> (rng.next() % 40)) as i128;
        let (ba, bb) = (from_i128(a), from_i128(b));
        assert_eq!((&ba + &bb).to_string(), (a + b).to_string());
        assert_eq!((&ba - &bb).to_string(), (a - b).to_string());
        assert_eq!((&ba * &bb).to_string(), (a * b).to_string());
        assert_eq!(ba.cmp(&bb), a.cmp(&b));
        if b != 0 {
            let (q, r) = ba.div_rem(&bb).unwrap();
            assert_eq!(q.to_string(), (a / b).to_string(), "{a} / {b}");
            assert_eq!(r.to_string(), (a % b).to_string(), "{a} % {b}");
        }
    }
}

#[test]
fn division_identity_on_large_values() {
    let mut rng = Rng(0xDEADBEEFCAFEF00D);
    for _ in 0..3_000 {
        let a = rng.big(200);
        let b = rng.big(120);
        if b.is_zero() {
            continue;
        }
        let (q, r) = a.div_rem(&b).unwrap();
        assert_eq!(&(&q * &b) + &r, a, "{a} / {b}");
        assert!(r.abs() < b.abs(), "{a} % {b}");
        assert!(r.is_zero() || r.is_negative() == a.is_negative());
    }
}

#[test]
fn ring_laws() {
    let mut rng = Rng(42);
    for _ in 0..500 {
        let (a, b, c) = (rng.big(150), rng.big(150), rng.big(150));
        assert_eq!(&a + &b, &b + &a);
        assert_eq!(&a * &b, &b * &a);
        assert_eq!(&(&a + &b) - &b, a);
        assert_eq!(&a * &(&b + &c), &(&a * &b) + &(&a * &c));
    }
}

#[test]
fn pow_matches_repeated_multiplication() {
    let mut rng = Rng(7);
    for _ in 0..100 {
        let a = rng.big(30);
        let e = rng.next() % 12;
        let mut expect = BigInt::one();
        for _ in 0..e {
            expect = &expect * &a;
        }
        assert_eq!(a.pow(e), expect);
    }
}

#[test]
fn print_parse_roundtrip() {
    let mut rng = Rng(99);
    for _ in 0..500 {
        let a = rng.big(300);
        assert_eq!(a.to_string().parse::<BigInt>().unwrap(), a);
    }
}

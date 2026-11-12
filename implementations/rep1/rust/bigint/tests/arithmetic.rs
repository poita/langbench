//! Property-style tests of the library against machine integers and algebraic
//! identities, using a small deterministic PRNG (no external crates).

use bigint::BigInt;

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        // xorshift64*
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    /// A random signed decimal string with up to `max_digits` digits, biased
    /// toward runs of 0s and 9s to hit carry and division edge cases.
    fn number(&mut self, max_digits: usize) -> String {
        let len = 1 + (self.next() as usize) % max_digits;
        let mut s = String::new();
        if self.next() % 2 == 0 {
            s.push('-');
        }
        for _ in 0..len {
            let d = match self.next() % 4 {
                0 => b'0',
                1 => b'9',
                _ => b'0' + (self.next() % 10) as u8,
            };
            s.push(d as char);
        }
        s
    }
}

fn big(s: &str) -> BigInt {
    s.parse().unwrap()
}

#[test]
fn matches_i128_for_small_values() {
    let mut rng = Rng(0x1234_5678_9abc_def1);
    for _ in 0..2000 {
        let a = (rng.next() as i64 >> 2) as i128;
        let b = (rng.next() as i64 >> 2) as i128;
        let (ba, bb) = (BigInt::from(a as i64), BigInt::from(b as i64));
        assert_eq!((&ba + &bb).to_string(), (a + b).to_string());
        assert_eq!((&ba - &bb).to_string(), (a - b).to_string());
        assert_eq!((&ba * &bb).to_string(), (a * b).to_string());
        if b != 0 {
            let (q, r) = ba.div_rem(&bb).unwrap();
            assert_eq!(q.to_string(), (a / b).to_string());
            assert_eq!(r.to_string(), (a % b).to_string());
        }
    }
}

#[test]
fn division_identity_on_large_values() {
    let mut rng = Rng(42);
    for _ in 0..1500 {
        let a = big(&rng.number(120));
        let b = big(&rng.number(60));
        if b.is_zero() {
            continue;
        }
        let (q, r) = a.div_rem(&b).unwrap();
        assert_eq!(&(&q * &b) + &r, a, "{a} / {b}");
        assert!(r.magnitude() < b.magnitude(), "{a} / {b}");
        assert!(r.is_zero() || r.is_negative() == a.is_negative(), "{a} / {b}");
    }
}

#[test]
fn add_sub_roundtrip_and_ordering() {
    let mut rng = Rng(7);
    for _ in 0..1000 {
        let (a, b) = (big(&rng.number(80)), big(&rng.number(80)));
        assert_eq!(&(&a + &b) - &b, a);
        assert_eq!(&(&a - &b) + &b, a);
        assert_eq!(a.cmp(&b), (&a - &b).cmp(&BigInt::zero()));
    }
}

#[test]
fn multiplication_distributes() {
    let mut rng = Rng(99);
    for _ in 0..300 {
        let (a, b, c) = (big(&rng.number(70)), big(&rng.number(70)), big(&rng.number(70)));
        assert_eq!(&a * &(&b + &c), &(&a * &b) + &(&a * &c));
    }
}

#[test]
fn power_matches_repeated_multiplication() {
    let mut rng = Rng(5);
    for _ in 0..100 {
        let a = big(&rng.number(30));
        let e = rng.next() % 12;
        let mut expect = BigInt::one();
        for _ in 0..e {
            expect = &expect * &a;
        }
        assert_eq!(a.pow(&BigInt::from(e as i64)).unwrap(), expect);
    }
}

#[test]
fn power_of_ten_prints_exactly() {
    let p = big("10").pow(&big("5000")).unwrap().to_string();
    assert_eq!(p.len(), 5001);
    assert!(p.starts_with('1') && p[1..].bytes().all(|c| c == b'0'));
}

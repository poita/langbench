//! Arbitrary-precision signed integers.
//!
//! A [`BigInt`] is stored as a sign and a little-endian vector of 32-bit
//! limbs. The algorithms are the classical ones: schoolbook addition,
//! subtraction and multiplication, Knuth's Algorithm D for division, and
//! decimal conversion by repeated division by 10^9.

use std::cmp::Ordering;
use std::fmt;
use std::ops::{Add, Mul, Neg, Sub};

const BASE_BITS: u32 = 32;
/// Largest power of ten that fits in a limb; used for decimal conversion.
const CHUNK: u32 = 1_000_000_000;
const CHUNK_DIGITS: usize = 9;

/// An arbitrary-precision signed integer.
///
/// The representation is canonical (no leading zero limbs, zero is never
/// negative), so the derived equality is numeric equality.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct BigInt {
    neg: bool,
    mag: Vec<u32>,
}

// ---------------------------------------------------------------------------
// Magnitude (unsigned) helpers
// ---------------------------------------------------------------------------

fn trim(v: &mut Vec<u32>) {
    while v.last() == Some(&0) {
        v.pop();
    }
}

fn cmp_mag(a: &[u32], b: &[u32]) -> Ordering {
    if a.len() != b.len() {
        return a.len().cmp(&b.len());
    }
    for i in (0..a.len()).rev() {
        if a[i] != b[i] {
            return a[i].cmp(&b[i]);
        }
    }
    Ordering::Equal
}

fn add_mag(a: &[u32], b: &[u32]) -> Vec<u32> {
    let (long, short) = if a.len() >= b.len() { (a, b) } else { (b, a) };
    let mut out = Vec::with_capacity(long.len() + 1);
    let mut carry = 0u64;
    for i in 0..long.len() {
        let s = long[i] as u64 + short.get(i).copied().unwrap_or(0) as u64 + carry;
        out.push(s as u32);
        carry = s >> BASE_BITS;
    }
    if carry > 0 {
        out.push(carry as u32);
    }
    out
}

/// `a - b` where `a >= b` in magnitude.
fn sub_mag(a: &[u32], b: &[u32]) -> Vec<u32> {
    let mut out = Vec::with_capacity(a.len());
    let mut borrow = 0i64;
    for i in 0..a.len() {
        let mut d = a[i] as i64 - borrow - b.get(i).copied().unwrap_or(0) as i64;
        if d < 0 {
            d += 1 << BASE_BITS;
            borrow = 1;
        } else {
            borrow = 0;
        }
        out.push(d as u32);
    }
    trim(&mut out);
    out
}

fn mul_mag(a: &[u32], b: &[u32]) -> Vec<u32> {
    if a.is_empty() || b.is_empty() {
        return Vec::new();
    }
    let mut out = vec![0u32; a.len() + b.len()];
    for (i, &x) in a.iter().enumerate() {
        if x == 0 {
            continue;
        }
        let mut carry = 0u64;
        for (j, &y) in b.iter().enumerate() {
            let t = x as u64 * y as u64 + out[i + j] as u64 + carry;
            out[i + j] = t as u32;
            carry = t >> BASE_BITS;
        }
        out[i + b.len()] = carry as u32;
    }
    trim(&mut out);
    out
}

/// Divides `a` in place by a single limb, returning the remainder.
fn divrem_small_in_place(a: &mut Vec<u32>, d: u32) -> u32 {
    let mut rem = 0u64;
    for limb in a.iter_mut().rev() {
        let cur = (rem << BASE_BITS) | *limb as u64;
        *limb = (cur / d as u64) as u32;
        rem = cur % d as u64;
    }
    trim(a);
    rem as u32
}

fn shl_bits(a: &[u32], s: u32, extra_limb: bool) -> Vec<u32> {
    let mut out = Vec::with_capacity(a.len() + 1);
    if s == 0 {
        out.extend_from_slice(a);
        if extra_limb {
            out.push(0);
        }
        return out;
    }
    let mut carry = 0u32;
    for &x in a {
        out.push((x << s) | carry);
        carry = x >> (BASE_BITS - s);
    }
    if extra_limb {
        out.push(carry);
    }
    out
}

fn shr_bits(a: &[u32], s: u32) -> Vec<u32> {
    let mut out = a.to_vec();
    if s != 0 {
        for i in 0..out.len() {
            let hi = out.get(i + 1).copied().unwrap_or(0);
            out[i] = (out[i] >> s) | (hi << (BASE_BITS - s));
        }
    }
    trim(&mut out);
    out
}

/// Knuth's Algorithm D: returns `(a / b, a % b)` for magnitudes, `b != 0`.
fn divrem_mag(a: &[u32], b: &[u32]) -> (Vec<u32>, Vec<u32>) {
    debug_assert!(!b.is_empty());
    if cmp_mag(a, b) == Ordering::Less {
        return (Vec::new(), a.to_vec());
    }
    if b.len() == 1 {
        let mut q = a.to_vec();
        let r = divrem_small_in_place(&mut q, b[0]);
        return (q, if r == 0 { Vec::new() } else { vec![r] });
    }
    let base: u64 = 1 << BASE_BITS;
    let n = b.len();
    let m = a.len() - n;
    // D1: normalise so the divisor's top limb has its high bit set.
    let s = b[n - 1].leading_zeros();
    let v = shl_bits(b, s, false);
    let mut u = shl_bits(a, s, true);
    let mut q = vec![0u32; m + 1];
    let vtop = v[n - 1] as u64;
    let vsecond = v[n - 2] as u64;
    for j in (0..=m).rev() {
        // D3: estimate the quotient digit.
        let num = ((u[j + n] as u64) << BASE_BITS) | u[j + n - 1] as u64;
        let mut qhat = num / vtop;
        let mut rhat = num % vtop;
        while qhat >= base || qhat * vsecond > ((rhat << BASE_BITS) | u[j + n - 2] as u64) {
            qhat -= 1;
            rhat += vtop;
            if rhat >= base {
                break;
            }
        }
        // D4: multiply and subtract.
        let mut borrow = 0i64;
        let mut carry = 0u64;
        for i in 0..n {
            let p = qhat * v[i] as u64 + carry;
            carry = p >> BASE_BITS;
            let t = u[i + j] as i64 - borrow - (p & 0xFFFF_FFFF) as i64;
            u[i + j] = t as u32;
            borrow = i64::from(t < 0);
        }
        let t = u[j + n] as i64 - borrow - carry as i64;
        u[j + n] = t as u32;
        // D5/D6: if the subtraction went negative, add the divisor back.
        if t < 0 {
            qhat -= 1;
            let mut c = 0u64;
            for i in 0..n {
                let sum = u[i + j] as u64 + v[i] as u64 + c;
                u[i + j] = sum as u32;
                c = sum >> BASE_BITS;
            }
            u[j + n] = u[j + n].wrapping_add(c as u32);
        }
        q[j] = qhat as u32;
    }
    trim(&mut q);
    // D8: denormalise the remainder.
    let r = shr_bits(&u[..n], s);
    (q, r)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

impl BigInt {
    /// The integer zero.
    pub fn zero() -> BigInt {
        BigInt::default()
    }

    fn from_parts(neg: bool, mut mag: Vec<u32>) -> BigInt {
        trim(&mut mag);
        let neg = neg && !mag.is_empty();
        BigInt { neg, mag }
    }

    /// Whether this integer is zero.
    pub fn is_zero(&self) -> bool {
        self.mag.is_empty()
    }

    /// Whether this integer is strictly negative.
    pub fn is_negative(&self) -> bool {
        self.neg
    }

    /// Converts the integer to an `i64` if it fits.
    pub fn to_i64(&self) -> Option<i64> {
        if self.mag.len() > 2 {
            return None;
        }
        let mut v = 0u64;
        for (i, &limb) in self.mag.iter().enumerate() {
            v |= (limb as u64) << (BASE_BITS * i as u32);
        }
        if self.neg {
            if v <= 1u64 << 63 {
                Some((v as i64).wrapping_neg())
            } else {
                None
            }
        } else {
            i64::try_from(v).ok()
        }
    }

    /// Parses an optionally signed decimal integer (`[+-]?[0-9]+`).
    pub fn parse(s: &str) -> Option<BigInt> {
        let (neg, digits) = match s.as_bytes().first()? {
            b'-' => (true, &s[1..]),
            b'+' => (false, &s[1..]),
            _ => (false, s),
        };
        if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let bytes = digits.as_bytes();
        let mut mag: Vec<u32> = Vec::with_capacity(bytes.len() / 9 + 1);
        // Process the digits in chunks of nine, most significant first; the
        // first chunk takes the remainder so the rest are all full-width.
        let first = match bytes.len() % CHUNK_DIGITS {
            0 => CHUNK_DIGITS,
            r => r,
        };
        let mut pos = 0;
        let mut take = first;
        while pos < bytes.len() {
            let mut chunk = 0u32;
            for &b in &bytes[pos..pos + take] {
                chunk = chunk * 10 + (b - b'0') as u32;
            }
            let scale = 10u64.pow(take as u32);
            let mut carry = chunk as u64;
            for limb in mag.iter_mut() {
                let t = *limb as u64 * scale + carry;
                *limb = t as u32;
                carry = t >> BASE_BITS;
            }
            if carry > 0 {
                mag.push(carry as u32);
            }
            pos += take;
            take = CHUNK_DIGITS;
        }
        Some(BigInt::from_parts(neg, mag))
    }

    /// Truncating division: returns `(quotient, remainder)` such that
    /// `self == quotient * other + remainder`, with the remainder taking the
    /// sign of `self`. Returns `None` if `other` is zero.
    pub fn div_rem(&self, other: &BigInt) -> Option<(BigInt, BigInt)> {
        if other.is_zero() {
            return None;
        }
        let (q, r) = divrem_mag(&self.mag, &other.mag);
        Some((
            BigInt::from_parts(self.neg != other.neg, q),
            BigInt::from_parts(self.neg, r),
        ))
    }

    fn add_signed(&self, other: &BigInt, other_neg: bool) -> BigInt {
        if self.neg == other_neg {
            return BigInt::from_parts(self.neg, add_mag(&self.mag, &other.mag));
        }
        match cmp_mag(&self.mag, &other.mag) {
            Ordering::Equal => BigInt::zero(),
            Ordering::Greater => BigInt::from_parts(self.neg, sub_mag(&self.mag, &other.mag)),
            Ordering::Less => BigInt::from_parts(other_neg, sub_mag(&other.mag, &self.mag)),
        }
    }
}

impl From<i64> for BigInt {
    fn from(v: i64) -> BigInt {
        let m = v.unsigned_abs();
        BigInt::from_parts(v < 0, vec![m as u32, (m >> BASE_BITS) as u32])
    }
}

impl Add for &BigInt {
    type Output = BigInt;
    fn add(self, rhs: &BigInt) -> BigInt {
        self.add_signed(rhs, rhs.neg)
    }
}

impl Sub for &BigInt {
    type Output = BigInt;
    fn sub(self, rhs: &BigInt) -> BigInt {
        self.add_signed(rhs, !rhs.neg && !rhs.is_zero())
    }
}

impl Mul for &BigInt {
    type Output = BigInt;
    fn mul(self, rhs: &BigInt) -> BigInt {
        BigInt::from_parts(self.neg != rhs.neg, mul_mag(&self.mag, &rhs.mag))
    }
}

impl Neg for &BigInt {
    type Output = BigInt;
    fn neg(self) -> BigInt {
        BigInt::from_parts(!self.neg, self.mag.clone())
    }
}

impl PartialOrd for BigInt {
    fn partial_cmp(&self, other: &BigInt) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for BigInt {
    fn cmp(&self, other: &BigInt) -> Ordering {
        match (self.neg, other.neg) {
            (false, true) => Ordering::Greater,
            (true, false) => Ordering::Less,
            (false, false) => cmp_mag(&self.mag, &other.mag),
            (true, true) => cmp_mag(&other.mag, &self.mag),
        }
    }
}

impl fmt::Display for BigInt {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.mag.is_empty() {
            return f.write_str("0");
        }
        let mut work = self.mag.clone();
        let mut chunks = Vec::with_capacity(work.len() * 32 / 29 + 1);
        while !work.is_empty() {
            chunks.push(divrem_small_in_place(&mut work, CHUNK));
        }
        let mut s = String::with_capacity(chunks.len() * CHUNK_DIGITS + 1);
        if self.neg {
            s.push('-');
        }
        let mut iter = chunks.iter().rev();
        if let Some(first) = iter.next() {
            s.push_str(&first.to_string());
        }
        for c in iter {
            s.push_str(&format!("{c:09}"));
        }
        f.write_str(&s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn big(s: &str) -> BigInt {
        BigInt::parse(s).unwrap()
    }

    struct Lcg(u64);
    impl Lcg {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            self.0 >> 11
        }
        fn big(&mut self, limbs: usize) -> BigInt {
            let mut mag: Vec<u32> = (0..limbs).map(|_| self.next() as u32).collect();
            // Make some limbs extreme to exercise the add-back step.
            if self.next() % 3 == 0 {
                for l in mag.iter_mut() {
                    if self.next() % 2 == 0 {
                        *l = if self.next() % 2 == 0 { 0 } else { u32::MAX };
                    }
                }
            }
            BigInt::from_parts(self.next() % 2 == 0, mag)
        }
    }

    #[test]
    fn parse_and_display_round_trip() {
        for s in ["0", "1", "-1", "123456789", "1000000000", "-99999999999999999999999"] {
            assert_eq!(big(s).to_string(), s);
        }
        assert_eq!(big("-0").to_string(), "0");
        assert_eq!(big("+5").to_string(), "5");
        assert_eq!(big("000123").to_string(), "123");
        let long = "9".repeat(500);
        assert_eq!(big(&long).to_string(), long);
        assert_eq!(BigInt::parse(""), None);
        assert_eq!(BigInt::parse("-"), None);
        assert_eq!(BigInt::parse("12a"), None);
    }

    #[test]
    fn i64_conversion() {
        for v in [0, 1, -1, i64::MAX, i64::MIN, 1 << 40, -(1 << 40)] {
            assert_eq!(BigInt::from(v).to_i64(), Some(v));
            assert_eq!(BigInt::from(v).to_string(), v.to_string());
        }
        assert_eq!(big("9223372036854775808").to_i64(), None);
        assert_eq!(big("-9223372036854775809").to_i64(), None);
    }

    #[test]
    fn add_sub_mul_small() {
        let vals = [0i64, 1, -1, 7, -7, 1 << 33, -(1 << 33), i64::MAX, i64::MIN];
        for &a in &vals {
            for &b in &vals {
                let (x, y) = (BigInt::from(a), BigInt::from(b));
                let (xa, ya) = (a as i128, b as i128);
                assert_eq!((&x + &y).to_string(), (xa + ya).to_string());
                assert_eq!((&x - &y).to_string(), (xa - ya).to_string());
                assert_eq!((&x * &y).to_string(), (xa * ya).to_string());
                assert_eq!(x.cmp(&y), a.cmp(&b));
            }
        }
    }

    #[test]
    fn division_truncates_toward_zero() {
        let cases = [(-7, 2, -3, -1), (7, -2, -3, 1), (-7, -2, 3, -1), (7, 2, 3, 1)];
        for (a, b, q, r) in cases {
            let (bq, br) = BigInt::from(a).div_rem(&BigInt::from(b)).unwrap();
            assert_eq!((bq.to_i64(), br.to_i64()), (Some(q), Some(r)));
        }
        assert!(BigInt::from(1).div_rem(&BigInt::zero()).is_none());
    }

    #[test]
    fn division_identity_on_random_values() {
        let mut rng = Lcg(42);
        for round in 0..3000 {
            let a = rng.big(1 + round % 12);
            let b = rng.big(1 + (round / 3) % 7);
            if b.is_zero() {
                continue;
            }
            let (q, r) = a.div_rem(&b).unwrap();
            assert_eq!(&(&q * &b) + &r, a, "a = q*b + r");
            assert!(cmp_mag(&r.mag, &b.mag) == Ordering::Less, "|r| < |b|");
            assert!(r.is_zero() || r.neg == a.neg, "sign of remainder");
        }
    }

    #[test]
    fn factorial_digits() {
        let mut f = BigInt::from(1);
        for i in 1..=2000 {
            f = &f * &BigInt::from(i);
        }
        let s = f.to_string();
        assert_eq!(s.len(), 5736);
        // Divide it all back down.
        for i in (1..=2000).rev() {
            let (q, r) = f.div_rem(&BigInt::from(i)).unwrap();
            assert!(r.is_zero());
            f = q;
        }
        assert_eq!(f, BigInt::from(1));
    }

    #[test]
    fn knuth_add_back_case() {
        // A classic case that needs the "add back" correction step.
        let a = big("340282366920938463463374607431768211455"); // 2^128 - 1
        let b = big("18446744073709551615"); // 2^64 - 1
        let (q, r) = a.div_rem(&b).unwrap();
        assert_eq!(&(&q * &b) + &r, a);
        let u = BigInt::from_parts(false, vec![0, 0, 0x8000_0000, 0x7FFF_FFFF]);
        let v = BigInt::from_parts(false, vec![1, 0, 0x8000_0000]);
        let (q, r) = u.div_rem(&v).unwrap();
        assert_eq!(&(&q * &v) + &r, u);
    }
}

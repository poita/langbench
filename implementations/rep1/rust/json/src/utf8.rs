//! Strict UTF-8 validation (RFC 3629) in a single forward pass.

use crate::error::{Error, ErrorKind};

/// Checks that `bytes` is well-formed UTF-8: no overlong forms, no encoded
/// surrogates, nothing above U+10FFFF, no truncated sequences.
///
/// The error offset is the start of the offending sequence.
pub fn validate(bytes: &[u8]) -> Result<(), Error> {
    let n = bytes.len();
    let mut i = 0;
    while i < n {
        let b = bytes[i];
        if b < 0x80 {
            i += 1;
            continue;
        }
        // (sequence length, allowed range of the second byte)
        let (len, lo, hi) = match b {
            0xC2..=0xDF => (2, 0x80, 0xBF),
            0xE0 => (3, 0xA0, 0xBF),
            0xE1..=0xEC | 0xEE..=0xEF => (3, 0x80, 0xBF),
            0xED => (3, 0x80, 0x9F),
            0xF0 => (4, 0x90, 0xBF),
            0xF1..=0xF3 => (4, 0x80, 0xBF),
            0xF4 => (4, 0x80, 0x8F),
            _ => return Err(Error::new(ErrorKind::InvalidUtf8, i)),
        };
        if i + len > n {
            return Err(Error::new(ErrorKind::InvalidUtf8, i));
        }
        let second = bytes[i + 1];
        if second < lo || second > hi {
            return Err(Error::new(ErrorKind::InvalidUtf8, i));
        }
        if bytes[i + 2..i + len].iter().any(|&c| c & 0xC0 != 0x80) {
            return Err(Error::new(ErrorKind::InvalidUtf8, i));
        }
        i += len;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::validate;

    #[test]
    fn accepts_valid() {
        assert!(validate(b"").is_ok());
        assert!(validate("héllo 😀 \u{10FFFF} \u{E000} \u{7FF} \u{800}".as_bytes()).is_ok());
    }

    #[test]
    fn rejects_invalid() {
        let bad: &[&[u8]] = &[
            b"\x80",
            b"\xC0\x80",         // overlong
            b"\xC1\xBF",         // overlong
            b"\xE0\x80\x80",     // overlong
            b"\xED\xA0\x80",     // surrogate
            b"\xF0\x80\x80\x80", // overlong
            b"\xF4\x90\x80\x80", // > U+10FFFF
            b"\xF5\x80\x80\x80",
            b"\xFF",
            b"\xE2\x82",         // truncated
            b"\xF0\x9F\x98",     // truncated
            b"\xE2\x28\xA1",
        ];
        for b in bad {
            assert!(validate(b).is_err(), "{:?}", b);
        }
    }
}

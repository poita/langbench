//! Standard Webhooks signing and verification.

use crate::base64;
use crate::secret::Secret;
use crate::sha256::DIGEST_LEN;
use std::fmt;

/// Maximum clock skew, in seconds, accepted in either direction (inclusive).
pub const TOLERANCE_SECS: i64 = 300;

/// Largest absolute value of a canonical integer.
const INT_LIMIT: i64 = 1_000_000_000_000_000;

/// Parses a canonical decimal integer: `0`, or an optional `-` followed by a
/// digit `1`-`9` and any more digits, with absolute value at most 10^15.
///
/// ```
/// use webhooks::is_canonical_int;
/// assert_eq!(is_canonical_int(b"-12"), Some(-12));
/// assert_eq!(is_canonical_int(b"007"), None);
/// assert_eq!(is_canonical_int(b"-0"), None);
/// ```
pub fn is_canonical_int(text: &[u8]) -> Option<i64> {
    let (neg, digits) = match text.split_first() {
        Some((b'-', rest)) => (true, rest),
        _ => (false, text),
    };
    if digits.is_empty() || digits.len() > 16 || !digits.iter().all(u8::is_ascii_digit) {
        return None;
    }
    if digits[0] == b'0' && (digits.len() > 1 || neg) {
        return None;
    }
    let mut v: i64 = 0;
    for &d in digits {
        v = v * 10 + (d - b'0') as i64;
    }
    if v > INT_LIMIT {
        return None;
    }
    Some(if neg { -v } else { v })
}

/// Computes the raw HMAC for `id.ts.body` under one secret.
pub fn sign(secret: &Secret, id: &str, ts: &str, body: &[u8]) -> [u8; DIGEST_LEN] {
    secret.hmac_key().mac_parts(&[id.as_bytes(), b".", ts.as_bytes(), b".", body])
}

/// Produces the `webhook-signature` header value: one `v1,<base64>` per
/// secret, in order, joined by single spaces.
pub fn sign_header(secrets: &[Secret], id: &str, ts: &str, body: &[u8]) -> String {
    let mut out = String::with_capacity(secrets.len() * 48);
    for (i, s) in secrets.iter().enumerate() {
        if i > 0 {
            out.push(' ');
        }
        out.push_str("v1,");
        out.push_str(&base64::encode(&sign(s, id, ts, body)));
    }
    out
}

/// Why verification failed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VerifyFailure {
    /// The header holds no non-empty token.
    MissingSignature,
    /// The timestamp is not a canonical integer.
    InvalidTimestamp,
    /// The timestamp is more than [`TOLERANCE_SECS`] in the past.
    TimestampTooOld,
    /// The timestamp is more than [`TOLERANCE_SECS`] in the future.
    TimestampTooNew,
    /// No header token matches any secret.
    NoMatch,
}

impl VerifyFailure {
    /// The kebab-case name used in the command protocol.
    pub fn as_str(self) -> &'static str {
        match self {
            VerifyFailure::MissingSignature => "missing-signature",
            VerifyFailure::InvalidTimestamp => "invalid-timestamp",
            VerifyFailure::TimestampTooOld => "timestamp-too-old",
            VerifyFailure::TimestampTooNew => "timestamp-too-new",
            VerifyFailure::NoMatch => "no-match",
        }
    }
}

impl fmt::Display for VerifyFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Result of [`verify`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VerifyOutcome {
    /// A signature matched: `secret` is the 0-based index of the secret and
    /// `token` the 0-based index of the header token (counting empty tokens).
    Ok { secret: usize, token: usize },
    /// Verification failed.
    Fail(VerifyFailure),
}

/// Verifies a received webhook.
///
/// Steps, in order: header tokens, timestamp syntax, timestamp tolerance
/// against `now`, then signature matching. One MAC is computed per secret and
/// compared against every decoded `v1` token, so the cost is
/// `O(S·(B + T))`. The first match in (secret, token) order wins.
pub fn verify(
    secrets: &[Secret],
    id: &str,
    ts: &str,
    now: i64,
    header: &[u8],
    body: &[u8],
) -> VerifyOutcome {
    let tokens: Vec<&[u8]> = header.split(|&c| c == b' ').collect();
    if tokens.iter().all(|t| t.is_empty()) {
        return VerifyOutcome::Fail(VerifyFailure::MissingSignature);
    }
    let ts_val = match is_canonical_int(ts.as_bytes()) {
        Some(v) => v,
        None => return VerifyOutcome::Fail(VerifyFailure::InvalidTimestamp),
    };
    if now - ts_val > TOLERANCE_SECS {
        return VerifyOutcome::Fail(VerifyFailure::TimestampTooOld);
    }
    if ts_val - now > TOLERANCE_SECS {
        return VerifyOutcome::Fail(VerifyFailure::TimestampTooNew);
    }
    // Decode each `v1,<value>` token once.
    let decoded: Vec<Option<Vec<u8>>> = tokens
        .iter()
        .map(|t| {
            let comma = t.iter().position(|&c| c == b',')?;
            if &t[..comma] != b"v1" {
                return None;
            }
            base64::decode(&t[comma + 1..])
        })
        .collect();
    for (i, secret) in secrets.iter().enumerate() {
        let mac = sign(secret, id, ts, body);
        for (j, d) in decoded.iter().enumerate() {
            if d.as_deref() == Some(&mac[..]) {
                return VerifyOutcome::Ok { secret: i, token: j };
            }
        }
    }
    VerifyOutcome::Fail(VerifyFailure::NoMatch)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
    const ID: &str = "msg_p5jXN8AQM9LWM0D4loKWxJek";
    const BODY: &[u8] = br#"{"test": 2432232314}"#;
    const SIG: &str = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=";

    fn secrets() -> Vec<Secret> {
        vec![Secret::parse(SECRET).unwrap()]
    }

    #[test]
    fn published_vector() {
        assert_eq!(sign_header(&secrets(), ID, "1614265330", BODY), SIG);
    }

    #[test]
    fn rotation_header() {
        let s = vec![Secret::parse(SECRET).unwrap(), Secret::parse("c2VjcmV0").unwrap()];
        let h = sign_header(&s, ID, "1614265330", BODY);
        let parts: Vec<&str> = h.split(' ').collect();
        assert_eq!(parts.len(), 2);
        assert_eq!(parts[0], SIG);
        assert_eq!(
            verify(&s, ID, "1614265330", 1614265330, h.as_bytes(), BODY),
            VerifyOutcome::Ok { secret: 0, token: 0 }
        );
        // The second secret only matches its own token.
        let swapped = format!("{} {}", parts[1], parts[0]);
        assert_eq!(
            verify(&s, ID, "1614265330", 1614265330, swapped.as_bytes(), BODY),
            VerifyOutcome::Ok { secret: 0, token: 1 }
        );
    }

    #[test]
    fn tolerance_is_inclusive() {
        let ts = "1614265330";
        let v = |now| verify(&secrets(), ID, ts, now, SIG.as_bytes(), BODY);
        assert_eq!(v(1614265330 + 300), VerifyOutcome::Ok { secret: 0, token: 0 });
        assert_eq!(v(1614265330 + 301), VerifyOutcome::Fail(VerifyFailure::TimestampTooOld));
        assert_eq!(v(1614265330 - 300), VerifyOutcome::Ok { secret: 0, token: 0 });
        assert_eq!(v(1614265330 - 301), VerifyOutcome::Fail(VerifyFailure::TimestampTooNew));
    }

    #[test]
    fn failure_ordering() {
        let s = secrets();
        assert_eq!(
            verify(&s, ID, "abc", 0, b"", BODY),
            VerifyOutcome::Fail(VerifyFailure::MissingSignature)
        );
        assert_eq!(
            verify(&s, ID, "abc", 0, b"  ", BODY),
            VerifyOutcome::Fail(VerifyFailure::MissingSignature)
        );
        assert_eq!(
            verify(&s, ID, "01", 0, b"x", BODY),
            VerifyOutcome::Fail(VerifyFailure::InvalidTimestamp)
        );
        assert_eq!(
            verify(&s, ID, "1614265330", 1614265330, b"v1,AAAA", BODY),
            VerifyOutcome::Fail(VerifyFailure::NoMatch)
        );
    }

    #[test]
    fn garbage_tokens_are_skipped_and_indexed() {
        let h = format!("garbage  v2,{} {}", &SIG[3..], SIG);
        assert_eq!(
            verify(&secrets(), ID, "1614265330", 1614265330, h.as_bytes(), BODY),
            VerifyOutcome::Ok { secret: 0, token: 3 }
        );
    }

    #[test]
    fn canonical_ints() {
        for ok in ["0", "5", "-5", "1000000000000000", "-1000000000000000"] {
            assert!(is_canonical_int(ok.as_bytes()).is_some(), "{ok}");
        }
        for bad in ["", "-", "-0", "+5", "007", "1.0", "1e3", "1000000000000001", "99999999999999999999"] {
            assert!(is_canonical_int(bad.as_bytes()).is_none(), "{bad}");
        }
    }
}

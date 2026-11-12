//! Webhook signing secrets.

use crate::base64;
use crate::hmac::HmacKey;
use std::fmt;

/// Why a secret string was rejected.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SecretError {
    /// The text (after any `whsec_` prefix) is not valid Base64.
    InvalidBase64,
    /// The text decodes to zero bytes.
    Empty,
}

impl fmt::Display for SecretError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SecretError::InvalidBase64 => f.write_str("secret is not valid Base64"),
            SecretError::Empty => f.write_str("secret decodes to zero bytes"),
        }
    }
}

impl std::error::Error for SecretError {}

/// A decoded signing secret, ready to compute MACs.
#[derive(Clone, Debug)]
pub struct Secret {
    raw: Vec<u8>,
    key: HmacKey,
}

impl Secret {
    /// Parses a secret such as `whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw`.
    ///
    /// A single leading `whsec_` is removed; the remainder is Base64-decoded
    /// (either alphabet, padding optional) into the raw key, which must not be
    /// empty.
    pub fn parse(text: &str) -> Result<Secret, SecretError> {
        Self::parse_bytes(text.as_bytes())
    }

    /// Like [`Secret::parse`] but on raw bytes.
    pub fn parse_bytes(text: &[u8]) -> Result<Secret, SecretError> {
        let rest = text.strip_prefix(b"whsec_").unwrap_or(text);
        let raw = base64::decode(rest).ok_or(SecretError::InvalidBase64)?;
        if raw.is_empty() {
            return Err(SecretError::Empty);
        }
        Ok(Secret { key: HmacKey::new(&raw), raw })
    }

    /// The raw HMAC key bytes.
    pub fn key_bytes(&self) -> &[u8] {
        &self.raw
    }

    /// The precomputed HMAC key.
    pub fn hmac_key(&self) -> &HmacKey {
        &self.key
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefix_is_optional_and_stripped_once() {
        let a = Secret::parse("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw").unwrap();
        let b = Secret::parse("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw").unwrap();
        assert_eq!(a.key_bytes(), b.key_bytes());
        assert_eq!(a.key_bytes().len(), 24);
        // "whsec_whsec_" -> second prefix is Base64 text ('_' is URL-safe).
        let c = Secret::parse("whsec_whsec_AAAA").unwrap();
        assert_eq!(c.key_bytes().len(), 7);
    }

    #[test]
    fn invalid_secrets() {
        assert_eq!(Secret::parse("whsec_").unwrap_err(), SecretError::Empty);
        assert_eq!(Secret::parse("A").unwrap_err(), SecretError::InvalidBase64);
        assert_eq!(Secret::parse("whsec_=").unwrap_err(), SecretError::InvalidBase64);
        assert_eq!(Secret::parse("a+b-").unwrap_err(), SecretError::InvalidBase64);
    }

    #[test]
    fn optional_padding_forms() {
        let s = Secret::parse("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr").unwrap();
        assert_eq!(s.key_bytes().len(), 25);
    }
}

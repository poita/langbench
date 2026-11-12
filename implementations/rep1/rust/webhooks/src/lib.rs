//! # webhooks
//!
//! A small, dependency-free implementation of the
//! [Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md)
//! signature scheme, together with the cryptographic primitives it needs and a
//! deterministic webhook delivery simulator.
//!
//! The crate is organised by responsibility:
//!
//! | module | contents |
//! |---|---|
//! | [`sha256`] | FIPS 180-4 SHA-256 (one-shot and streaming) |
//! | [`hmac`] | RFC 2104 HMAC-SHA-256 with precomputed key state |
//! | [`base64`] | standard / URL-safe Base64 encoding and lenient decoding |
//! | [`hex`] | the lowercase hex codec used by the command stream |
//! | [`secret`] | `whsec_` secrets ([`Secret`]) |
//! | [`signature`] | signing and verification ([`sign`], [`verify`]) |
//! | [`simulator`] | retry schedule and delivery simulation ([`simulate`]) |
//! | [`protocol`] | the line-oriented command protocol ([`run_commands`]) |
//!
//! SHA-256, HMAC and Base64 are implemented here from scratch.
//!
//! ```
//! use webhooks::{Secret, sign_header, verify, VerifyOutcome};
//!
//! let secret = Secret::parse("whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw").unwrap();
//! let body = br#"{"test": 2432232314}"#;
//! let header = sign_header(&[secret.clone()], "msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", body);
//! assert_eq!(header, "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=");
//!
//! let outcome = verify(
//!     &[secret],
//!     "msg_p5jXN8AQM9LWM0D4loKWxJek",
//!     "1614265330",
//!     1614265400,
//!     header.as_bytes(),
//!     body,
//! );
//! assert_eq!(outcome, VerifyOutcome::Ok { secret: 0, token: 0 });
//! ```

pub mod base64;
pub mod hex;
pub mod hmac;
pub mod protocol;
pub mod secret;
pub mod sha256;
pub mod signature;
pub mod simulator;

pub use hmac::{hmac_sha256, HmacKey};
pub use protocol::run_commands;
pub use secret::{Secret, SecretError};
pub use sha256::{sha256, Sha256};
pub use signature::{
    is_canonical_int, sign, sign_header, verify, VerifyFailure, VerifyOutcome, TOLERANCE_SECS,
};
pub use simulator::{
    simulate, Attempt, Delivery, DeliveryStatus, Endpoint, Event, Filter, Outcome, Report,
    Response, MAX_ATTEMPTS, RETRY_DELAYS,
};

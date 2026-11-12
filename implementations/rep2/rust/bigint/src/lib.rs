//! # bigint
//!
//! Signed arbitrary-precision integer arithmetic implemented from scratch on
//! top of fixed-size machine integers.
//!
//! Numbers are stored as a sign and a magnitude whose limbs are base 10⁹
//! digits, so decimal parsing and printing are linear in the number of
//! digits. Arithmetic uses the classical algorithms: linear addition and
//! subtraction, schoolbook multiplication, Knuth's Algorithm D for division
//! and binary exponentiation.
//!
//! ```
//! use bigint::BigInt;
//!
//! let a: BigInt = "-123456789012345678901234567890".parse().unwrap();
//! let b: BigInt = "987654321098765432109876543210".parse().unwrap();
//! assert_eq!(
//!     (&a * &b).to_string(),
//!     "-121932631137021795226185032733622923332237463801111263526900"
//! );
//!
//! let (q, r) = BigInt::from(-7).div_rem(&BigInt::from(2)).unwrap();
//! assert_eq!((q.to_string(), r.to_string()), ("-3".into(), "-1".into()));
//! ```
//!
//! # Modules
//!
//! * [`natural`] – unsigned magnitudes ([`Natural`]).
//! * [`int`] – signed integers ([`BigInt`]) and operator impls.
//! * [`query`] – the line-oriented query language used by the CLI.

pub mod error;
pub mod int;
pub mod natural;
pub mod query;

pub use error::{ArithmeticError, ParseError};
pub use int::BigInt;
pub use natural::Natural;

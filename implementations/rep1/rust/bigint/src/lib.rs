//! # bigint
//!
//! Arbitrary-precision signed integer arithmetic implemented from scratch
//! with the classical algorithms:
//!
//! * numbers are stored as a sign and a magnitude in base 10⁹, so parsing and
//!   printing decimal text is linear in the number of digits;
//! * addition, subtraction and comparison are linear;
//! * multiplication is schoolbook, O(n·m);
//! * division uses Knuth's Algorithm D, O((n − m + 1)·m), producing quotient
//!   and remainder together;
//! * exponentiation is binary exponentiation (repeated squaring).
//!
//! The crate is split into:
//!
//! * [`natural`] — the unsigned magnitude type [`Natural`];
//! * [`int`] — the signed integer type [`BigInt`] (truncating division, C-style
//!   remainder);
//! * [`query`] — parsing and evaluation of the `<a> <op> <b>` line format used
//!   by the command-line tool;
//! * [`error`] — the error types.
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
//! let (q, r) = BigInt::from(-7).div_rem(&BigInt::from(2)).unwrap();
//! assert_eq!((q.to_string(), r.to_string()), ("-3".into(), "-1".into()));
//! ```

pub mod error;
pub mod int;
pub mod natural;
pub mod query;

pub use error::{ArithmeticError, ParseError};
pub use int::BigInt;
pub use natural::Natural;

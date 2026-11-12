//! # softfloat
//!
//! IEEE-754 binary32 (single precision) addition, subtraction, multiplication,
//! division and square root, implemented with integer arithmetic only.
//!
//! Values are exchanged as raw `u32` bit patterns, so every bit of the result
//! (including the sign of zero) is observable. All operations use
//! round-to-nearest, ties-to-even, with full gradual underflow. Every NaN
//! result is the canonical quiet NaN [`QNAN`] (`0x7fc00000`). Exception flags
//! are not modelled.
//!
//! No host floating point is used anywhere in the library, and every
//! intermediate value fits in a `u64`.
//!
//! ```
//! use softfloat::{add, div, sqrt};
//!
//! assert_eq!(add(0x3f80_0000, 0x3f80_0000), 0x4000_0000); // 1 + 1 = 2
//! assert_eq!(div(0x3f80_0000, 0x4040_0000), 0x3eaa_aaab); // 1 / 3
//! assert_eq!(sqrt(0x4000_0000), 0x3fb5_04f3);             // sqrt(2)
//! ```
//!
//! ## Modules
//!
//! * [`format`] – binary32 field layout, classification and unpacking.
//! * [`round`]  – the shared round-to-nearest-even and pack step.
//! * [`addsub`], [`mul`], [`div`], [`sqrt`] – the operations.
//! * [`line`]   – parsing and evaluation of the text line protocol used by
//!   the command-line tool.

pub mod addsub;
pub mod div;
pub mod format;
pub mod line;
pub mod mul;
pub mod round;
pub mod sqrt;

pub use addsub::{add, sub};
pub use div::div;
pub use format::QNAN;
pub use mul::mul;
pub use sqrt::sqrt;

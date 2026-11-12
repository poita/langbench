//! A deterministic CHIP-8 interpreter.
//!
//! The crate is split by responsibility:
//!
//! * [`machine`] – the CPU/memory model ([`Machine`]) that executes opcodes;
//! * [`display`] – the 64×32 one-bit frame buffer ([`Display`]);
//! * [`keys`] – the key-schedule ([`KeySchedule`]) that drives the keypad;
//! * [`rng`] – the specified linear congruential generator ([`Lcg`]);
//! * [`font`] – the built-in hexadecimal font;
//! * [`input`] – parsing of the textual input format ([`Input`]);
//! * [`output`] – rendering of the final machine state as text;
//! * [`error`] – the [`ParseError`] type.
//!
//! Every cycle is interpreted straight from memory: there is no pre-decoding
//! or caching, so self-modifying programs behave correctly.
//!
//! # Example
//!
//! ```
//! use chip8::{Machine, KeySchedule};
//!
//! // V0 = 0xFF; V0 += 1; V1 = 1; V0 += V1; jump to self.
//! let rom = [0x60, 0xFF, 0x70, 0x01, 0x61, 0x01, 0x80, 0x14, 0x12, 0x08];
//! let mut m = Machine::new(&rom).unwrap();
//! m.run(6, &KeySchedule::default());
//! assert_eq!(m.v[0], 1);
//! assert_eq!(m.pc, 0x208);
//! ```

pub mod display;
pub mod error;
pub mod font;
pub mod input;
pub mod keys;
pub mod machine;
pub mod output;
pub mod rng;

pub use display::{Display, HEIGHT, WIDTH};
pub use error::ParseError;
pub use input::Input;
pub use keys::KeySchedule;
pub use machine::Machine;
pub use rng::Lcg;

use std::fmt::Write as _;

/// Parses `text` (the textual input format), runs the machine and returns
/// the rendered 34-line report.
///
/// # Errors
///
/// Returns a [`ParseError`] if the input is malformed.
///
/// ```
/// let out = chip8::run_text("6001\n1\n").unwrap();
/// assert!(out.ends_with("V=01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n"));
/// ```
pub fn run_text(text: &str) -> Result<String, ParseError> {
    let input = Input::parse(text)?;
    let mut machine = Machine::new(&input.rom)?;
    machine.run(input.cycles, &input.keys);
    let mut s = String::new();
    let _ = write!(s, "{}", output::Report(&machine));
    Ok(s)
}

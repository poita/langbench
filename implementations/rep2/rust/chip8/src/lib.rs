//! A deterministic CHIP-8 interpreter.
//!
//! The crate is split into small modules:
//!
//! * [`machine`] – the CPU/memory model ([`Machine`]) that executes opcodes;
//! * [`display`] – the 64×32 monochrome frame buffer ([`Display`]);
//! * [`keys`] – key schedules ([`KeySchedule`], [`KeyEvent`]);
//! * [`rng`] – the specified linear congruential generator ([`Lcg`]);
//! * [`font`] – the built-in hexadecimal font;
//! * [`input`] – parsing of the textual job format ([`Job`]);
//! * [`render`] – formatting of the final state as text;
//! * [`error`] – error types.
//!
//! # Example
//!
//! ```
//! use chip8::{Job, Machine};
//!
//! // V0 = 0xFF; V0 += 1; V1 = 1; V0 += V1; jump to self.
//! let job = Job::parse("60ff7001610180141208\n6\n").unwrap();
//! let mut machine = Machine::new();
//! machine.load_rom(&job.rom).unwrap();
//! machine.run(job.cycles, &job.schedule);
//! assert_eq!(machine.registers()[0], 1);
//! assert_eq!(machine.pc(), 0x208);
//! println!("{}", chip8::render::render(&machine));
//! ```

pub mod display;
pub mod error;
pub mod font;
pub mod input;
pub mod keys;
pub mod machine;
pub mod render;
pub mod rng;

pub use display::{Display, HEIGHT, WIDTH};
pub use error::{ParseError, RomError};
pub use input::Job;
pub use keys::{KeyEvent, KeySchedule};
pub use machine::{Machine, MEMORY_SIZE, PROGRAM_START};
pub use rng::Lcg;

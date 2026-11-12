//! # rrule
//!
//! Expansion of RFC 5545 recurrence rules (`FREQ`, `INTERVAL`, `COUNT`,
//! `UNTIL`, `WKST` and the `BY…` parts) with the occurrence semantics of
//! python-dateutil's `rrule`. All calendar arithmetic (leap years, weekdays,
//! week numbers) is implemented in this crate, on floating (zone-less)
//! date-times.
//!
//! Modules:
//!
//! * [`calendar`] – proleptic Gregorian arithmetic on day numbers;
//! * [`datetime`] – [`Date`] and [`DateTime`];
//! * [`rule`] – the [`Rule`] model and its parser;
//! * [`weeknum`] – `BYWEEKNO` week numbering;
//! * [`recurrence`] – the [`Recurrence`] iterator that expands a rule;
//! * [`request`] – the `<DTSTART> <RRULE> <N>` line format used by the CLI.
//!
//! ```
//! use rrule::{DateTime, Recurrence, Rule};
//!
//! let start: DateTime = "19970902T090000".parse().unwrap();
//! let rule: Rule = "FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;COUNT=3".parse().unwrap();
//! let days: Vec<String> = Recurrence::new(start, &rule).map(|d| d.to_string()).collect();
//! assert_eq!(days, ["19970926T090000", "19971128T090000", "19980130T090000"]);
//! ```

pub mod calendar;
pub mod datetime;
pub mod error;
pub mod recurrence;
pub mod request;
pub mod rule;
pub mod weeknum;

pub use datetime::{Date, DateTime};
pub use error::ParseError;
pub use recurrence::Recurrence;
pub use request::Request;
pub use rule::{ByDay, Freq, Rule, Weekday};

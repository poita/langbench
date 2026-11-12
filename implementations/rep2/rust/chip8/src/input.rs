//! Parsing of the textual job format.
//!
//! ```text
//! <rom-hex>
//! <cycles>
//! <key-schedule>      (optional; events "<cycle>:<mask>" separated by spaces)
//! ```

use crate::error::ParseError;
use crate::keys::{KeyEvent, KeySchedule};

/// A fully parsed run description.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Job {
    /// ROM bytes, to be loaded at `0x200`.
    pub rom: Vec<u8>,
    /// Number of instruction cycles to execute.
    pub cycles: u64,
    /// Key events.
    pub schedule: KeySchedule,
}

impl Job {
    /// Parses the textual job format. A trailing newline is optional and the
    /// third line may be absent or empty.
    pub fn parse(text: &str) -> Result<Job, ParseError> {
        let mut lines = text.split('\n').map(|l| l.trim_end_matches('\r'));
        let rom_line = lines.next().ok_or(ParseError::MissingLine("ROM"))?;
        let cycles_line = lines.next().ok_or(ParseError::MissingLine("cycles"))?;
        let schedule_line = lines.next().unwrap_or("");

        let rom = parse_hex(rom_line.trim())?;
        if rom.is_empty() {
            return Err(ParseError::InvalidRom(rom_line.to_string()));
        }
        let cycles_line = cycles_line.trim();
        let cycles: u64 = cycles_line
            .parse()
            .map_err(|_| ParseError::InvalidCycles(cycles_line.to_string()))?;
        let schedule = parse_schedule(schedule_line.trim(), cycles)?;
        Ok(Job { rom, cycles, schedule })
    }
}

fn parse_hex(s: &str) -> Result<Vec<u8>, ParseError> {
    let err = || ParseError::InvalidRom(s.to_string());
    if !s.len().is_multiple_of(2) || !s.is_ascii() {
        return Err(err());
    }
    s.as_bytes()
        .chunks(2)
        .map(|pair| {
            let hi = (pair[0] as char).to_digit(16).ok_or_else(err)?;
            let lo = (pair[1] as char).to_digit(16).ok_or_else(err)?;
            Ok((hi * 16 + lo) as u8)
        })
        .collect()
}

fn parse_schedule(s: &str, cycles: u64) -> Result<KeySchedule, ParseError> {
    let mut events: Vec<KeyEvent> = Vec::new();
    for item in s.split_whitespace() {
        let err = || ParseError::InvalidEvent(item.to_string());
        let (c, m) = item.split_once(':').ok_or_else(err)?;
        let cycle: u64 = c.parse().map_err(|_| err())?;
        let mask = u16::from_str_radix(m, 16).map_err(|_| err())?;
        if m.len() != 4 {
            return Err(err());
        }
        if cycle > cycles {
            return Err(ParseError::EventAfterEnd(cycle));
        }
        if let Some(prev) = events.last() {
            if prev.cycle >= cycle {
                return Err(ParseError::EventsNotIncreasing(cycle));
            }
        }
        events.push(KeyEvent { cycle, mask });
    }
    Ok(KeySchedule::from_events(events).expect("order checked while parsing"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_all_three_lines() {
        let job = Job::parse("00e0\n10\n3:0001 5:ffff").unwrap();
        assert_eq!(job.rom, vec![0x00, 0xe0]);
        assert_eq!(job.cycles, 10);
        assert_eq!(
            job.schedule.events(),
            &[KeyEvent { cycle: 3, mask: 1 }, KeyEvent { cycle: 5, mask: 0xffff }]
        );
    }

    #[test]
    fn schedule_is_optional() {
        assert!(Job::parse("00e0\n0\n").unwrap().schedule.is_empty());
        assert!(Job::parse("00e0\n0").unwrap().schedule.is_empty());
        assert!(Job::parse("00e0\n0\n\n").unwrap().schedule.is_empty());
    }

    #[test]
    fn rejects_malformed_input() {
        assert!(matches!(Job::parse("00e\n1"), Err(ParseError::InvalidRom(_))));
        assert!(matches!(Job::parse("zz\n1"), Err(ParseError::InvalidRom(_))));
        assert!(matches!(Job::parse("00e0"), Err(ParseError::MissingLine(_))));
        assert!(matches!(Job::parse("00e0\nx"), Err(ParseError::InvalidCycles(_))));
        assert!(matches!(Job::parse("00e0\n5\n1:1"), Err(ParseError::InvalidEvent(_))));
        assert!(matches!(
            Job::parse("00e0\n5\n2:0001 2:0002"),
            Err(ParseError::EventsNotIncreasing(2))
        ));
        assert!(matches!(Job::parse("00e0\n5\n6:0001"), Err(ParseError::EventAfterEnd(6))));
    }
}

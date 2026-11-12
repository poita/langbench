//! Parsing of the textual input format.

use crate::error::ParseError;
use crate::keys::{KeyEvent, KeySchedule};

/// Maximum ROM size in bytes (memory from `0x200` to `0xFFF`).
pub const MAX_ROM: usize = 0x1000 - 0x200;

/// A parsed input: ROM bytes, cycle budget and key schedule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Input {
    /// ROM bytes, loaded at `0x200`.
    pub rom: Vec<u8>,
    /// Number of instruction cycles to execute.
    pub cycles: u64,
    /// Key-state events.
    pub keys: KeySchedule,
}

impl Input {
    /// Parses the three-line input format (the third line is optional).
    ///
    /// ```
    /// let i = chip8::Input::parse("6001\n10\n3:0001 7:0000\n").unwrap();
    /// assert_eq!(i.rom, [0x60, 0x01]);
    /// assert_eq!(i.cycles, 10);
    /// assert_eq!(i.keys.events().len(), 2);
    /// ```
    pub fn parse(text: &str) -> Result<Input, ParseError> {
        let mut lines = text.split('\n').map(|l| l.trim_end_matches('\r'));
        let rom_line = lines.next().ok_or(ParseError::MissingLine("ROM"))?;
        let cycles_line = lines
            .next()
            .filter(|l| !l.trim().is_empty())
            .ok_or(ParseError::MissingLine("cycle count"))?;
        let key_line = lines.next().unwrap_or("");

        let rom = parse_hex(rom_line.trim())?;
        if rom.is_empty() || rom.len() > MAX_ROM {
            return Err(ParseError::RomSize(rom.len()));
        }
        let cycles = cycles_line
            .trim()
            .parse::<u64>()
            .map_err(|_| ParseError::BadCycles(cycles_line.to_string()))?;
        let keys = parse_schedule(key_line)?;
        Ok(Input { rom, cycles, keys })
    }
}

fn hex_val(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

fn parse_hex(s: &str) -> Result<Vec<u8>, ParseError> {
    let b = s.as_bytes();
    if b.len() % 2 != 0 {
        return Err(ParseError::BadRom("odd number of digits".into()));
    }
    b.chunks(2)
        .map(|p| match (hex_val(p[0]), hex_val(p[1])) {
            (Some(h), Some(l)) => Ok(h << 4 | l),
            _ => Err(ParseError::BadRom("non-hex character".into())),
        })
        .collect()
}

fn parse_schedule(line: &str) -> Result<KeySchedule, ParseError> {
    let mut events: Vec<KeyEvent> = Vec::new();
    for tok in line.split_whitespace() {
        let bad = || ParseError::BadEvent(tok.to_string());
        let (c, m) = tok.split_once(':').ok_or_else(bad)?;
        let cycle = c.parse::<u64>().map_err(|_| bad())?;
        let mask = u16::from_str_radix(m, 16).map_err(|_| bad())?;
        if events.last().is_some_and(|e| e.cycle >= cycle) {
            return Err(bad());
        }
        events.push(KeyEvent { cycle, mask });
    }
    Ok(KeySchedule::new(events))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn optional_key_line() {
        assert!(Input::parse("00e0\n0").unwrap().keys.events().is_empty());
        assert!(Input::parse("00e0\n0\n\n").unwrap().keys.events().is_empty());
    }

    #[test]
    fn errors() {
        assert!(matches!(Input::parse("0\n1"), Err(ParseError::BadRom(_))));
        assert!(matches!(Input::parse("\n1"), Err(ParseError::RomSize(0))));
        assert!(matches!(Input::parse("00"), Err(ParseError::MissingLine(_))));
        assert!(matches!(Input::parse("00\nx"), Err(ParseError::BadCycles(_))));
        assert!(matches!(
            Input::parse("00\n5\n3:0001 3:0000"),
            Err(ParseError::BadEvent(_))
        ));
    }
}

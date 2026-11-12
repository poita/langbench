//! One line of the command-line input: `<DTSTART> <RRULE> <N>`.

use crate::datetime::DateTime;
use crate::error::ParseError;
use crate::recurrence::Recurrence;
use crate::rule::Rule;

/// A parsed request: expand `rule` from `start` and keep at most `limit`
/// occurrences.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    /// DTSTART.
    pub start: DateTime,
    /// The recurrence rule.
    pub rule: Rule,
    /// Maximum number of occurrences to produce.
    pub limit: usize,
}

impl Request {
    /// Parses `"<YYYYMMDDTHHMMSS> <RRULE> <N>"`.
    pub fn parse(line: &str) -> Result<Request, ParseError> {
        let mut parts = line.split(' ');
        let (Some(start), Some(rule), Some(limit), None) = (parts.next(), parts.next(), parts.next(), parts.next())
        else {
            return Err(ParseError::new("expected `<DTSTART> <RRULE> <N>`"));
        };
        let limit: usize = limit.parse().map_err(|_| ParseError::new(format!("invalid limit {limit:?}")))?;
        Ok(Request { start: DateTime::parse(start)?, rule: Rule::parse(rule)?, limit })
    }

    /// Computes the occurrences as a space-separated line (without newline).
    pub fn render(&self) -> String {
        let mut out = String::new();
        for (i, occ) in Recurrence::new(self.start, &self.rule).take(self.limit).enumerate() {
            if i > 0 {
                out.push(' ');
            }
            occ.write_to(&mut out);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_and_render() {
        let r = Request::parse("20240101T000000 FREQ=DAILY;COUNT=3 2").unwrap();
        assert_eq!(r.limit, 2);
        assert_eq!(r.render(), "20240101T000000 20240102T000000");
    }

    #[test]
    fn bad_lines() {
        assert!(Request::parse("").is_err());
        assert!(Request::parse("20240101T000000 FREQ=DAILY").is_err());
        assert!(Request::parse("20240101T000000 FREQ=DAILY x").is_err());
        assert!(Request::parse("20240101T000000 FREQ=DAILY 1 2").is_err());
    }
}

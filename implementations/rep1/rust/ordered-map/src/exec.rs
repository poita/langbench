//! Executing commands against an [`OrderedMap`] and rendering the output.

use crate::command::Command;
use crate::map::OrderedMap;
use std::io::{self, Write};

/// Executes one command against `map`, writing its single output line
/// (including the trailing `\n`) to `out`.
pub fn execute<W: Write>(
    map: &mut OrderedMap<String>,
    cmd: Command,
    out: &mut W,
) -> io::Result<()> {
    fn opt<W: Write>(out: &mut W, v: Option<i64>, none: &str) -> io::Result<()> {
        match v {
            Some(k) => writeln!(out, "{k}"),
            None => writeln!(out, "{none}"),
        }
    }
    match cmd {
        Command::Insert(k, v) => {
            let updated = map.insert(k, v).is_some();
            writeln!(out, "{}", if updated { "updated" } else { "ok" })
        }
        Command::Delete(k) => {
            let found = map.remove(k).is_some();
            writeln!(out, "{}", if found { "ok" } else { "missing" })
        }
        Command::Get(k) => match map.get(k) {
            Some(v) => writeln!(out, "{v}"),
            None => writeln!(out, "missing"),
        },
        Command::Size => writeln!(out, "{}", map.len()),
        Command::Min => opt(out, map.min(), "empty"),
        Command::Max => opt(out, map.max(), "empty"),
        Command::Floor(k) => opt(out, map.floor(k), "missing"),
        Command::Ceil(k) => opt(out, map.ceil(k), "missing"),
        Command::Succ(k) => opt(out, map.successor(k), "missing"),
        Command::Pred(k) => opt(out, map.predecessor(k), "missing"),
        Command::Rank(k) => writeln!(out, "{}", map.rank(k)),
        Command::Select(k) => {
            let found = usize::try_from(k).ok().and_then(|k| map.select(k));
            opt(out, found, "missing")
        }
        Command::Range(lo, hi) => {
            let mut keys = map.range(lo..=hi).map(|(k, _)| k);
            match keys.next() {
                None => writeln!(out, "empty")?,
                Some(first) => {
                    write!(out, "{first}")?;
                    for k in keys {
                        write!(out, " {k}")?;
                    }
                    writeln!(out)?;
                }
            }
            Ok(())
        }
    }
}

/// Runs a whole session: `input` is the text of the `Q` header line followed
/// by `Q` command lines; the results are written to `out`.
///
/// Returns an `InvalidData` error describing the offending line if the input
/// is malformed.
pub fn run<W: Write>(input: &str, out: &mut W) -> io::Result<()> {
    let bad = |msg: String| io::Error::new(io::ErrorKind::InvalidData, msg);
    let mut lines = input.lines();
    let header = lines.next().unwrap_or("0");
    let q: usize = header
        .trim()
        .parse()
        .map_err(|_| bad(format!("invalid command count `{header}`")))?;
    let mut map = OrderedMap::new();
    for i in 0..q {
        let line = lines
            .next()
            .ok_or_else(|| bad(format!("expected {q} commands, found {i}")))?;
        let cmd = line
            .parse::<Command>()
            .map_err(|e| bad(format!("line {}: {e}", i + 2)))?;
        execute(&mut map, cmd, out)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(input: &str) -> String {
        let mut out = Vec::new();
        run(input, &mut out).unwrap();
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn spec_example_1() {
        let input = "12\nsize\nmin\ninsert 5 five\ninsert 5 FIVE\nget 5\ninsert 2 two\n\
                     insert 9 nine\nmin\nmax\nrange 2 9\ndelete 5\nrange 3 8";
        assert_eq!(session(input), "0\nempty\nok\nupdated\nFIVE\nok\nok\n2\n9\n2 5 9\nok\nempty\n");
    }

    #[test]
    fn zero_commands_is_empty_output() {
        assert_eq!(session("0\n"), "");
    }

    #[test]
    fn huge_select_is_missing() {
        assert_eq!(session("1\nselect 1000000000"), "missing\n");
    }

    #[test]
    fn malformed_input_is_an_error() {
        let mut out = Vec::new();
        assert!(run("2\nsize\n", &mut out).is_err());
        assert!(run("1\nbogus\n", &mut out).is_err());
        assert!(run("x\n", &mut out).is_err());
    }
}

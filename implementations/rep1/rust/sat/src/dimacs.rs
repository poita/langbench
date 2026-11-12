//! DIMACS CNF parsing and answer formatting.

use std::fmt;

/// A formula in conjunctive normal form, as read from a DIMACS file.
///
/// Clauses hold DIMACS literals: non-zero integers, `k` for variable `k`
/// being true and `-k` for it being false (`1 <= k <= num_vars`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Cnf {
    /// Number of variables declared in the header.
    pub num_vars: usize,
    /// The clauses, in input order.
    pub clauses: Vec<Vec<i32>>,
}

/// Why a DIMACS input could not be parsed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParseError {
    /// No `p cnf V C` header was found.
    MissingHeader,
    /// A second header line was found.
    DuplicateHeader,
    /// The header line is not of the form `p cnf V C`.
    BadHeader(String),
    /// A token in the clause data is not an integer.
    BadToken(String),
    /// A literal refers to a variable greater than the declared count.
    VariableOutOfRange(i32),
    /// The data ends in the middle of a clause (no terminating `0`).
    UnterminatedClause,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::MissingHeader => write!(f, "missing `p cnf` header"),
            ParseError::DuplicateHeader => write!(f, "more than one `p cnf` header"),
            ParseError::BadHeader(l) => write!(f, "malformed header line: {l:?}"),
            ParseError::BadToken(t) => write!(f, "not an integer: {t:?}"),
            ParseError::VariableOutOfRange(l) => write!(f, "literal {l} is out of range"),
            ParseError::UnterminatedClause => write!(f, "last clause is not terminated by 0"),
        }
    }
}

impl std::error::Error for ParseError {}

fn is_blank(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\r')
}

/// Parses DIMACS CNF text.
///
/// Comment lines (first non-blank character `c`) and blank lines are
/// skipped anywhere. Clauses are runs of integers terminated by `0` and may
/// span lines or share a line. The number of clauses in the header is not
/// enforced.
pub fn parse(input: &str) -> Result<Cnf, ParseError> {
    let mut cnf = Cnf::default();
    let mut header = false;
    let mut current: Vec<i32> = Vec::new();

    for raw in input.split('\n') {
        let line = raw.trim_matches(is_blank);
        match line.chars().next() {
            None | Some('c') => continue,
            Some('p') => {
                if header {
                    return Err(ParseError::DuplicateHeader);
                }
                let toks: Vec<&str> = line.split(is_blank).filter(|t| !t.is_empty()).collect();
                let bad = || ParseError::BadHeader(line.to_string());
                if toks.len() != 4 || toks[0] != "p" || toks[1] != "cnf" {
                    return Err(bad());
                }
                cnf.num_vars = toks[2].parse().map_err(|_| bad())?;
                toks[3].parse::<usize>().map_err(|_| bad())?;
                header = true;
            }
            Some(_) => {
                if !header {
                    return Err(ParseError::MissingHeader);
                }
                for tok in line.split(is_blank).filter(|t| !t.is_empty()) {
                    let n: i32 = tok
                        .parse()
                        .map_err(|_| ParseError::BadToken(tok.to_string()))?;
                    if n == 0 {
                        cnf.clauses.push(std::mem::take(&mut current));
                    } else if n.unsigned_abs() as usize > cnf.num_vars {
                        return Err(ParseError::VariableOutOfRange(n));
                    } else {
                        current.push(n);
                    }
                }
            }
        }
    }
    if !header {
        return Err(ParseError::MissingHeader);
    }
    if !current.is_empty() {
        return Err(ParseError::UnterminatedClause);
    }
    Ok(cnf)
}

/// Formats a solver answer in the output format: `UNSAT\n`, or `SAT\n`
/// followed by one line of literals (variable `i` as `i` when
/// `model[i - 1]` is true, else `-i`) terminated by `0`.
pub fn format_answer(model: Option<&[bool]>) -> String {
    match model {
        None => "UNSAT\n".to_string(),
        Some(m) => {
            let mut s = String::with_capacity(8 + m.len() * 6);
            s.push_str("SAT\n");
            for (i, &v) in m.iter().enumerate() {
                if !v {
                    s.push('-');
                }
                s.push_str(&(i + 1).to_string());
                s.push(' ');
            }
            s.push_str("0\n");
            s
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_layouts() {
        let cnf = parse("c hi\n\n  p  cnf\t3 3 \n1 -2\nc mid\n0 2 3 0\n0\ncend").unwrap();
        assert_eq!(cnf.num_vars, 3);
        assert_eq!(cnf.clauses, vec![vec![1, -2], vec![2, 3], vec![]]);
    }

    #[test]
    fn last_line_without_newline() {
        let cnf = parse("p cnf 1 1\n1 0").unwrap();
        assert_eq!(cnf.clauses, vec![vec![1]]);
    }

    #[test]
    fn rejects_bad_input() {
        assert_eq!(parse("1 0\n"), Err(ParseError::MissingHeader));
        assert_eq!(parse(""), Err(ParseError::MissingHeader));
        assert_eq!(parse("p cnf 1 1\n2 0"), Err(ParseError::VariableOutOfRange(2)));
        assert_eq!(parse("p cnf 1 1\n1"), Err(ParseError::UnterminatedClause));
        assert!(matches!(parse("p cnf 1 1\nx 0"), Err(ParseError::BadToken(_))));
        assert!(matches!(parse("p dnf 1 1\n"), Err(ParseError::BadHeader(_))));
        assert_eq!(parse("p cnf 1 0\np cnf 1 0\n"), Err(ParseError::DuplicateHeader));
    }

    #[test]
    fn formats_answers() {
        assert_eq!(format_answer(None), "UNSAT\n");
        assert_eq!(format_answer(Some(&[])), "SAT\n0\n");
        assert_eq!(format_answer(Some(&[true, false, true])), "SAT\n1 -2 3 0\n");
    }
}

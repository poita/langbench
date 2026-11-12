//! Reading and writing the DIMACS CNF format.

use std::fmt;

use crate::lit::Lit;
use crate::solver::{SolveResult, Solver};

/// A parsed CNF formula.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Cnf {
    /// Number of variables declared in the `p cnf` header.
    pub num_vars: usize,
    /// Clauses as DIMACS integers (non-zero, without the terminating 0).
    pub clauses: Vec<Vec<i32>>,
}

/// Error returned when the input is not valid DIMACS CNF.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    /// 1-based line number where the problem was detected.
    pub line: usize,
    /// Human-readable description.
    pub message: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "line {}: {}", self.line, self.message)
    }
}

impl std::error::Error for ParseError {}

impl Cnf {
    /// Parses DIMACS CNF text.
    ///
    /// Lines whose first non-blank character is `c` are comments, blank lines
    /// are ignored, a clause is a run of non-zero integers terminated by `0`
    /// and may span lines. A trailing unterminated clause is an error.
    ///
    /// ```
    /// let cnf = cdcl_sat::Cnf::parse("p cnf 2 1\n1 -2 0\n").unwrap();
    /// assert_eq!(cnf.clauses, vec![vec![1, -2]]);
    /// ```
    pub fn parse(text: &str) -> Result<Cnf, ParseError> {
        let mut cnf = Cnf::default();
        let mut have_header = false;
        let mut current: Vec<i32> = Vec::new();
        for (n, raw) in text.lines().enumerate() {
            let line_no = n + 1;
            let err = |message: String| ParseError { line: line_no, message };
            let line = raw.trim_matches(|c| c == ' ' || c == '\t' || c == '\r');
            if line.is_empty() || line.starts_with('c') {
                continue;
            }
            if line.starts_with('p') {
                if have_header {
                    return Err(err("duplicate header".into()));
                }
                let toks: Vec<&str> = line.split_whitespace().collect();
                if toks.len() != 4 || toks[0] != "p" || toks[1] != "cnf" {
                    return Err(err("malformed header".into()));
                }
                cnf.num_vars = toks[2].parse().map_err(|_| err("bad variable count".into()))?;
                // The clause count is validated implicitly by the data itself.
                toks[3]
                    .parse::<usize>()
                    .map_err(|_| err("bad clause count".into()))?;
                have_header = true;
                continue;
            }
            if !have_header {
                return Err(err("clause data before header".into()));
            }
            for tok in line.split_whitespace() {
                let v: i32 = tok.parse().map_err(|_| err(format!("bad integer {tok:?}")))?;
                if v == 0 {
                    cnf.clauses.push(std::mem::take(&mut current));
                } else {
                    if v.unsigned_abs() as usize > cnf.num_vars {
                        return Err(err(format!("literal {v} out of range")));
                    }
                    current.push(v);
                }
            }
        }
        if !current.is_empty() {
            return Err(ParseError {
                line: text.lines().count(),
                message: "last clause is not terminated by 0".into(),
            });
        }
        Ok(cnf)
    }

    /// Loads the formula into a fresh [`Solver`].
    pub fn into_solver(&self) -> Solver {
        let mut solver = Solver::new(self.num_vars);
        let mut buf: Vec<Lit> = Vec::new();
        for clause in &self.clauses {
            buf.clear();
            buf.extend(clause.iter().map(|&d| Lit::from_dimacs(d)));
            if !solver.add_clause(&buf) {
                break;
            }
        }
        solver
    }

    /// Solves the formula; on success returns a model (`model[i]` is the value
    /// of DIMACS variable `i + 1`).
    pub fn solve(&self) -> SolveResult {
        self.into_solver().solve()
    }
}

/// Renders a result in the output format of the `sat` tool:
/// `UNSAT\n`, or `SAT\n` followed by the model line terminated by `0`.
pub fn format_result(result: &SolveResult) -> String {
    match result {
        SolveResult::Unsat => "UNSAT\n".to_string(),
        SolveResult::Sat(model) => {
            let mut out = String::with_capacity(8 + model.len() * 6);
            out.push_str("SAT\n");
            for (i, &value) in model.iter().enumerate() {
                if value {
                    out.push_str(&(i + 1).to_string());
                } else {
                    out.push('-');
                    out.push_str(&(i + 1).to_string());
                }
                out.push(' ');
            }
            out.push_str("0\n");
            out
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_comments_blank_lines_and_split_clauses() {
        let text = "c hi\n\n  p cnf 2 4 \n1 2\nc inside\n0 -1 2 0\n\t-1 -2 0 1 -2 0\ncend";
        let cnf = Cnf::parse(text).unwrap();
        assert_eq!(cnf.num_vars, 2);
        assert_eq!(cnf.clauses, vec![vec![1, 2], vec![-1, 2], vec![-1, -2], vec![1, -2]]);
    }

    #[test]
    fn empty_clause_and_bare_c_comment() {
        let cnf = Cnf::parse("c\np cnf 1 1\n0").unwrap();
        assert_eq!(cnf.clauses, vec![Vec::<i32>::new()]);
    }

    #[test]
    fn rejects_bad_input() {
        assert!(Cnf::parse("1 2 0\n").is_err());
        assert!(Cnf::parse("p cnf 2 1\n1 2\n").is_err());
        assert!(Cnf::parse("p cnf 2 1\n3 0\n").is_err());
        assert!(Cnf::parse("p cnf 2 1\np cnf 2 1\n").is_err());
    }

    #[test]
    fn formats_results() {
        assert_eq!(format_result(&SolveResult::Unsat), "UNSAT\n");
        assert_eq!(format_result(&SolveResult::Sat(vec![])), "SAT\n0\n");
        assert_eq!(format_result(&SolveResult::Sat(vec![true, false])), "SAT\n1 -2 0\n");
    }
}

//! Splitting the input into modules (pass 0 of the compiler).

use crate::diag::{err, Diag, ErrorKind, Pos, Res};
use crate::lexer::is_keyword;

/// One module of the input stream: its name and body text.
#[derive(Clone, Debug)]
pub struct SourceModule {
    /// The module name from its `@module` header.
    pub name: String,
    /// The body: the lines after the header, joined with LF (no final LF).
    pub text: String,
    /// Number of lines in the body.
    pub num_lines: u32,
    /// Length (in scalar values) of the body's last line.
    pub last_line_len: u32,
}

/// Splits `input` into lines: a line ends at LF, one CR before the LF is
/// removed, and the final line need not be terminated.
pub fn split_lines(input: &str) -> Vec<&str> {
    if input.is_empty() {
        return Vec::new();
    }
    let mut lines: Vec<&str> = input.split('\n').collect();
    // The piece after the final LF is empty (and not a line) when the input
    // ends with a newline; otherwise it is an unterminated last line, which
    // keeps a trailing CR.
    let unterminated = if input.ends_with('\n') {
        lines.pop();
        None
    } else {
        Some(lines.len() - 1)
    };
    lines
        .into_iter()
        .enumerate()
        .map(|(i, l)| if Some(i) == unterminated { l } else { l.strip_suffix('\r').unwrap_or(l) })
        .collect()
}

fn is_ident(s: &str) -> bool {
    let mut cs = s.chars();
    match cs.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return false,
    }
    s.chars().count() <= 200
        && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        && s != "_"
        && !is_keyword(s)
}

fn header_name(line: &str) -> Option<&str> {
    let name = line.strip_prefix("@module ")?;
    if is_ident(name) {
        Some(name)
    } else {
        None
    }
}

/// Splits the module stream (section 2 of the specification).
///
/// # Errors
/// `bad-module` and `dup-module` diagnostics, with whole-input line numbers.
pub fn split_modules(input: &str) -> Res<Vec<SourceModule>> {
    let lines = split_lines(input);
    if lines.is_empty() {
        return err(ErrorKind::BadModule, Pos::new(1, 1));
    }
    // (name, header line index, body start)
    let mut headers: Vec<(String, usize)> = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        if line.starts_with('@') {
            match header_name(line) {
                Some(n) => headers.push((n.to_string(), i)),
                None => return err(ErrorKind::BadModule, Pos::new(i as u32 + 1, 1)),
            }
        } else if i == 0 {
            return err(ErrorKind::BadModule, Pos::new(1, 1));
        }
    }
    let mut seen = std::collections::HashSet::new();
    for (n, i) in &headers {
        if !seen.insert(n.clone()) {
            return Err(Diag::new(ErrorKind::DupModule, Pos::new(*i as u32 + 1, 1)));
        }
    }
    let mut out = Vec::new();
    for (k, (name, hi)) in headers.iter().enumerate() {
        let end = headers.get(k + 1).map(|h| h.1).unwrap_or(lines.len());
        let body = &lines[hi + 1..end];
        let text = body.join("\n");
        let (num_lines, last_line_len) = if body.is_empty() {
            (1, 0)
        } else {
            (body.len() as u32, body[body.len() - 1].chars().count() as u32)
        };
        out.push(SourceModule { name: name.clone(), text, num_lines, last_line_len });
    }
    Ok(out)
}

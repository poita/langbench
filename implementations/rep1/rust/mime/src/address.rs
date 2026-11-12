//! Address-list parsing (`From`, `To`, `Cc`, ...).

use crate::rfc2047::{decode_display, encoded_word};
use crate::scan::{is_blank, quoted_string, skip_comment};

/// A parsed address.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Address {
    /// The decoded display name (possibly empty).
    pub display: String,
    /// The address itself, e.g. `user@example.com`.
    pub spec: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Quoted,
    Literal,
    Encoded,
    Special,
    Atom,
}

#[derive(Debug, Clone)]
struct Token {
    kind: Kind,
    text: String,
    /// Index (in characters) of the token's first character in the value.
    start: usize,
}

impl Token {
    fn is_special(&self, c: char) -> bool {
        self.kind == Kind::Special && self.text.len() == 1 && self.text.starts_with(c)
    }
}

fn is_atom_delimiter(c: char) -> bool {
    is_blank(c) || "()<>[]@,:;.\"\\".contains(c)
}

fn tokenize(chars: &[char]) -> Vec<Token> {
    let mut tokens = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if is_blank(c) {
            i += 1;
        } else if c == '(' {
            i = skip_comment(chars, i);
        } else if c == '"' {
            let (text, next) = quoted_string(chars, i);
            tokens.push(Token { kind: Kind::Quoted, text, start: i });
            i = next;
        } else if c == '[' {
            let mut j = i + 1;
            let end = loop {
                if j >= chars.len() {
                    break chars.len();
                }
                match chars[j] {
                    '\\' if j + 1 < chars.len() => j += 2,
                    ']' => break j + 1,
                    _ => j += 1,
                }
            };
            tokens.push(Token { kind: Kind::Literal, text: chars[i..end].iter().collect(), start: i });
            i = end;
        } else if let Some((end, text)) = encoded_word(chars, i) {
            tokens.push(Token { kind: Kind::Encoded, text, start: i });
            i = end;
        } else if "<>@,:;.".contains(c) {
            tokens.push(Token { kind: Kind::Special, text: c.to_string(), start: i });
            i += 1;
        } else if ")]\\".contains(c) {
            tokens.push(Token { kind: Kind::Atom, text: c.to_string(), start: i });
            i += 1;
        } else {
            let mut j = i;
            while j < chars.len() && !is_atom_delimiter(chars[j]) {
                j += 1;
            }
            tokens.push(Token { kind: Kind::Atom, text: chars[i..j].iter().collect(), start: i });
            i = j;
        }
    }
    tokens
}

/// Splits tokens at top-level commas (outside any `<` ... `>` nesting).
fn split_elements(tokens: &[Token]) -> Vec<&[Token]> {
    let mut out = Vec::new();
    let mut depth = 0usize;
    let mut from = 0;
    for (k, t) in tokens.iter().enumerate() {
        if t.is_special('<') {
            depth += 1;
        } else if t.is_special('>') {
            depth = depth.saturating_sub(1);
        } else if t.is_special(',') && depth == 0 {
            out.push(&tokens[from..k]);
            from = k + 1;
        }
    }
    out.push(&tokens[from..]);
    out
}

/// Joins `items` at even positions with `.` at odd positions: returns the
/// texts if the run alternates strictly and every item satisfies `ok`.
fn dotted<'a>(run: &'a [Token], ok: impl Fn(&Token) -> bool) -> Option<Vec<&'a str>> {
    if run.is_empty() || run.len() % 2 == 0 {
        return None;
    }
    let mut texts = Vec::new();
    for (k, t) in run.iter().enumerate() {
        if k % 2 == 0 {
            if !ok(t) {
                return None;
            }
            texts.push(t.text.as_str());
        } else if !t.is_special('.') {
            return None;
        }
    }
    Some(texts)
}

fn render_addr_spec(run: &[Token]) -> Option<String> {
    let local_ok = |t: &Token| matches!(t.kind, Kind::Atom | Kind::Quoted);
    let at = run.iter().position(|t| t.is_special('@'));
    let local_run = &run[..at.unwrap_or(run.len())];
    let local = dotted(local_run, local_ok)?.join(".");
    let Some(at) = at else { return Some(local) };
    let domain = &run[at + 1..];
    let domain = if domain.len() == 1 && domain[0].kind == Kind::Literal {
        domain[0].text.clone()
    } else {
        dotted(domain, |t| t.kind == Kind::Atom)?.join(".")
    };
    Some(format!("{local}@{domain}"))
}

fn parse_element(chars: &[char], element: &[Token]) -> Option<Address> {
    let mut toks = element;
    for (k, t) in toks.iter().enumerate() {
        if t.is_special('<') || t.is_special('@') {
            break;
        }
        if t.is_special(':') {
            toks = &toks[k + 1..];
            break;
        }
    }
    if let Some(last) = toks.last() {
        if last.is_special(';') {
            toks = &toks[..toks.len() - 1];
        }
    }
    if toks.is_empty() {
        return None;
    }

    if let Some(lt) = toks.iter().position(|t| t.is_special('<')) {
        if let Some(gt) = toks.iter().rposition(|t| t.is_special('>')).filter(|&g| g > lt) {
            if let Some(spec) = render_addr_spec(&toks[lt + 1..gt]) {
                let display = if lt == 0 {
                    String::new()
                } else {
                    let s: String = chars[toks[0].start..toks[lt].start].iter().collect();
                    decode_display(&s)
                };
                return Some(Address { display, spec });
            }
        }
    } else if let Some(spec) = render_addr_spec(toks) {
        return Some(Address { display: String::new(), spec });
    }

    let spec: String = toks.iter().map(|t| t.text.as_str()).collect();
    Some(Address { display: String::new(), spec })
}

/// Parses an address-list header value into addresses.
pub fn parse_address_list(value: &str) -> Vec<Address> {
    let chars: Vec<char> = value.chars().collect();
    let tokens = tokenize(&chars);
    split_elements(&tokens)
        .into_iter()
        .filter_map(|el| parse_element(&chars, el))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list(v: &str) -> Vec<(String, String)> {
        parse_address_list(v).into_iter().map(|a| (a.display, a.spec)).collect()
    }

    fn one(display: &str, spec: &str) -> Vec<(String, String)> {
        vec![(display.to_string(), spec.to_string())]
    }

    #[test]
    fn spec_examples() {
        assert_eq!(list("Real Name <user@example.com>"), one("Real Name", "user@example.com"));
        assert_eq!(list("user@example.com (Real Name)"), one("", "user@example.com"));
        assert_eq!(list("\"Doe, John\" <jd@x.com>"), one("Doe, John", "jd@x.com"));
        assert_eq!(
            list("a@b.com, (c) d@e.com"),
            vec![("".into(), "a@b.com".into()), ("".into(), "d@e.com".into())]
        );
        assert!(list("Undisclosed recipients:;").is_empty());
        assert_eq!(
            list("grp: a@b.com, c@d.com;"),
            vec![("".into(), "a@b.com".into()), ("".into(), "c@d.com".into())]
        );
        assert_eq!(list("=?utf-8?B?SsO2cmc=?= <j@x.de>"), one("Jörg", "j@x.de"));
        assert_eq!(list("foo (c (nested)) <a@b>"), one("foo", "a@b"));
        assert_eq!(list("ed <a@[10.0.0.1]>"), one("ed", "a@[10.0.0.1]"));
        assert_eq!(list("broken <a@@b>"), one("", "broken<a@@b>"));
        assert_eq!(list("John Q. Public <jqp@example.com>"), one("John Q. Public", "jqp@example.com"));
        assert_eq!(list("Symantec Email Proxy"), one("", "SymantecEmailProxy"));
        assert_eq!(list("\"=?utf-8?Q?x?=\" <a@b>"), one("=?utf-8?Q?x?=", "a@b"));
        assert_eq!(
            list("a <b <c@d.com> , e@f.com>, g@h.com"),
            vec![("".into(), "a<b<c@d.com>,e@f.com>".into()), ("".into(), "g@h.com".into())]
        );
        assert_eq!(list("John (the third) Public <jqp@x.com>"), one("John   Public", "jqp@x.com"));
    }

    #[test]
    fn local_part_shapes() {
        assert_eq!(list("\"john doe\".x@y.z"), one("", "john doe.x@y.z"));
        assert_eq!(list("a@b.c."), one("", "a@b.c."));
        assert!(list("").is_empty());
        assert_eq!(list("<>"), one("", "<>"));
    }
}

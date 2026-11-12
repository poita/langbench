//! A reader for the small TOML subset used by `site.toml` and front matter.
//!
//! A document is a sequence of lines, each blank, a comment, or an
//! assignment `key = value` where the value is a basic string, an integer, a
//! boolean or a one-line array of strings. There are no tables, dotted keys
//! or multi-line values.
//!
//! ```
//! use sitegen::toml::{parse, Value};
//!
//! let doc = parse("title = \"A \\\"Blog\\\"\"  # note\nposts_per_page = 5\ntags = [\"a\", \"b\",]\n").unwrap();
//! assert_eq!(doc.get("title"), Some(&Value::String("A \"Blog\"".into())));
//! assert_eq!(doc.get("posts_per_page"), Some(&Value::Integer(5)));
//! assert_eq!(doc.get("tags"), Some(&Value::Array(vec!["a".into(), "b".into()])));
//! ```

use std::fmt;

/// A parsed TOML-subset value.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Value {
    /// A basic string.
    String(String),
    /// A 64-bit signed integer.
    Integer(i64),
    /// A boolean.
    Boolean(bool),
    /// An array of strings.
    Array(Vec<String>),
}

/// A parsed document: its keys in file order.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Table {
    entries: Vec<(String, Value)>,
}

impl Table {
    /// The value of `key`, if present.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.entries.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    /// Iterate over the entries in file order.
    pub fn iter(&self) -> impl Iterator<Item = (&str, &Value)> {
        self.entries.iter().map(|(k, v)| (k.as_str(), v))
    }

    /// Number of entries.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// True when the document has no entries.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// A syntax error in a TOML-subset document.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    /// 1-based line number.
    pub line: usize,
    /// What is wrong.
    pub message: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "line {}: {}", self.line, self.message)
    }
}

impl std::error::Error for ParseError {}

fn is_blank(c: char) -> bool {
    c == ' ' || c == '\t'
}

/// Parse a document.
pub fn parse(src: &str) -> Result<Table, ParseError> {
    let mut entries: Vec<(String, Value)> = Vec::new();
    for (i, line) in src.split('\n').enumerate() {
        let lineno = i + 1;
        let err = |message: &str| ParseError {
            line: lineno,
            message: message.to_string(),
        };
        let chars: Vec<char> = line.chars().collect();
        let mut p = 0;
        skip_blanks(&chars, &mut p);
        if p >= chars.len() || chars[p] == '#' {
            continue;
        }
        let key_start = p;
        while p < chars.len()
            && (chars[p].is_ascii_alphanumeric() || chars[p] == '_' || chars[p] == '-')
        {
            p += 1;
        }
        if p == key_start {
            return Err(err("expected a key"));
        }
        let key: String = chars[key_start..p].iter().collect();
        skip_blanks(&chars, &mut p);
        if chars.get(p) != Some(&'=') {
            return Err(err("expected `=`"));
        }
        p += 1;
        skip_blanks(&chars, &mut p);
        let value = parse_value(&chars, &mut p).map_err(|m| err(&m))?;
        skip_blanks(&chars, &mut p);
        if p < chars.len() && chars[p] != '#' {
            return Err(err("unexpected text after the value"));
        }
        if entries.iter().any(|(k, _)| *k == key) {
            return Err(err("duplicate key"));
        }
        entries.push((key, value));
    }
    Ok(Table { entries })
}

fn skip_blanks(chars: &[char], p: &mut usize) {
    while *p < chars.len() && is_blank(chars[*p]) {
        *p += 1;
    }
}

fn parse_value(chars: &[char], p: &mut usize) -> Result<Value, String> {
    match chars.get(*p) {
        Some('"') => Ok(Value::String(parse_string(chars, p)?)),
        Some('[') => {
            *p += 1;
            let mut items = Vec::new();
            skip_blanks(chars, p);
            if chars.get(*p) == Some(&']') {
                *p += 1;
                return Ok(Value::Array(items));
            }
            loop {
                skip_blanks(chars, p);
                if chars.get(*p) != Some(&'"') {
                    return Err("expected a string in the array".into());
                }
                items.push(parse_string(chars, p)?);
                skip_blanks(chars, p);
                match chars.get(*p) {
                    Some(',') => {
                        *p += 1;
                        skip_blanks(chars, p);
                        if chars.get(*p) == Some(&']') {
                            *p += 1;
                            return Ok(Value::Array(items));
                        }
                    }
                    Some(']') => {
                        *p += 1;
                        return Ok(Value::Array(items));
                    }
                    _ => return Err("expected `,` or `]` in the array".into()),
                }
            }
        }
        Some(_) => {
            let start = *p;
            while *p < chars.len() && !is_blank(chars[*p]) && chars[*p] != '#' {
                *p += 1;
            }
            let word: String = chars[start..*p].iter().collect();
            match word.as_str() {
                "true" => Ok(Value::Boolean(true)),
                "false" => Ok(Value::Boolean(false)),
                w => parse_integer(w).map(Value::Integer),
            }
        }
        None => Err("missing value".into()),
    }
}

fn parse_integer(w: &str) -> Result<i64, String> {
    let digits = w.strip_prefix('-').unwrap_or(w);
    let ok = !digits.is_empty()
        && digits.bytes().all(|b| b.is_ascii_digit())
        && (digits == "0" || !digits.starts_with('0'));
    if !ok {
        return Err(format!("invalid value `{}`", w));
    }
    w.parse::<i64>()
        .map_err(|_| format!("integer out of range: {}", w))
}

/// Parse a basic string starting at the opening quote.
fn parse_string(chars: &[char], p: &mut usize) -> Result<String, String> {
    debug_assert_eq!(chars[*p], '"');
    *p += 1;
    let mut s = String::new();
    loop {
        let Some(&c) = chars.get(*p) else {
            return Err("unterminated string".into());
        };
        *p += 1;
        match c {
            '"' => return Ok(s),
            '\\' => {
                let Some(&e) = chars.get(*p) else {
                    return Err("unterminated escape".into());
                };
                *p += 1;
                match e {
                    '"' => s.push('"'),
                    '\\' => s.push('\\'),
                    'n' => s.push('\n'),
                    't' => s.push('\t'),
                    'r' => s.push('\r'),
                    'u' => {
                        if *p + 4 > chars.len() {
                            return Err("short \\u escape".into());
                        }
                        let hex: String = chars[*p..*p + 4].iter().collect();
                        *p += 4;
                        let code = u32::from_str_radix(&hex, 16)
                            .map_err(|_| "bad \\u escape".to_string())?;
                        s.push(char::from_u32(code).ok_or("bad \\u escape (surrogate)")?);
                    }
                    _ => return Err(format!("unknown escape `\\{}`", e)),
                }
            }
            c => s.push(c),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spec_example() {
        let t = parse(
            "# a comment\ntitle  = \"The \\\"Big\\\" Blog\"        # trailing comment\nposts_per_page = 5\ndraft = false\ntags = [\"one\", \"two\",]\nmotto = \"line one\\nline two\"\n",
        )
        .unwrap();
        assert_eq!(
            t.get("title"),
            Some(&Value::String("The \"Big\" Blog".into()))
        );
        assert_eq!(t.get("posts_per_page"), Some(&Value::Integer(5)));
        assert_eq!(t.get("draft"), Some(&Value::Boolean(false)));
        assert_eq!(
            t.get("tags"),
            Some(&Value::Array(vec!["one".into(), "two".into()]))
        );
        assert_eq!(
            t.get("motto"),
            Some(&Value::String("line one\nline two".into()))
        );
        let keys: Vec<&str> = t.iter().map(|(k, _)| k).collect();
        assert_eq!(keys, ["title", "posts_per_page", "draft", "tags", "motto"]);
    }

    #[test]
    fn hash_inside_string_is_not_a_comment() {
        let t = parse("a = \"x # y\" # c\n").unwrap();
        assert_eq!(t.get("a"), Some(&Value::String("x # y".into())));
    }

    #[test]
    fn escapes_and_unicode() {
        let t = parse("a = \"\\u00e9\\u00C9\\t\\r\\\\ ü 'q'\"\n").unwrap();
        assert_eq!(t.get("a"), Some(&Value::String("éÉ\t\r\\ ü 'q'".into())));
    }

    #[test]
    fn integers() {
        let t = parse("a = 0\nb = -4\nc = 9223372036854775807\n").unwrap();
        assert_eq!(t.get("a"), Some(&Value::Integer(0)));
        assert_eq!(t.get("b"), Some(&Value::Integer(-4)));
        assert_eq!(t.get("c"), Some(&Value::Integer(i64::MAX)));
        assert!(parse("a = 01\n").is_err());
        assert!(parse("a = +1\n").is_err());
        assert!(parse("a = 1_0\n").is_err());
        assert!(parse("a = -\n").is_err());
    }

    #[test]
    fn arrays() {
        let t = parse("a = []\nb = [ ]\nc = [ \"x\" , \"y\" ]\nd = [\"z\",]\n").unwrap();
        assert_eq!(t.get("a"), Some(&Value::Array(vec![])));
        assert_eq!(t.get("b"), Some(&Value::Array(vec![])));
        assert_eq!(
            t.get("c"),
            Some(&Value::Array(vec!["x".into(), "y".into()]))
        );
        assert_eq!(t.get("d"), Some(&Value::Array(vec!["z".into()])));
        assert!(parse("a = [1]\n").is_err());
        assert!(parse("a = [\"x\" \"y\"]\n").is_err());
    }

    #[test]
    fn blank_lines_and_indentation() {
        let t = parse("\n  \t\n   # c\n\t k-1_x =\t\"v\" \t\n").unwrap();
        assert_eq!(t.get("k-1_x"), Some(&Value::String("v".into())));
        assert_eq!(t.len(), 1);
    }

    #[test]
    fn errors_report_the_line() {
        let e = parse("a = 1\nb = \"x\nc = 2\n").unwrap_err();
        assert_eq!(e.line, 2);
        assert!(parse("a = 1 b\n").is_err());
        assert!(parse("= 1\n").is_err());
        assert!(parse("a = 1\na = 2\n").is_err());
    }
}

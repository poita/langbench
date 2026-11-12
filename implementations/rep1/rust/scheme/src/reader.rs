//! The reader: turns program text into datums.

use crate::bigint::BigInt;
use crate::error::{Error, Result};
use crate::value::{Symbol, Value, QUOTE};

/// A recursive-descent reader over a program's text.
///
/// Call [`Reader::read`] repeatedly to obtain the top-level forms in order.
pub struct Reader<'a> {
    src: &'a [u8],
    pos: usize,
}

fn is_delimiter(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\r' | b'\n' | b'(' | b')' | b'\'' | b'"' | b';')
}

impl<'a> Reader<'a> {
    /// Creates a reader over `src`.
    pub fn new(src: &'a str) -> Reader<'a> {
        Reader { src: src.as_bytes(), pos: 0 }
    }

    fn skip_blank(&mut self) {
        while let Some(&b) = self.src.get(self.pos) {
            match b {
                b' ' | b'\t' | b'\r' | b'\n' => self.pos += 1,
                b';' => {
                    while self.src.get(self.pos).is_some_and(|&c| c != b'\n') {
                        self.pos += 1;
                    }
                }
                _ => break,
            }
        }
    }

    /// Reads the next datum, or `None` at the end of the input.
    pub fn read(&mut self) -> Result<Option<Value>> {
        self.skip_blank();
        if self.pos >= self.src.len() {
            return Ok(None);
        }
        self.datum().map(Some)
    }

    /// Reads every remaining datum.
    pub fn read_all(&mut self) -> Result<Vec<Value>> {
        let mut out = Vec::new();
        while let Some(d) = self.read()? {
            out.push(d);
        }
        Ok(out)
    }

    fn datum(&mut self) -> Result<Value> {
        self.skip_blank();
        let Some(&b) = self.src.get(self.pos) else {
            return Err(Error::syntax("unexpected end of input"));
        };
        match b {
            b'(' => {
                self.pos += 1;
                self.list_tail()
            }
            b')' => Err(Error::syntax("unexpected `)`")),
            b'\'' => {
                self.pos += 1;
                let d = self.datum()?;
                Ok(Value::list([Value::Sym(QUOTE), d]))
            }
            b'"' => self.string(),
            _ => Ok(self.atom()),
        }
    }

    /// Reads list elements up to the closing parenthesis (already past `(`).
    fn list_tail(&mut self) -> Result<Value> {
        let mut items = Vec::new();
        let mut tail = Value::Nil;
        loop {
            self.skip_blank();
            match self.src.get(self.pos) {
                None => return Err(Error::syntax("unterminated list")),
                Some(b')') => {
                    self.pos += 1;
                    break;
                }
                Some(b'.') if self.is_lone_dot() => {
                    self.pos += 1;
                    tail = self.datum()?;
                    self.skip_blank();
                    if self.src.get(self.pos) != Some(&b')') {
                        return Err(Error::syntax("expected `)` after dotted tail"));
                    }
                    self.pos += 1;
                    break;
                }
                Some(_) => items.push(self.datum()?),
            }
        }
        Ok(items.into_iter().rev().fold(tail, |t, x| Value::cons(x, t)))
    }

    fn is_lone_dot(&self) -> bool {
        self.src.get(self.pos + 1).map_or(true, |&b| is_delimiter(b))
    }

    fn string(&mut self) -> Result<Value> {
        self.pos += 1; // opening quote
        let mut bytes = Vec::new();
        loop {
            let Some(&b) = self.src.get(self.pos) else {
                return Err(Error::syntax("unterminated string"));
            };
            self.pos += 1;
            match b {
                b'"' => break,
                b'\\' => {
                    let Some(&e) = self.src.get(self.pos) else {
                        return Err(Error::syntax("unterminated string"));
                    };
                    self.pos += 1;
                    bytes.push(match e {
                        b'n' => b'\n',
                        b't' => b'\t',
                        other => other,
                    });
                }
                _ => bytes.push(b),
            }
        }
        // The input is valid UTF-8 and escapes only ever substitute ASCII
        // bytes, so this cannot fail.
        Ok(Value::string(&String::from_utf8_lossy(&bytes)))
    }

    fn atom(&mut self) -> Value {
        let start = self.pos;
        while self.src.get(self.pos).is_some_and(|&b| !is_delimiter(b)) {
            self.pos += 1;
        }
        let tok = std::str::from_utf8(&self.src[start..self.pos]).unwrap_or("");
        parse_atom(tok)
    }
}

/// Classifies a token as a boolean, an integer or a symbol.
fn parse_atom(tok: &str) -> Value {
    match tok {
        "#t" => return Value::Bool(true),
        "#f" => return Value::Bool(false),
        _ => {}
    }
    let digits = tok.strip_prefix(['+', '-']).unwrap_or(tok);
    if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
        if let Ok(i) = tok.parse::<i64>() {
            return Value::Int(i);
        }
        if let Some(b) = BigInt::parse(tok) {
            return Value::from_bigint(b);
        }
    }
    Value::Sym(Symbol::new(tok))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(src: &str) -> Vec<String> {
        Reader::new(src).read_all().unwrap().iter().map(|v| v.to_string()).collect()
    }

    #[test]
    fn atoms() {
        assert_eq!(read("42 -7 +5 007 -0 #t #f foo + - ... 1+ a.b"),
                   ["42", "-7", "5", "7", "0", "#t", "#f", "foo", "+", "-", "...", "1+", "a.b"]);
    }

    #[test]
    fn big_integer() {
        assert_eq!(read("123456789012345678901234567890"), ["123456789012345678901234567890"]);
        assert_eq!(read("-9223372036854775808"), ["-9223372036854775808"]);
        assert_eq!(read("9223372036854775808"), ["9223372036854775808"]);
    }

    #[test]
    fn lists_and_dots() {
        assert_eq!(read("() (1 2 . 3) (1 . (2))"), ["()", "(1 2 . 3)", "(1 2)"]);
    }

    #[test]
    fn quote_and_comments() {
        assert_eq!(read("'a ; comment\n'(1 'b) ''()"),
                   ["(quote a)", "(quote (1 (quote b)))", "(quote (quote ()))"]);
    }

    #[test]
    fn strings() {
        let forms = Reader::new(r#""a\"b\\c\nd\te" "x
y""#).read_all().unwrap();
        match (&forms[0], &forms[1]) {
            (Value::Str(a), Value::Str(b)) => {
                assert_eq!(&**a, "a\"b\\c\nd\te");
                assert_eq!(&**b, "x\ny");
            }
            _ => panic!("expected strings"),
        }
    }

    #[test]
    fn errors() {
        assert!(Reader::new("(1 2").read_all().is_err());
        assert!(Reader::new("\"abc").read_all().is_err());
    }
}

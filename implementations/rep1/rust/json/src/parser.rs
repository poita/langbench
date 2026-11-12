//! Recursive-descent parser for RFC 8259 JSON, producing a [`Value`] tree.
//!
//! The parser makes a single forward pass over the bytes and stops at the
//! first error. It expects its input to have been validated as UTF-8 already
//! (see [`crate::utf8`]); [`parse`] does that for you.

use crate::error::{Error, ErrorKind};
use crate::utf8;
use crate::value::Value;

/// Maximum supported nesting depth of arrays and objects.
pub const MAX_DEPTH: usize = 512;

/// Parses a complete document: validates UTF-8, rejects a leading BOM, and
/// requires exactly one value surrounded by optional JSON whitespace.
pub fn parse(input: &[u8]) -> Result<Value, Error> {
    if input.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return Err(Error::new(ErrorKind::ByteOrderMark, 0));
    }
    utf8::validate(input)?;
    let mut p = Parser { s: input, pos: 0 };
    p.skip_ws();
    let v = p.value(0)?;
    p.skip_ws();
    if p.pos != p.s.len() {
        return Err(Error::new(ErrorKind::TrailingData, p.pos));
    }
    Ok(v)
}

struct Parser<'a> {
    s: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn err<T>(&self, kind: ErrorKind) -> Result<T, Error> {
        Err(Error::new(kind, self.pos))
    }

    fn peek(&self) -> Option<u8> {
        self.s.get(self.pos).copied()
    }

    fn skip_ws(&mut self) {
        while let Some(b' ' | b'\t' | b'\n' | b'\r') = self.peek() {
            self.pos += 1;
        }
    }

    fn expect_byte(&mut self, b: u8) -> Result<(), Error> {
        match self.peek() {
            Some(c) if c == b => {
                self.pos += 1;
                Ok(())
            }
            Some(_) => self.err(ErrorKind::UnexpectedByte),
            None => self.err(ErrorKind::UnexpectedEnd),
        }
    }

    fn literal(&mut self, word: &[u8], v: Value) -> Result<Value, Error> {
        if self.s[self.pos..].starts_with(word) {
            self.pos += word.len();
            Ok(v)
        } else if word.starts_with(&self.s[self.pos..]) {
            self.pos = self.s.len();
            self.err(ErrorKind::UnexpectedEnd)
        } else {
            self.err(ErrorKind::UnexpectedByte)
        }
    }

    /// Parses a value. `depth` is the number of enclosing containers.
    fn value(&mut self, depth: usize) -> Result<Value, Error> {
        match self.peek() {
            None => self.err(ErrorKind::UnexpectedEnd),
            Some(b'{') => self.object(depth + 1),
            Some(b'[') => self.array(depth + 1),
            Some(b'"') => Ok(Value::String(self.string()?)),
            Some(b't') => self.literal(b"true", Value::Bool(true)),
            Some(b'f') => self.literal(b"false", Value::Bool(false)),
            Some(b'n') => self.literal(b"null", Value::Null),
            Some(b'-' | b'0'..=b'9') => Ok(Value::Number(self.number()?)),
            Some(_) => self.err(ErrorKind::UnexpectedByte),
        }
    }

    fn array(&mut self, depth: usize) -> Result<Value, Error> {
        if depth > MAX_DEPTH {
            return self.err(ErrorKind::TooDeep);
        }
        self.pos += 1; // '['
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Value::Array(items));
        }
        loop {
            self.skip_ws();
            items.push(self.value(depth)?);
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Value::Array(items));
                }
                Some(_) => return self.err(ErrorKind::UnexpectedByte),
                None => return self.err(ErrorKind::UnexpectedEnd),
            }
        }
    }

    fn object(&mut self, depth: usize) -> Result<Value, Error> {
        if depth > MAX_DEPTH {
            return self.err(ErrorKind::TooDeep);
        }
        self.pos += 1; // '{'
        let mut members = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Value::Object(members));
        }
        loop {
            self.skip_ws();
            if self.peek() != Some(b'"') {
                return match self.peek() {
                    None => self.err(ErrorKind::UnexpectedEnd),
                    Some(_) => self.err(ErrorKind::UnexpectedByte),
                };
            }
            let key = self.string()?;
            self.skip_ws();
            self.expect_byte(b':')?;
            self.skip_ws();
            let v = self.value(depth)?;
            members.push((key, v));
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Value::Object(members));
                }
                Some(_) => return self.err(ErrorKind::UnexpectedByte),
                None => return self.err(ErrorKind::UnexpectedEnd),
            }
        }
    }

    fn hex4(&mut self) -> Result<u32, Error> {
        if self.pos + 4 > self.s.len() {
            self.pos = self.s.len();
            return self.err(ErrorKind::UnexpectedEnd);
        }
        let mut v = 0u32;
        for k in 0..4 {
            let d = match self.s[self.pos + k] {
                c @ b'0'..=b'9' => c - b'0',
                c @ b'a'..=b'f' => c - b'a' + 10,
                c @ b'A'..=b'F' => c - b'A' + 10,
                _ => {
                    self.pos += k;
                    return self.err(ErrorKind::InvalidEscape);
                }
            };
            v = v * 16 + d as u32;
        }
        self.pos += 4;
        Ok(v)
    }

    fn string(&mut self) -> Result<String, Error> {
        self.pos += 1; // opening quote
        let mut out = String::new();
        let mut run = self.pos; // start of the pending raw run
        loop {
            let Some(b) = self.peek() else {
                return self.err(ErrorKind::UnexpectedEnd);
            };
            match b {
                b'"' => {
                    self.flush(&mut out, run);
                    self.pos += 1;
                    return Ok(out);
                }
                0x00..=0x1F => return self.err(ErrorKind::ControlCharacter),
                b'\\' => {
                    self.flush(&mut out, run);
                    self.pos += 1;
                    let Some(e) = self.peek() else {
                        return self.err(ErrorKind::UnexpectedEnd);
                    };
                    self.pos += 1;
                    match e {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let c = self.unicode_escape()?;
                            out.push(c);
                        }
                        _ => {
                            self.pos -= 1;
                            return self.err(ErrorKind::InvalidEscape);
                        }
                    }
                    run = self.pos;
                }
                _ => self.pos += 1,
            }
        }
    }

    /// Appends the raw bytes `s[run..pos]` (valid UTF-8, since the whole input
    /// was validated and runs are delimited by ASCII bytes).
    fn flush(&self, out: &mut String, run: usize) {
        if run < self.pos {
            match std::str::from_utf8(&self.s[run..self.pos]) {
                Ok(t) => out.push_str(t),
                Err(_) => unreachable!("input was validated as UTF-8"),
            }
        }
    }

    /// Handles the part after `\u`, including surrogate pairing.
    fn unicode_escape(&mut self) -> Result<char, Error> {
        let hi = self.hex4()?;
        match hi {
            0xD800..=0xDBFF => {
                if self.s[self.pos..].starts_with(b"\\u") {
                    self.pos += 2;
                    let lo = self.hex4()?;
                    if (0xDC00..=0xDFFF).contains(&lo) {
                        let cp = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
                        return Ok(char::from_u32(cp).expect("valid supplementary code point"));
                    }
                }
                self.err(ErrorKind::InvalidEscape)
            }
            0xDC00..=0xDFFF => self.err(ErrorKind::InvalidEscape),
            _ => Ok(char::from_u32(hi).expect("non-surrogate BMP code point")),
        }
    }

    fn digits(&mut self) -> usize {
        let start = self.pos;
        while let Some(b'0'..=b'9') = self.peek() {
            self.pos += 1;
        }
        self.pos - start
    }

    /// Parses a number and returns its canonical text: the integer lexeme
    /// as written, or `-? int frac?` followed by a normalized exponent.
    fn number(&mut self) -> Result<String, Error> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        match self.peek() {
            Some(b'0') => {
                self.pos += 1;
                if let Some(b'0'..=b'9') = self.peek() {
                    return self.err(ErrorKind::InvalidNumber);
                }
            }
            Some(b'1'..=b'9') => {
                self.digits();
            }
            _ => return self.err(ErrorKind::InvalidNumber),
        }
        if self.peek() == Some(b'.') {
            self.pos += 1;
            if self.digits() == 0 {
                return self.err(ErrorKind::InvalidNumber);
            }
        }
        let mantissa_end = self.pos;
        let mut out = String::with_capacity(mantissa_end - start + 4);
        // Number lexemes are pure ASCII.
        out.push_str(std::str::from_utf8(&self.s[start..mantissa_end]).expect("ASCII"));
        if let Some(b'e' | b'E') = self.peek() {
            self.pos += 1;
            let mut negative = false;
            match self.peek() {
                Some(b'+') => self.pos += 1,
                Some(b'-') => {
                    negative = true;
                    self.pos += 1;
                }
                _ => {}
            }
            let ds = self.pos;
            if self.digits() == 0 {
                return self.err(ErrorKind::InvalidNumber);
            }
            let digits = &self.s[ds..self.pos];
            let nz = digits.iter().position(|&d| d != b'0');
            out.push('e');
            match nz {
                None => out.push('0'),
                Some(k) => {
                    if negative {
                        out.push('-');
                    }
                    out.push_str(std::str::from_utf8(&digits[k..]).expect("ASCII"));
                }
            }
        }
        Ok(out)
    }
}
